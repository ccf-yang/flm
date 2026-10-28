import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the player did, in order, kept in memory *and on disk*.
///
/// The request/headers/body dump this used to be is gone: it buried the few lines
/// that matter under hundreds of HTTP entries, and it lived only in memory, so the
/// one moment worth reading — a stall behind the lock screen, followed by the app
/// being killed — lost the log. Now every entry is a playback decision (a remote
/// skip, a resolve that gave up, a boundary promotion, a watchdog re-arm), the
/// tail of the previous run is read back at startup, and each line is appended to
/// `Documents/Debug/playback.log` as it is recorded.
///
/// Recording is gated on [enabled] at append time; turning the switch off pauses
/// recording but keeps the existing log readable — use [clear] to wipe both.
class DebugLog extends ChangeNotifier {
  DebugLog({required this.enabled});

  static const int _maxEntries = 2000;

  /// How many of the previous run's lines are read back at startup. Enough to see
  /// a whole stall, small enough that opening the page stays instant.
  static const int _restoreEntries = 600;

  /// Long enough for a stack trace, short enough that a link or an error string
  /// cannot push the interesting fields off the screen.
  static const int _maxValueChars = 1200;

  /// The file is rotated once it passes this size, keeping its newest half.
  static const int _maxLogBytes = 512 * 1024;

  bool enabled;

  final Queue<String> _entries = Queue<String>();

  IOSink? _sink;
  int _bytesWritten = 0;
  bool _warming = false;
  Timer? _flushTimer;

  List<String> get entries => List<String>.unmodifiable(_entries);

  /// How many entries the view keeps before the oldest fall off.
  int get maxEntries => _maxEntries;

  String get text => _entries.join('\n\n\n');

  /// Where the on-disk copy lives, for the settings/debug page to show.
  String get filePath => _file?.path ?? '（尚未就绪）';

  File? _file;
  Directory? _dir;

  /// Opens the log file, trims it if it grew too large, and brings the previous
  /// run's tail back into the view. Safe to call once at startup; failures simply
  /// leave the log memory-only.
  Future<void> warmUp() async {
    if (_warming || _file != null) return;
    _warming = true;
    try {
      final documents = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(documents.path, 'Debug'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'playback.log'));
      if (await file.exists()) {
        final size = await file.length();
        _bytesWritten = size;
        if (size > _maxLogBytes) await _trim(file, size);
        if (await file.length() > 0) _restore(file);
      }
      _dir = dir;
      _file = file;
      final sink = file.openWrite(mode: FileMode.append);
      final header = '===== 新会话 ${_dateStamp()} · 之前共 ${_entries.length} 条 =====\n\n\n';
      sink.write(header);
      _bytesWritten += header.length;
      _sink = sink;
      _warming = false;
      notifyListeners();
    } catch (error) {
      // Disk is a convenience here; the in-memory trace still works without it.
      _warming = false;
      _sink = null;
      if (kDebugMode) debugPrint('DebugLog warmUp failed: $error');
    }
  }

  /// Keep the newest half of an oversized file, starting on a line boundary.
  Future<void> _trim(File file, int size) async {
    try {
      final raf = file.openSync(mode: FileMode.append);
      try {
        const keep = _maxLogBytes ~/ 2;
        final start = size - keep;
        raf.setPosition(start);
        var bytes = raf.readSync(keep);
        // Drop everything up to the first newline so the file never starts
        // mid-entry.
        final index = bytes.indexOf(0x0a);
        if (index >= 0 && index + 1 < bytes.length) {
          bytes = bytes.sublist(index + 1);
        }
        raf.truncate(0);
        raf.setPosition(0);
        raf.writeFromSync(bytes);
        _bytesWritten = bytes.length;
      } finally {
        await raf.close();
      }
    } catch (_) {
      // Rotation is best effort.
    }
  }

  /// Read the file's newest lines back into the buffer so the stall from before
  /// the restart is still exportable.
  void _restore(File file) {
    try {
      final lines = file.readAsLinesSync();
      final kept = <String>[];
      var current = <String>[];
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) {
          if (current.isNotEmpty) {
            kept.add(current.reversed.join('\n'));
            current = <String>[];
            if (kept.length >= _restoreEntries) break;
          }
          continue;
        }
        if (line.startsWith('=====')) {
          if (current.isNotEmpty) {
            kept.add(current.reversed.join('\n'));
          }
          break;
        }
        current.add(line);
      }
      if (current.isNotEmpty) kept.add(current.reversed.join('\n'));
      if (kept.isEmpty) return;
      final restored = kept.reversed.toList(growable: false);
      // Rebuild rather than prepend: the Queue API has no addAllFirst, and any
      // lines already recorded while the file was opening belong after the history.
      final live = _entries.toList(growable: false);
      _entries.clear();
      _entries.addAll(<String>[
        '——— 上次运行的记录（共 ${restored.length} 条）———',
        ...restored,
        ...live,
      ]);
      while (_entries.length > _maxEntries) {
        _entries.removeFirst();
      }
    } catch (_) {
      // A half-written file is not worth losing the live log over.
    }
  }

  void record(String title, Map<String, Object?> fields) {
    if (!enabled) return;
    final buffer = StringBuffer()..writeln('[${_stamp()}] $title');
    fields.forEach((key, value) {
      if (value == null || '$value'.isEmpty) return;
      buffer.writeln('$key: ${_clip('$value')}');
    });
    append(buffer.toString());
  }

  /// Appends one preformatted entry: into the view and, once the file is open,
  /// onto disk. Split out so [clear] and [warmUp] can write their own markers.
  void append(String entry) {
    _entries.add(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    final sink = _sink;
    if (sink != null) {
      final text = '$entry\n\n\n';
      sink.write(text);
      _bytesWritten += text.length;
      if (_bytesWritten > _maxLogBytes) {
        unawaited(_rotate());
      } else {
        // A stall is usually followed by the app being killed, so the buffer must
        // not wait for the OS to drain it: flush shortly after the burst settles.
        _flushTimer?.cancel();
        _flushTimer = Timer(const Duration(milliseconds: 400), () {
          final current = _sink;
          if (current != null) unawaited(current.flush());
        });
      }
    }
    notifyListeners();
  }

  Future<void> _rotate() async {
    final file = _file;
    final sink = _sink;
    if (file == null || sink == null || _bytesWritten <= _maxLogBytes) return;
    try {
      await sink.flush();
      await sink.close();
      _sink = null;
      await _trim(file, await file.length());
      final next = file.openWrite(mode: FileMode.append);
      next.writeln('（日志已滚动，保留了最近的部分）');
      _sink = next;
    } catch (_) {
      // Keep recording in memory if the file could not be reopened.
    }
  }

  void setEnabled(bool value) {
    // Turning the switch off must NOT wipe the log — the user needs to read
    // what happened after the fact. Use the explicit clear button for that.
    enabled = value;
    notifyListeners();
  }

  /// Wipe both the view and the file, so an export never mixes old runs with new.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    unawaited(_truncateFile());
    notifyListeners();
  }

  Future<void> _truncateFile() async {
    final file = _file;
    var sink = _sink;
    try {
      if (sink != null) {
        await sink.flush();
        await sink.close();
        _sink = null;
      }
      if (file != null && await file.exists()) {
        await file.writeAsString('', mode: FileMode.write, flush: true);
      }
      _bytesWritten = 0;
      if (file != null) {
        sink = file.openWrite(mode: FileMode.append);
        sink.writeln('===== 日志已清空 ${_dateStamp()} =====');
        _sink = sink;
      }
    } catch (_) {
      // The in-memory view is already cleared, which is what the user asked for.
    }
  }

  Future<void> disposeFile() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
  }

  String _dateStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  String _clip(String value) {
    final flat = value.replaceAll('\r', '');
    if (flat.length <= _maxValueChars) return flat;
    return '${flat.substring(0, _maxValueChars)}…(${flat.length} chars)';
  }

  /// Directory the log lives in, once [warmUp] has run.
  String? get directoryPath => _dir?.path;
}
