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
import '../services/online_engine.dart';
import '../services/source_engine.dart';
import '../services/source_hub.dart';
import '../services/url_probe.dart';
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
    this.onlineEngine,
  });

  /// Keep at most this many live sandboxes; the least recently used idle one is
  /// unmounted when a new source pushes past the cap.
  static const int _maxLiveEngines = 8;

  final CustomSourceRepository repository;
  final HttpBridge http;
  final AppState appState;
  final DebugLog? debugLog;

  /// Used by the batch probe to fetch a real song per platform; a hub candidate
  /// is only called usable when its link resolves against such a song.
  final OnlineEngine? onlineEngine;

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

  /// Batch scan state, shown as a progress line on the 自定义源 page while the
  /// hub list is being fetched, downloaded and (for 自动导入源) re-probed here.
  bool hubWorking = false;
  String hubStatus = '';
  int hubDone = 0;
  int hubTotal = 0;
  bool _hubCancelRequested = false;

  final SourceHub _hub = SourceHub();

  /// A probe needs a real song per platform; the first search result is cached
  /// so a 20-candidate scan only pays for the search once per platform.
  final Map<String, Song?> _hubTestSongs = <String, Song?>{};

  /// Ask the running batch scan to stop after its current candidate.
  void cancelHubScan() {
    if (!hubWorking) return;
    _hubCancelRequested = true;
    hubStatus = '正在停止…';
    notifyListeners();
  }

  List<CustomSourceInfo> get sources => repository.sources;

  /// Sources that take part in playback: disabled scripts are kept imported and
  /// refreshable but never asked for a link.
  List<CustomSourceInfo> get enabledSources => repository.sources
      .where((source) => !source.disabled)
      .toList(growable: false);

  CustomSourceInfo? get active {
    final id = appState.settings.activeSourceId;
    if (id == null) return null;
    final source = repository.byId(id);
    return source == null || source.disabled ? null : source;
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

  /// Switch a source out of playback without deleting it. The stored selection
  /// is kept, so re-enabling the active source makes it take over again at once.
  Future<void> setDisabled(CustomSourceInfo source, bool disabled) async {
    await repository.setDisabled(source.id, disabled);
    debugLog?.record(disabled ? '源已禁用 ${source.name}' : '源已启用 ${source.name}', <String, Object?>{
      'id': source.id,
      '在线 URL': source.importUrl ?? '本地导入',
    });
    notifyListeners();
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

  /// Create the sandbox for [id] if needed and let [EngineHost] mount it. The
  /// page-load future must not start waiting before the web view exists, so a
  /// freshly created slot gets one frame first; a backgrounded app produces no
  /// frames, hence the short timeout.
  Future<_SourceSlot> _mountSlot(String id) async {
    final existing = _slots[id];
    if (existing != null) {
      existing.lastUsed = DateTime.now();
      return existing;
    }
    final slot = _SourceSlot(SourceEngine(http), debugLog);
    _slots[id] = slot;
    _evictIfNeeded(id);
    notifyListeners();
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 600),
      onTimeout: () {},
    );
    slot.lastUsed = DateTime.now();
    return slot;
  }

  Future<void> _doInitialize(CustomSourceInfo source) async {
    final slot = await _mountSlot(source.id);

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
    if (sources.length >= CustomSourceRepository.maxSources) {
      throw const FormatException('最多只能同时存在 ${CustomSourceRepository.maxSources} 个自定义源');
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
    final targets = enabledSources
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

  /// Check one script against a real song with the same path playback uses,
  /// including the link check, so a dead source can be switched off instead of
  /// slowing every song down.
  Future<SourceProbeReport> probeSource(CustomSourceInfo source, {Song? song}) async {
    final started = DateTime.now();
    SourceProbeReport finish(bool ok, String headline, String detail) {
      debugLog?.record('探测${ok ? '通过' : '失败'} ${source.name}', <String, Object?>{
        '结论': headline,
        '详情': detail,
        '耗时': '${DateTime.now().difference(started).inMilliseconds}ms',
      });
      return SourceProbeReport(ok: ok, headline: headline, detail: detail);
    }

    final target = song;
    if (target == null || target.isLocal || target.source.isEmpty) {
      return finish(false, '缺少在线歌曲',
          '探测要拿真实歌曲信息去请求链接，请先播放一首在线歌曲再点探测。');
    }

    final current = _slots[source.id];
    if (current == null || !current.ready) await _initialize(source);
    final slot = _slots[source.id];
    if (slot == null || !slot.ready || slot.capabilities.isEmpty) {
      return finish(false, '脚本加载失败',
          '这个源初始化没成功，可能已失效或不是有效的 userApi 脚本。');
    }

    final platforms = slot.capabilities.sources.keys
        .where((name) => slot.capabilities.supports(name, 'musicUrl'))
        .toList();
    if (!slot.capabilities.supports(target.source, 'musicUrl')) {
      return finish(
        false,
        '不支持 ${target.source.toUpperCase()}',
        '可取链平台：${platforms.isEmpty ? '无' : platforms.join('、')}'
            '（测试曲为 ${target.source.toUpperCase()} ${target.name}）',
      );
    }

    try {
      final resolved = await _resolveVia(source, target);
      _supported.putIfAbsent(source.id, () => <String>{}).add(target.source);
      return finish(true, '${target.source.toUpperCase()} 可播', '${resolved['url'] ?? ''}');
    } catch (error) {
      return finish(false, '${target.source.toUpperCase()} 不可用', '$error');
    }
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
        // A script can resolve "successfully" and still hand back a link whose
        // host now answers 404 with an HTML page. Verifying it here lets the
        // cross-source pool move on instead of failing later inside the player.
        final probe = await probeAudioUrl(url);
        debugLog?.record('解析成功 $attemptId → ${source.name}', <String, Object?>{
          '音质': currentQuality,
          '地址': url,
          '探测': probe.networkFailed
              ? '请求失败（仍尝试播放）'
              : 'HTTP ${probe.status} ${probe.contentType.isEmpty ? '未知类型' : probe.contentType}',
          '长度': probe.length < 0 ? '未知' : probe.length,
          '耗时': '${probe.elapsedMs}ms',
        });
        if (probe.rejected) {
          throw StateError('返回的链接已失效（HTTP ${probe.status}）');
        }
        if (probe.notAudio) {
          throw StateError('返回的不是音频（${probe.contentType}）');
        }
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

    final enabled = enabledSources;
    final selected = active;
    if (selected == null) {
      throw StateError(
        enabled.isEmpty
            ? (sources.isEmpty
                ? '尚未导入自定义源。请先到「设置 → 自定义源」导入音源脚本。'
                : '所有自定义源都被禁用了。请到「自定义源」探测后启用可用的源。')
            : '尚未启用自定义源。请先到「设置 → 自定义源」导入并启用音源脚本。',
      );
    }

    _lastPoolError = null;
    debugLog?.record('取链开始 ${song.name} - ${song.singer}', <String, Object?>{
      '平台': song.source,
      '首选源': selected.name,
      '可用源': enabled.length,
      '已禁用': sources.length - enabled.length,
    });

    final candidates = <CustomSourceInfo>[selected];
    final others = enabled.where((source) => source.id != selected.id).toList()
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

  /// Fetch the lx-hub list and turn it into the seeds of one batch group.
  ///
  /// [selfProbe] is what separates the two entry points. `true`（自动导入源）
  /// re-checks every published script inside this app with the same path
  /// playback uses, because the hub's verdict is hours old and its backend can
  /// already be dead; `false`（web探测导入源） trusts that daily scan and only
  /// needs the script text. Nothing is written here — the caller shows the
  /// verdicts and only [applyHubGroup] replaces the group.
  Future<HubImportOutcome> scanHubSources({
    required String group,
    required bool selfProbe,
    int? maxCandidates,
  }) async {
    if (hubWorking) {
      return HubImportOutcome(
        group: group,
        candidates: const <HubCandidateResult>[],
        seeds: const <SourceSeed>[],
        poolSize: 0,
        error: '已有一批源在获取中，请等待它结束',
      );
    }
    hubWorking = true;
    _hubCancelRequested = false;
    hubDone = 0;
    hubTotal = 0;
    hubStatus = '正在读取 lx-hub 源列表…';
    notifyListeners();

    final candidates = <HubCandidateResult>[];
    final seeds = <SourceSeed>[];
    String? failure;
    DateTime? generatedAt;
    var poolSize = 0;
    var cancelled = false;

    try {
      final index = await _hub.fetchIndex();
      generatedAt = index.generatedAt;
      final published = index.entries
          .where((entry) => entry.name.trim().isNotEmpty)
          .toList(growable: false);
      poolSize = published.length;
      // The static export only contains scripts the hub could resolve, so for a
      // trusted import that is the whole pool; for a self-probe the web verdict
      // is only a hint about which platform to test first.
      final usableFirst = <HubSourceEntry>[
        ...published.where((entry) => entry.hasUsablePlatform),
        ...published.where((entry) => !entry.hasUsablePlatform),
      ];
      // A self-probe costs tens of seconds per script, so it is capped harder
      // than the trusted web import, which only downloads.
      final cap = maxCandidates ?? (selfProbe ? 15 : 25);
      final targets = selfProbe
          ? usableFirst.take(cap).toList(growable: false)
          : usableFirst
              .where((entry) => entry.hasUsablePlatform)
              .take(cap)
              .toList(growable: false);

      hubTotal = targets.length;
      hubStatus = selfProbe
          ? '共 ${targets.length} 个候选，逐个实测取链…'
          : '共 ${targets.length} 个可用源，正在取回脚本…';
      notifyListeners();

      for (final entry in targets) {
        if (_hubCancelRequested) {
          cancelled = true;
          break;
        }
        hubStatus = '正在检测「${entry.name}」';
        notifyListeners();

        HubDownload? download;
        try {
          download = await _hub.downloadFirst(entry.downloadCandidates);
        } catch (error) {
          candidates.add(HubCandidateResult(
            entry: entry,
            ok: false,
            detail: '脚本下载失败：$error',
          ));
          hubDone++;
          notifyListeners();
          continue;
        }

        List<String> platforms;
        String detail;
        if (selfProbe) {
          final verdict = await _probeHubCandidate(entry, download.script);
          platforms = verdict.platforms;
          detail = verdict.detail;
        } else {
          platforms = entry.usablePlatforms;
          detail = '${entry.platformSummary}（web 实测）';
        }

        candidates.add(HubCandidateResult(
          entry: entry,
          ok: platforms.isNotEmpty,
          detail: detail,
          platforms: platforms,
        ));
        if (platforms.isNotEmpty) {
          seeds.add(SourceSeed(
            script: download.script,
            importUrl: download.url,
            label: entry.name,
            platforms: platforms,
          ));
        }
        hubDone++;
        notifyListeners();
      }
    } catch (error) {
      failure = '$error';
    } finally {
      hubWorking = false;
      hubStatus = '';
      hubDone = 0;
      hubTotal = 0;
      notifyListeners();
    }

    debugLog?.record('批量获取源结束', <String, Object?>{
      '分组': sourceGroupName(group),
      '候选': poolSize,
      '通过': seeds.length,
      '失败': candidates.length - seeds.length,
      '取消': cancelled,
      if (failure != null) '错误': failure,
    });

    return HubImportOutcome(
      group: group,
      candidates: candidates,
      seeds: seeds,
      poolSize: poolSize,
      error: failure,
      cancelled: cancelled,
      generatedAt: generatedAt,
    );
  }

  /// Run one published script through the real playback path: mount a throwaway
  /// sandbox, activate it, then resolve a song we fetched for each platform the
  /// script claims. Only a link that serves audio counts.
  Future<HubCandidateResult> _probeHubCandidate(
    HubSourceEntry entry,
    String script,
  ) async {
    final temp = CustomSourceInfo(
      id: 'hub_probe_${entry.id}',
      name: entry.name,
      author: entry.author,
      version: entry.version,
    );
    try {
      final slot = await _mountSlot(temp.id);
      try {
        slot.capabilities = await slot.engine.activate(temp, script);
        slot.ready = true;
      } catch (error) {
        return HubCandidateResult(
          entry: entry,
          ok: false,
          detail: '脚本加载失败：$error',
        );
      }

      final supported = slot.capabilities.sources.keys
          .where((name) => slot.capabilities.supports(name, 'musicUrl'))
          .toList();
      if (supported.isEmpty) {
        return HubCandidateResult(
          entry: entry,
          ok: false,
          detail: '脚本没有声明任何可取链平台',
        );
      }

      // Try what the hub says works first, then everything else it claims.
      final preferred = entry.usablePlatforms.where(supported.contains).toList();
      final order = <String>[
        ...preferred,
        ...supported.where((name) => !preferred.contains(name)),
      ];

      String lastError = '';
      for (final platform in order.take(2)) {
        final song = await _testSongFor(platform);
        if (song == null) {
          lastError = '无法获取 ${hubPlatformLabel(platform)} 的测试歌曲';
          continue;
        }
        try {
          // Low quality on purpose: a scan asks "does this script serve real
          // audio at all", and 128k is the cheapest link to prove it. The whole
          // attempt is deadline-bound so one hung script cannot stall the batch.
          await _resolveVia(temp, song, quality: '128k')
              .timeout(const Duration(seconds: 25));
          _supported.putIfAbsent(temp.id, () => <String>{}).add(platform);
          return HubCandidateResult(
            entry: entry,
            ok: true,
            detail: '${hubPlatformLabel(platform)} 实测返回真实音频'
                '（${song.name} - ${song.singer}）',
            platforms: <String>[platform],
          );
        } on TimeoutException {
          lastError = '${hubPlatformLabel(platform)} 取链超时（25s）';
        } catch (error) {
          lastError = '$error';
        }
      }
      return HubCandidateResult(
        entry: entry,
        ok: false,
        detail: '取链失败：$lastError',
        platforms: const <String>[],
      );
    } finally {
      _slots.remove(temp.id);
      _supported.remove(temp.id);
      notifyListeners();
    }
  }

  Future<Song?> _testSongFor(String platform) async {
    if (_hubTestSongs.containsKey(platform)) return _hubTestSongs[platform];
    final engine = onlineEngine;
    Song? found;
    if (engine != null) {
      for (final keyword in const <String>['海阔天空', '晴天']) {
        try {
          final result = await engine.call('searchMusic', <String, dynamic>{
            'source': platform,
            'keyword': keyword,
            'page': 1,
            'limit': 5,
          });
          final map = result is Map
              ? Map<String, dynamic>.from(result)
              : <String, dynamic>{};
          final list = map['list'];
          if (list is List) {
            for (final item in list.whereType<Map>()) {
              final song = Song.fromOnline(Map<String, dynamic>.from(item));
              if (song.id.isNotEmpty && !song.isLocal) {
                found = song;
                break;
              }
            }
          }
        } catch (_) {
          found = null;
        }
        if (found != null) break;
      }
    }
    _hubTestSongs[platform] = found;
    return found;
  }

  /// Overwrite one batch group with the seeds the user just approved.
  Future<int> applyHubGroup(String group, List<SourceSeed> seeds) async {
    if (seeds.isEmpty) return 0;
    final added = await repository.replaceGroup(group, seeds);
    // Scripts that the scan replaced no longer exist; drop their sandboxes.
    _slots.removeWhere((id, _) => repository.byId(id) == null);
    _supported.removeWhere((id, _) => repository.byId(id) == null);
    notifyListeners();
    if (active == null && added.isNotEmpty) {
      await setActive(added.first);
    }
    debugLog?.record('批量导入源完成', <String, Object?>{
      '分组': sourceGroupName(group),
      '写入': added.length,
      '源': added.map((source) => source.name).join('、'),
    });
    return added.length;
  }

  /// 一键清空 of a batch group. Hand-imported sources are never included.
  Future<int> clearHubGroup(String group) async {
    final removed = await repository.clearGroup(group);
    if (removed == 0) return 0;
    _slots.removeWhere((id, _) => repository.byId(id) == null);
    _supported.removeWhere((id, _) => repository.byId(id) == null);
    if (active == null && appState.settings.activeSourceId != null) {
      await setActive(null);
    } else {
      notifyListeners();
    }
    debugLog?.record('清空分组 $group', <String, Object?>{'删除': removed});
    return removed;
  }

  @override
  void dispose() {
    _slots.clear();
    super.dispose();
  }
}

/// One hub candidate and the verdict the scan reached about it.
class HubCandidateResult {
  const HubCandidateResult({
    required this.entry,
    required this.ok,
    required this.detail,
    this.platforms = const <String>[],
  });

  final HubSourceEntry entry;
  final bool ok;

  /// What passed or why it did not — shown verbatim in the review dialog.
  final String detail;

  /// Platforms whose link resolution served real audio (self-probe only).
  final List<String> platforms;
}

/// Result of a batch scan, before the user confirms the overwrite.
class HubImportOutcome {
  const HubImportOutcome({
    required this.group,
    required this.candidates,
    required this.seeds,
    required this.poolSize,
    this.error,
    this.cancelled = false,
    this.generatedAt,
  });

  final String group;
  final List<HubCandidateResult> candidates;

  /// Scripts that passed, ready to replace the group.
  final List<SourceSeed> seeds;

  /// How many published scripts the list had before the candidate cap.
  final int poolSize;

  final String? error;
  final bool cancelled;

  /// When the hub last ran its own scan.
  final DateTime? generatedAt;

  List<HubCandidateResult> get usable =>
      candidates.where((item) => item.ok).toList(growable: false);

  List<HubCandidateResult> get dead =>
      candidates.where((item) => !item.ok).toList(growable: false);

  bool get hasUsable => usable.isNotEmpty;
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

/// Verdict of a single-source probe, shown on the source page and mirrored into
/// the debug log.
class SourceProbeReport {
  const SourceProbeReport({
    required this.ok,
    required this.headline,
    required this.detail,
  });

  final bool ok;
  final String headline;
  final String detail;
}
