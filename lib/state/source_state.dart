import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:webview_flutter/webview_flutter.dart';

import '../data/custom_source_repository.dart';
import '../models/custom_source.dart';
import '../models/song.dart';
import '../services/debug_log.dart';
import '../services/http_bridge.dart';
import '../services/source_engine.dart';
import 'app_state.dart';

/// One long-lived WebView sandbox per custom source. Initializing a source runs
/// its script once; afterwards every switch/reuse is instant — the engine stays
/// mounted off-screen inside [SourceState]'s slot map.
class _SourceSlot {
  _SourceSlot(this.engine, DebugLog? log) {
    if (log != null) {
      engine.onEvent = (title, fields) => log.record(title, fields);
    }
  }

  final SourceEngine engine;
  SourceCapabilities capabilities = SourceCapabilities.empty();
  bool ready = false;
  DateTime lastUsed = DateTime.now();
}

class SourceState extends ChangeNotifier {
  SourceState({
    required this.repository,
    required this.http,
    required this.appState,
    this.debugLog,
  });

  /// Keep at most this many live sandboxes; the least recently used idle one is
  /// unmounted when a new source pushes past the cap.
  static const int _maxLiveEngines = 8;

  final CustomSourceRepository repository;
  final HttpBridge http;
  final AppState appState;
  final DebugLog? debugLog;

  /// Reason of the most recent failed cross-source resolution, surfaced in the
  /// debug log so "why can't this song play" is answerable from the phone.
  String? _lastPoolError;

  final Map<String, _SourceSlot> _slots = <String, _SourceSlot>{};
  final Map<String, Future<void>> _initializing = <String, Future<void>>{};

  /// Cache of which music platforms each custom source can resolve, keyed by
  /// source id. Used to prefer a source that likely supports a song during the
  /// transparent cross-source fallback in [resolveMusicUrlAutoSwitch].
  final Map<String, Set<String>> _supported = <String, Set<String>>{};

  bool importing = false;
  String? error;

  List<CustomSourceInfo> get sources => repository.sources;

  CustomSourceInfo? get active {
    final id = appState.settings.activeSourceId;
    if (id == null) return null;
    return repository.byId(id);
  }

  SourceCapabilities get capabilities {
    final id = active?.id;
    if (id == null) return SourceCapabilities.empty();
    return _slots[id]?.capabilities ?? SourceCapabilities.empty();
  }

  bool get hasActiveSource => active != null && !capabilities.isEmpty;

  /// Why the previous cross-source resolution failed (null after a success).
  String? get lastPoolError => _lastPoolError;

  bool get loading => _initializing.containsKey(active?.id ?? '');

  /// Controllers of every live sandbox. [EngineHost] must keep these mounted
  /// off-screen, otherwise their WKWebViews never run.
  List<WebViewController> get engineControllers =>
      _slots.values.map((slot) => slot.engine.controller).toList(growable: false);

  Future<void> init() async {
    final source = active;
    if (source != null) await _initialize(source);
  }

  /// The user's explicit choice. Writing the selection is immediate; loading
  /// the script happens in the background and never rewrites this value.
  /// Cross-source fallback probes (see [resolveMusicUrlAutoSwitch]) call this
  /// method's internal engine pool only — they never touch settings.
  Future<void> setActive(CustomSourceInfo? source) async {
    appState.settings.activeSourceId = source?.id;
    await appState.repository.save();
    error = null;
    notifyListeners();
    if (source != null) {
      unawaited(_initialize(source));
    }
  }

  Future<void> _initialize(CustomSourceInfo source) {
    final pending = _initializing[source.id];
    if (pending != null) {
      return pending.catchError((_) {});
    }
    final task = _doInitialize(source);
    _initializing[source.id] = task;
    return task.whenComplete(() => _initializing.remove(source.id));
  }

  Future<void> _doInitialize(CustomSourceInfo source) async {
    var slot = _slots[source.id];
    if (slot == null) {
      slot = _SourceSlot(SourceEngine(http), debugLog);
      _slots[source.id] = slot;
      _evictIfNeeded(source.id);
      notifyListeners();
      // Give EngineHost one frame to mount the new off-screen web view before
      // the page-load future below starts waiting for it. When the app is
      // backgrounded no frames are produced, so never wait indefinitely.
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );
    }
    slot.lastUsed = DateTime.now();

    final script = await repository.scriptFor(source.id);
    if (script == null || script.trim().isEmpty) {
      slot.ready = false;
      if (active?.id == source.id) error = '自定义源脚本不存在';
      debugLog?.record('源初始化失败 ${source.name}', <String, Object?>{
        '原因': '脚本不存在',
      });
      notifyListeners();
      return;
    }
    debugLog?.record('源初始化开始 ${source.name}', <String, Object?>{
      'id': source.id,
      '脚本长度': script.length,
    });
    try {
      slot.capabilities = await slot.engine.activate(source, script);
      final names = <String>{};
      for (final name in slot.capabilities.sources.keys) {
        if (slot.capabilities.supports(name, 'musicUrl')) names.add(name);
      }
      _supported[source.id] = names;
      slot.ready = true;
      if (active?.id == source.id) error = null;
      debugLog?.record('源就绪 ${source.name}', <String, Object?>{
        '平台': names.join('、'),
      });
    } catch (e) {
      slot.ready = false;
      slot.capabilities = SourceCapabilities.empty();
      _supported.remove(source.id);
      if (active?.id == source.id) error = '$e';
      debugLog?.record('源初始化失败 ${source.name}', <String, Object?>{
        '原因': '$e',
      });
    }
    slot.lastUsed = DateTime.now();
    notifyListeners();
  }

  void _evictIfNeeded(String keepId) {
    while (_slots.length >= _maxLiveEngines) {
      String? victimId;
      _SourceSlot? victim;
      for (final entry in _slots.entries) {
        if (entry.key == keepId || entry.key == appState.settings.activeSourceId) continue;
        if (_initializing.containsKey(entry.key)) continue;
        if (victim == null || entry.value.lastUsed.isBefore(victim.lastUsed)) {
          victim = entry.value;
          victimId = entry.key;
        }
      }
      if (victimId == null) return;
      _slots.remove(victimId);
      _supported.remove(victimId);
    }
  }

  Future<void> reload() => init();

  Future<CustomSourceInfo?> importSource() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final script = file.bytes != null
        ? utf8.decode(file.bytes!, allowMalformed: true)
        : file.path != null
            ? await File(file.path!).readAsString()
            : null;
    if (script == null || script.trim().isEmpty) {
      throw const FormatException('无法读取脚本内容');
    }
    final info = await repository.importScript(script, fileName: file.name);
    notifyListeners();
    return info;
  }

  Future<CustomSourceInfo?> importSourceFromUrl(String rawUrl) async {
    final uri = _parseUrl(rawUrl);
    if (sources.length >= 20) {
      throw const FormatException('最多只能同时存在 20 个自定义源');
    }

    importing = true;
    notifyListeners();
    try {
      final script = await _downloadScript(uri);
      final fileName = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'remote_source.js';
      final info = await repository.importScript(
        script,
        fileName: fileName.isEmpty ? 'remote_source.js' : fileName,
        importUrl: uri.toString(),
      );
      notifyListeners();
      return info;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  /// Re-download an imported source from its saved URL, keeping the same id.
  Future<CustomSourceInfo> updateSourceFromUrl(CustomSourceInfo source) async {
    final rawUrl = source.importUrl;
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      throw const FormatException('该自定义源没有保存在线 URL');
    }
    final uri = _parseUrl(rawUrl);
    importing = true;
    notifyListeners();
    try {
      final script = await _downloadScript(uri);
      final updated = await repository.updateScript(
        source.id,
        script,
        importUrl: uri.toString(),
      );
      notifyListeners();
      // The script changed, so its cached sandbox must run the new code once.
      _slots.remove(updated.id);
      if (active?.id == updated.id || _initializing.isEmpty) {
        await _initialize(updated);
      }
      return updated;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  Uri _parseUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('请输入有效的 http / https 链接');
    }
    return uri;
  }

  Future<String> _downloadScript(Uri uri) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        sendTimeout: const Duration(seconds: 15),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
        followRedirects: true,
        maxRedirects: 5,
        headers: const <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
          'Accept': 'application/javascript, text/javascript, text/plain, */*',
        },
      ),
    );
    final response = await dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    final script = response.data;
    if (script == null || script.trim().isEmpty) {
      throw const FormatException('下载内容为空');
    }
    if (script.length > 1024 * 1024) {
      throw const FormatException('脚本超过 1 MiB，已拒绝导入');
    }
    return script;
  }

  /// One-tap refresh of every source that remembers the URL it came from.
  /// Locally imported scripts have nothing to re-fetch and are counted as
  /// skipped. Each refreshed script drops its cached sandbox, so the engine
  /// pool runs the new code the next time that source is used.
  Future<SourceRefreshResult> updateAllFromUrls() async {
    final targets = sources
        .where((source) => (source.importUrl ?? '').trim().isNotEmpty)
        .toList();
    final skipped = sources.length - targets.length;
    var updated = 0;
    final failed = <String>[];
    debugLog?.record('全局刷新开始', <String, Object?>{
      '待更新': targets.length,
      '跳过（无 URL）': skipped,
      '源': targets.map((source) => source.name).join('、'),
    });
    importing = true;
    notifyListeners();
    try {
      for (final source in targets) {
        final rawUrl = source.importUrl!.trim();
        try {
          final script = await _downloadScript(_parseUrl(rawUrl));
          await repository.updateScript(source.id, script, importUrl: rawUrl);
          _slots.remove(source.id);
          _supported.remove(source.id);
          updated++;
          debugLog?.record('全局刷新成功 ${source.name}', <String, Object?>{
            'URL': rawUrl,
            '脚本长度': script.length,
          });
        } catch (e) {
          failed.add('${source.name}: $e');
          debugLog?.record('全局刷新失败 ${source.name}', <String, Object?>{
            'URL': rawUrl,
            '原因': '$e',
          });
        }
        notifyListeners();
      }
    } finally {
      importing = false;
      notifyListeners();
    }
    final current = active;
    if (current != null) await _initialize(current);
    debugLog?.record('全局刷新结束', <String, Object?>{
      '成功': updated,
      '失败': failed.length,
      '跳过': skipped,
    });
    return SourceRefreshResult(
      updated: updated,
      failed: failed,
      skipped: skipped,
    );
  }

  Future<void> deleteSource(String id) async {
    await repository.delete(id);
    _supported.remove(id);
    _slots.remove(id);
    if (appState.settings.activeSourceId == id) {
      await setActive(null);
    } else {
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> resolveMusicUrl(Song song, {String? quality}) async {
    final source = active;
    if (source == null) {
      throw StateError('尚未启用自定义源。请先到「设置 → 自定义源」导入并启用音源脚本。');
    }
    return _resolveVia(source, song, quality: quality);
  }

  Future<Map<String, dynamic>> _resolveVia(
    CustomSourceInfo source,
    Song song, {
    String? quality,
  }) async {
    final slot = _slots[source.id];
    if (slot == null) {
      throw StateError(error ?? '自定义源尚未初始化完成');
    }
    if (!slot.ready || slot.capabilities.isEmpty) {
      throw StateError(error ?? '自定义源尚未初始化完成');
    }
    if (!slot.capabilities.supports(song.source, 'musicUrl')) {
      throw StateError('当前自定义源不支持 ${song.source.toUpperCase()} 的音源');
    }
    final supported = slot.capabilities.qualitysFor(song.source);
    var targetQuality = quality ?? appState.settings.quality;
    if (supported.isNotEmpty && !supported.contains(targetQuality)) {
      const order = <String>['128k', '320k', 'flac', 'flac24bit'];
      final requestedIndex = order.indexOf(targetQuality);
      String? fallback;
      for (final item in supported) {
        final index = order.indexOf(item);
        if (index >= 0 && requestedIndex >= 0 && index <= requestedIndex) {
          fallback = item;
        }
      }
      targetQuality = fallback ?? supported.first;
    }
    const order = <String>['flac24bit', 'flac', '320k', '128k'];
    final targetIndex = order.indexOf(targetQuality);
    final candidates = supported
        .where((item) => order.contains(item) && order.indexOf(item) >= targetIndex)
        .toList()
      ..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    final tryQualitys = supported.isEmpty
        ? <String>[targetQuality]
        : candidates.toList();
    if (tryQualitys.isEmpty) tryQualitys.add(targetQuality);

    Object? lastError;
    for (final currentQuality in tryQualitys) {
      final attemptId = 'url_${DateTime.now().microsecondsSinceEpoch % 100000}';
      debugLog?.record('解析 $attemptId → ${source.name}', <String, Object?>{
        '歌曲': '${song.name} - ${song.singer}',
        '平台': song.source,
        '音质': currentQuality,
      });
      try {
        final result = await slot.engine.requestMusicUrl(
          source: song.source,
          quality: currentQuality,
          song: song,
        );
        slot.lastUsed = DateTime.now();
        final data = result['data'];
        if (data is! Map) throw StateError('自定义源返回格式错误');
        final url = '${data['url'] ?? ''}';
        if (url.isEmpty) throw StateError('自定义源没有返回播放链接');
        debugLog?.record('解析成功 $attemptId → ${source.name}', <String, Object?>{
          '音质': currentQuality,
          '地址': url,
        });
        return <String, dynamic>{
          'url': url,
          'type': '${data['type'] ?? currentQuality}',
        };
      } catch (error) {
        lastError = error;
        debugLog?.record('解析失败 $attemptId → ${source.name}', <String, Object?>{
          '音质': currentQuality,
          '原因': '$error',
        });
      }
    }
    throw lastError ?? StateError('自定义源没有返回播放链接');
  }

  /// Resolve a playable URL while keeping the user's selection untouched.
  /// Always tries the selected source first; when it cannot serve this song,
  /// other imported sources are probed in the background (each initialized
  /// once and then cached in the engine pool). Whichever source answers gets
  /// remembered for this song's platform, but the next song starts from the
  /// selected source again — the user never sees a "source switch".
  Future<Map<String, dynamic>> resolveMusicUrlAutoSwitch(
    Song song, {
    String? quality,
  }) async {
    if (song.isLocal) {
      return <String, dynamic>{'url': song.localPath, 'type': 'local'};
    }

    final selected = active;
    if (selected == null) {
      throw StateError('尚未启用自定义源。请先到「设置 → 自定义源」导入并启用音源脚本。');
    }

    _lastPoolError = null;
    debugLog?.record('取链开始 ${song.name} - ${song.singer}', <String, Object?>{
      '平台': song.source,
      '首选源': selected.name,
    });

    final candidates = <CustomSourceInfo>[selected];
    final others = sources.where((source) => source.id != selected.id).toList()
      ..sort((a, b) {
        final aSupports = _supported[a.id]?.contains(song.source) ?? false;
        final bSupports = _supported[b.id]?.contains(song.source) ?? false;
        if (aSupports != bSupports) return aSupports ? -1 : 1;
        return 0;
      });
    candidates.addAll(others);

    Object? lastError;
    for (final candidate in candidates) {
      final slot = _slots[candidate.id];
      if (slot == null || !slot.ready) {
        await _initialize(candidate);
      }
      final live = _slots[candidate.id];
      if (live == null || !live.ready || !live.capabilities.supports(song.source, 'musicUrl')) {
        lastError ??= StateError(
          '没有可用的自定义源支持 ${song.source.toUpperCase()} 的音源',
        );
        continue;
      }
      try {
        final resolved = await _resolveVia(candidate, song, quality: quality);
        _supported.putIfAbsent(candidate.id, () => <String>{}).add(song.source);
        return resolved;
      } catch (error) {
        lastError = error;
        _lastPoolError = '${candidate.name}: $error';
      }
    }
    final failure = lastError ?? StateError('没有可用的自定义源返回播放链接');
    debugLog?.record('取链全部失败 ${song.name}', <String, Object?>{
      '最后错误': _lastPoolError ?? '$failure',
      '尝试源数': candidates.length,
    });
    throw failure;
  }

  @override
  void dispose() {
    _slots.clear();
    super.dispose();
  }
}

/// Outcome of a batch refresh: how many scripts were replaced, which ones could
/// not be reached, and how many sources had no URL to refresh from.
class SourceRefreshResult {
  const SourceRefreshResult({
    required this.updated,
    required this.failed,
    required this.skipped,
  });

  final int updated;
  final List<String> failed;
  final int skipped;
}
