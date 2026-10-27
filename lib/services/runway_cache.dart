import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log.dart';

/// A hidden, self-limiting audio cache holding the tracks the queue is about to
/// reach.
///
/// The two-player standby already removes JavaScript and link fetching from the
/// track boundary, but the boundary still depends on *one remote URL staying
/// alive*: sources hand out links that expire within minutes, and a host that
/// answers a range probe can still refuse the body a minute later or disappear
/// into a cellular hole. Keeping the next tracks as local files turns the
/// boundary into a file open — the only shape of pre-preparation that survives
/// an unstable source.
///
/// Files live in `Documents/Runway` and are deliberately *not* part of 本地音乐:
/// they are disposable transport cache, tracked by `index.json`, capped by total
/// size, and pruned down to the tracks still ahead of the playhead.
class RunwayCache {
  RunwayCache({this.debugLog});

  /// Total bytes the cache may occupy; the oldest entries go first.
  static const int maxBytes = 200 * 1024 * 1024;

  /// How many files are retained at most — a few tracks behind the playhead is
  /// all the runway a boundary can use, and it keeps a long queue from filling
  /// the device with audio it already played.
  static const int keepFiles = 6;

  /// A body larger than this is not one song, so the transfer is abandoned.
  static const int _maxFileBytes = 80 * 1024 * 1024;

  /// Below this the body cannot be a song (an error page, a truncated stream).
  static const int _minFileBytes = 8 * 1024;

  final DebugLog? debugLog;

  /// Turns a `source:id` key into something a human can read on the debug page.
  String Function(String key)? labelFor;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 90),
      responseType: ResponseType.stream,
      followRedirects: true,
      maxRedirects: 10,
      headers: const <String, String>{
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
    ),
  );

  final Map<String, _RunwayEntry> _entries = <String, _RunwayEntry>{};
  final Set<String> _inFlight = <String>{};
  final List<_RunwayJob> _pending = <_RunwayJob>[];

  Directory? _dir;
  File? _indexFile;
  bool _loaded = false;
  bool _busy = false;
  bool _writing = false;
  bool _writeAgain = false;

  /// The local file for [key] when one is ready, otherwise null.
  String? pathFor(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!File(entry.path).existsSync()) {
      _entries.remove(key);
      unawaited(_store());
      return null;
    }
    return entry.path;
  }

  bool isBusy(String key) => _inFlight.contains(key) || _pending.any((job) => job.key == key);

  /// Throw away a track's cached copy: the player refused the file, so the caller
  /// has to fall back to the remote link instead of reaching for the same broken
  /// bytes on every later attempt.
  Future<void> drop(String key) async {
    _pending.removeWhere((job) => job.key == key);
    await _drop(key);
    await _store();
  }

  /// Return the local file for [key], queueing a download of [url] when absent.
  ///
  /// A request for a track that is not cached yet answers null straight away: the
  /// caller keeps arming the standby with the remote link and adopts the file
  /// later, when the transfer lands. Only one transfer runs at a time, so a deep
  /// runway never competes for bandwidth with the audio being heard.
  Future<String?> ensure({
    required String key,
    required String url,
    String type = 'mp3',
  }) async {
    if (key.isEmpty || !url.startsWith('http')) return null;
    final ready = pathFor(key);
    if (ready != null) return ready;
    if (_inFlight.contains(key)) return null;
    if (_busy) {
      _pending.removeWhere((job) => job.key == key);
      _pending.add(_RunwayJob(key: key, url: url, type: type));
      // Whatever is further ahead than the last few tracks will be re-requested
      // with a fresher link long before it is reached.
      while (_pending.length > keepFiles) {
        _pending.removeAt(0);
      }
      return null;
    }
    unawaited(_run(_RunwayJob(key: key, url: url, type: type)));
    return null;
  }

  Future<void> _run(_RunwayJob job) async {
    _busy = true;
    _inFlight.add(job.key);
    try {
      await _download(job);
    } finally {
      _inFlight.remove(job.key);
      _busy = false;
      if (_pending.isNotEmpty) {
        unawaited(_run(_pending.removeAt(0)));
      }
    }
  }

  Future<void> _download(_RunwayJob job) async {
    final dir = await _obtainDir();
    if (dir == null) return;
    final ext = _extensionFor(job.type, job.url);
    final target = File(p.join(dir.path, '${_stableName(job.key)}.$ext'));
    final temp = File('${target.path}.part');
    final started = DateTime.now();
    var written = 0;
    try {
      await () async {
        final response = await _dio.get<ResponseBody>(
          job.url,
          options: Options(receiveTimeout: const Duration(seconds: 120)),
        );
        final stream = response.data?.stream;
        if (stream == null) throw StateError('没有响应体');
        final sink = temp.openWrite();
        try {
          await stream.forEach((chunk) {
            written += chunk.length;
            if (written > _maxFileBytes) throw _RunwayTooBig();
            sink.add(chunk);
          });
          await sink.flush();
        } finally {
          await sink.close();
        }
      }().timeout(const Duration(seconds: 180));
      final size = await temp.length();
      if (size < _minFileBytes) {
        if (await temp.exists()) await temp.delete();
        debugLog?.record('预下载结果过小，丢弃 ${_label(job.key)}', <String, Object?>{'字节': size});
        return;
      }
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      _entries[job.key] = _RunwayEntry(
        path: target.path,
        bytes: size,
        touchedAt: DateTime.now(),
      );
      await _store();
      debugLog?.record('预下载完成 ${_label(job.key)}', <String, Object?>{
        '大小': human(size),
        '耗时': '${DateTime.now().difference(started).inSeconds}s',
        '缓存占用': human(totalBytes()),
      });
      await _enforceLimits();
    } on _RunwayTooBig {
      debugLog?.record('预下载已放弃（超大）${_label(job.key)}', <String, Object?>{
        '已收': human(written),
      });
      await _deleteQuietly(temp);
    } catch (error) {
      await _deleteQuietly(temp);
      debugLog?.record('预下载失败 ${_label(job.key)}', <String, Object?>{
        '错误': '$error',
        '耗时': '${DateTime.now().difference(started).inSeconds}s',
      });
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Retain only what the playhead can still reach, then enforce the caps.
  ///
  /// [ahead] is the order the queue will actually play in. Anything outside its
  /// first entries has been heard or is far enough away that re-resolving it
  /// later is cheaper than storing it now.
  Future<void> prune({required List<String> ahead}) async {
    final keep = ahead.take(keepFiles).toSet();
    _pending.removeWhere((job) => !keep.contains(job.key));
    for (final key in _entries.keys.where((item) => !keep.contains(item)).toList()) {
      await _drop(key);
    }
    await _enforceLimits();
    await _store();
  }

  Future<void> _enforceLimits() async {
    while (_entries.length > keepFiles) {
      await _drop(_oldest().key);
    }
    while (_entries.isNotEmpty && totalBytes() > maxBytes) {
      await _drop(_oldest().key);
    }
  }

  MapEntry<String, _RunwayEntry> _oldest() {
    var best = _entries.entries.first;
    for (final item in _entries.entries) {
      if (item.value.touchedAt.isBefore(best.value.touchedAt)) best = item;
    }
    return best;
  }

  Future<void> _drop(String key) async {
    final entry = _entries.remove(key);
    if (entry == null) return;
    try {
      final file = File(entry.path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  int totalBytes() {
    var sum = 0;
    for (final entry in _entries.values) {
      sum += entry.bytes;
    }
    return sum;
  }

  int get cachedCount => _entries.length;

  /// Drop the whole cache (the 清空播放缓存 button).
  Future<void> clear() async {
    _pending.clear();
    for (final key in _entries.keys.toList()) {
      await _drop(key);
    }
    await _store();
  }

  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// Read `index.json` once and sweep anything it no longer knows about, so an
  /// interrupted install or a hand-deleted index cannot leak audio files.
  Future<void> warmUp() async {
    if (_loaded) return;
    _loaded = true;
    final dir = await _obtainDir();
    if (dir == null) return;
    final index = _indexFile;
    if (index != null && await index.exists()) {
      try {
        final decoded = jsonDecode(await index.readAsString());
        if (decoded is Map<String, dynamic>) {
          for (final item in decoded.entries) {
            if (item.value is! Map) continue;
            final row = Map<String, dynamic>.from(item.value as Map);
            final path = '${row['f'] ?? ''}';
            if (path.isEmpty || !File(path).existsSync()) continue;
            _entries[item.key] = _RunwayEntry(
              path: path,
              bytes: (row['s'] as num?)?.toInt() ?? 0,
              touchedAt: DateTime.fromMillisecondsSinceEpoch(
                (row['t'] as num?)?.toInt() ?? 0,
              ),
            );
          }
        }
      } catch (_) {
        // A torn index just means the cache starts empty; the sweep below
        // removes the files that used to belong to it.
      }
    }
    final known = _entries.values.map((entry) => entry.path).toSet();
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (known.contains(entity.path)) continue;
        await _deleteQuietly(entity);
      }
    } catch (_) {}
  }

  Future<Directory?> _obtainDir() async {
    final current = _dir;
    if (current != null) return current;
    try {
      final documents = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(documents.path, 'Runway'));
      await dir.create(recursive: true);
      _dir = dir;
      _indexFile = File(p.join(dir.path, 'index.json'));
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<void> _store() async {
    if (_writing) {
      // Writes are small JSON blobs; coalescing beats racing renames.
      _writeAgain = true;
      return;
    }
    _writing = true;
    try {
      final dir = await _obtainDir();
      final index = _indexFile;
      if (dir == null || index == null) return;
      do {
        _writeAgain = false;
        final payload = <String, dynamic>{};
        _entries.forEach((key, entry) {
          payload[key] = <String, dynamic>{
            'f': entry.path,
            's': entry.bytes,
            't': entry.touchedAt.millisecondsSinceEpoch,
          };
        });
        final temp = File('${index.path}.tmp');
        await temp.writeAsString(jsonEncode(payload), flush: true);
        await temp.rename(index.path);
      } while (_writeAgain);
    } catch (_) {
      // Losing the index only costs a re-download; it must never surface.
    } finally {
      _writing = false;
    }
  }

  String _label(String key) => labelFor?.call(key) ?? key;

  String _stableName(String key) {
    final safe = !RegExp(r'[^A-Za-z0-9_.-]').hasMatch(key)
        ? key
        : base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return 'run_$safe';
  }

  String _extensionFor(String type, String url) {
    final t = type.trim().toLowerCase();
    const known = <String>[
      'mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'ape',
    ];
    if (known.contains(t)) return t;
    try {
      final ext = p.extension(Uri.parse(url).path).replaceFirst('.', '').toLowerCase();
      if (known.contains(ext)) return ext;
    } catch (_) {}
    return 'mp3';
  }
}

class _RunwayJob {
  _RunwayJob({required this.key, required this.url, required this.type});

  final String key;
  final String url;
  final String type;
}

class _RunwayEntry {
  _RunwayEntry({
    required this.path,
    required this.bytes,
    required this.touchedAt,
  });

  final String path;
  final int bytes;
  final DateTime touchedAt;
}

class _RunwayTooBig implements Exception {}
