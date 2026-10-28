import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:webview_flutter/webview_flutter.dart';

import '../data/custom_source_repository.dart';
import '../models/custom_source.dart';
import '../models/song.dart';
import '../services/debug_log.dart';
import '../services/http_bridge.dart';
import '../services/js_source_engine.dart';
import '../services/music_source_engine.dart';
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
    bindLog(log);
  }

  /// Starts as the in-process engine; [SourceState] replaces it with a
  /// [SourceEngine] when the JS runtime cannot run the script.
  MusicSourceEngine engine;
  SourceCapabilities capabilities = SourceCapabilities.empty();
  bool ready = false;
  DateTime lastUsed = DateTime.now();

  void bindLog(DebugLog? log) {
    if (log != null) {
      engine.onEvent = (title, fields) => log.record(title, fields);
    }
  }
}

class SourceState extends ChangeNotifier with WidgetsBindingObserver {
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

  /// Live sandboxes allowed right now: the cap above, plus one per concurrent
  /// batch worker while a scan or probe is running (see [_beginHubRun]).
  int _liveEngineCap = _maxLiveEngines;

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

  /// Batch state, shown as a progress line on the 自定义源 page while the hub list
  /// is being fetched, downloaded and then measured one source at a time.
  bool hubWorking = false;
  String hubStatus = '';
  int hubDone = 0;
  int hubTotal = 0;
  bool _hubCancelRequested = false;

  /// Completed by [cancelHubScan] so the step that is *currently running* can be
  /// abandoned at once instead of only being noticed when it happens to finish.
  /// Recreated by every batch entry point.
  Completer<void>? _hubAbort;

  final SourceHub _hub = SourceHub();

  /// Index from the most recent hub scan, kept so a batch probe can tell which
  /// platform a previously imported script claimed ([_hubEntryFor]).
  List<HubSourceEntry>? _hubIndex;

  /// Sandbox ids a running batch is working on. They are exempt from eviction
  /// for exactly as long as they are being probed: without that, a second worker
  /// mounting its own sandbox could unmount the one the first is mid-resolve on.
  final Set<String> _pinned = <String>{};

  /// How many sources the current batch has in flight, and how long one source
  /// may take. Both come from the user's 探测设置 when the run starts and are
  /// read from here so the progress line can show them.
  int _hubWorkers = 1;
  Duration _hubBudget = const Duration(seconds: 30);

  /// How many published scripts one update pulls at most. The hub's daily list is
  /// longer, but every imported script is measured afterwards, and measuring
  /// dozens of them on a phone is a far longer call than anyone waited for.
  static const int _hubImportCap = 30;

  /// A self-started update waits this long after launch — long enough that the
  /// sources already installed have taken over playback — and runs at most once
  /// per [interval] so a frequently-reopened app does not refetch the world.
  static const Duration _autoRefreshLead = Duration(seconds: 60);
  static const Duration _autoRefreshInterval = Duration(hours: 24);

  Timer? _autoRefreshTimer;
  bool _disposed = false;

  /// Whether the app is on screen. Measuring a source runs the script inside a
  /// WebView, and its JavaScript is frozen behind the lock screen — so a run that
  /// drifts into the background is stopped rather than allowed to keep going,
  /// because every measurement from there would time out and a timeout is recorded
  /// as a dead source.
  bool _foreground = true;

  /// A probe needs a real song per platform; the first search result is cached
  /// so a 20-candidate scan only pays for the search once per platform.
  final Map<String, Song?> _hubTestSongs = <String, Song?>{};

  /// The search that is currently filling [_hubTestSongs] for a platform. Workers
  /// start at the same moment, so without this two of them would search the same
  /// platform twice and the batch would pay for a slow search once per worker.
  final Map<String, Future<Song?>> _testSongRequests = <String, Future<Song?>>{};

  /// Ask the running batch — a hub scan or a group probe — to stop.
  void cancelHubScan() {
    if (!hubWorking) return;
    _hubCancelRequested = true;
    final abort = _hubAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    hubStatus = '正在停止…';
    notifyListeners();
  }

  void _beginHubRun(String initialStatus) {
    final settings = appState.settings;
    _hubWorkers = settings.probeConcurrencyClamped;
    _hubBudget = settings.probeDeadline;
    hubWorking = true;
    _hubCancelRequested = false;
    _hubAbort = Completer<void>();
    hubDone = 0;
    hubTotal = 0;
    hubStatus = initialStatus;
    // Every worker holds its own sandbox, so the pool that is used while a batch
    // runs is as much larger as the concurrency the user asked for.
    _liveEngineCap = _maxLiveEngines + _hubWorkers;
    notifyListeners();
  }

  void _endHubRun() {
    hubWorking = false;
    _hubAbort = null;
    hubStatus = '';
    hubDone = 0;
    hubTotal = 0;
    _pinned.clear();
    _testSongRequests.clear();
    _liveEngineCap = _maxLiveEngines;
    notifyListeners();
  }

  /// Run a long step while a batch is allowed to be abandoned, optionally giving
  /// up on it after [budget].
  ///
  /// Futures cannot be cancelled, so checking [_hubCancelRequested] only between
  /// candidates made one press wait out whatever the current candidate was busy
  /// with — up to two 取链 attempts, or a script that never answers at all. That
  /// is why 停止 felt dead. The step is raced against the abort signal instead, so
  /// a press returns the batch immediately. The abandoned step keeps running to
  /// completion in the background; its result and any late failure are drained on
  /// purpose, otherwise a script that finally throws after the user walked away
  /// would surface as an uncaught asynchronous error.
  ///
  /// The timeout is a third racer for the same reason: [Future.timeout] would left
  /// a script that answers after its deadline throwing into a future nobody
  /// listens to anymore. A source that runs out of budget is left exactly as it
  /// was — a slow answer says nothing about whether the link is alive, and the
  /// batch only ever switches off scripts that proved they cannot serve one.
  Future<T> _hubGuarded<T>(
    Future<T> Function() step, {
    Duration? budget,
  }) async {
    final abort = _hubAbort;
    final work = step();
    final tags = <Future<List<Object?>>>[
      work.then<List<Object?>>(
        (value) => <Object?>[_HubStepState.done, value, null],
        onError: (Object error) => <Object?>[_HubStepState.failed, null, error],
      ),
    ];
    if (abort != null) {
      tags.add(abort.future.then<List<Object?>>(
        (_) => <Object?>[_HubStepState.aborted, null, null],
      ));
    }
    Timer? timer;
    if (budget != null) {
      final deadline = Completer<void>();
      timer = Timer(budget, () {
        if (!deadline.isCompleted) deadline.complete();
      });
      tags.add(deadline.future.then<List<Object?>>(
        (_) => <Object?>[_HubStepState.timedOut, null, null],
      ));
    }
    final raced = await Future.any<List<Object?>>(tags);
    timer?.cancel();
    if (raced[0] == _HubStepState.aborted) {
      unawaited(work.then<void>((_) {}, onError: (Object _) {}));
      throw const HubScanCancelled();
    }
    if (raced[0] == _HubStepState.timedOut) {
      unawaited(work.then<void>((_) {}, onError: (Object _) {}));
      throw _HubProbeTimeout(budget!);
    }
    if (raced[0] == _HubStepState.done) return raced[1] as T;
    throw raced[2]!;
  }

  /// Run [step] over [items] with at most [workers] of them in flight at once.
  ///
  /// Dart ships no helper for this shape, so the pool is a shared cursor: each
  /// worker takes the next index until the list is empty, and a verdict is stored
  /// in the slot of its own index rather than appended, so the result the user
  /// reads still follows the order of the list on screen. [step] is expected to
  /// classify its own failures; anything that still escapes ends the batch, which
  /// is what 停止 does.
  Future<void> _runPool<T>(
    List<T> items,
    int workers,
    Future<void> Function(T item, int index) step,
  ) async {
    var next = 0;
    Future<void> runner() async {
      while (!_hubCancelRequested) {
        final index = next++;
        if (index >= items.length) return;
        await step(items[index], index);
      }
    }

    final count = workers < items.length ? workers : items.length;
    await Future.wait(
      List<Future<void>>.generate(
        count < 1 ? 1 : count,
        (_) => runner(),
        growable: false,
      ),
    );
  }

  /// Values 探测设置 offers to the batch entry points, so the sheet can show what
  /// the next run will use even while a run is already under way.
  int get probeConcurrency => appState.settings.probeConcurrencyClamped;

  int get probeTimeoutSeconds => appState.settings.probeTimeoutClamped;

  /// Where the batch stands: the first line names the whole run, then each worker
  /// announces what it picked up. With more than one worker the per-source line is
  /// only the most recent start, so it says what it means rather than pretending
  /// to be the one thing being tested.
  String _hubScanIntro(int total) {
    final mode = _hubWorkers > 1 ? '并发 $_hubWorkers 路' : '逐个';
    return '共 $total 个可用源，$mode取回脚本（每个 ${_hubBudget.inSeconds}s 上限）…';
  }

  String _hubActivity(String name) {
    if (_hubWorkers <= 1) return '正在取回「$name」';
    return '取回中：「$name」（$_hubWorkers 路并发）';
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

  /// True when the selected source's script runs in-process, so links can still
  /// be resolved while iOS has frozen every WKWebView behind the lock screen.
  bool get canResolveInBackground {
    final source = active;
    if (source == null) return false;
    final slot = _slots[source.id];
    if (slot == null) return true;
    return slot.engine is JsSourceEngine;
  }

  /// Why the previous cross-source resolution failed (null after a success).
  String? get lastPoolError => _lastPoolError;

  /// Bumped by [cancelResolutions]; a pool walk compares it between candidates and
  /// gives up when it no longer matches the generation it started with.
  int _resolveGeneration = 0;

  /// Give up on the cross-source pool walk currently in flight.
  ///
  /// A skip pressed on a headset or a car head unit has to be able to take over.
  /// Without this the abandoned walk keeps going through every remaining source —
  /// each with its own quality ladder and its own engine timeout — so the queue
  /// stays parked on a song nobody is waiting for, and the next tap queues behind
  /// it instead of fetching a link.
  void cancelResolutions({String? reason}) {
    _resolveGeneration++;
    debugLog?.record('取消进行中的取链', <String, Object?>{'原因': reason});
  }

  bool get loading => _initializing.containsKey(active?.id ?? '');

  /// Controllers of every live sandbox. [EngineHost] must keep these mounted
  /// off-screen, otherwise their WKWebViews never run.
  List<WebViewController> get engineControllers => _slots.values
      .map((slot) => slot.engine.controller)
      .whereType<WebViewController>()
      .toList(growable: false);

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
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

  /// Keep playback pointing at a source after a batch operation moved them around.
  ///
  /// [resolveMusicUrlAutoSwitch] refuses to try the pool at all when nothing is
  /// selected, so a run that replaced or deleted the selected script would leave a
  /// page full of freshly measured sources while every song reported
  /// 「尚未启用自定义源」. Selection is the one thing a batch cannot leave dangling:
  /// prefer the ids in [preferredIds] (a run passes the ones it just proved can
  /// serve a link), otherwise take the first enabled source. When nothing is left
  /// enabled the stale id is cleared so the page reads 未启用 instead of naming a
  /// source that no longer exists.
  Future<CustomSourceInfo?> _ensureActiveSource({
    List<String> preferredIds = const <String>[],
  }) async {
    final current = active;
    if (current != null) return current;
    final previous = appState.settings.activeSourceId;
    final enabled = enabledSources;
    if (enabled.isEmpty) {
      if (previous != null) await setActive(null);
      return null;
    }
    CustomSourceInfo? next;
    for (final id in preferredIds) {
      for (final candidate in enabled) {
        if (candidate.id == id) {
          next = candidate;
          break;
        }
      }
      if (next != null) break;
    }
    next ??= enabled.first;
    await setActive(next);
    debugLog?.record('批量操作后自动选用源', <String, Object?>{
      '源': next.name,
      '原因': previous == null ? '原先没有选中' : '原先选中的已不可用',
    });
    return next;
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
    // Prefer the in-process engine: it keeps resolving URLs while iOS has
    // frozen the WKWebView content process behind the lock screen. It starts
    // lazily, so a failure is detected (and recovered from) in _activateSlot.
    final slot = _SourceSlot(JsSourceEngine(http), debugLog);
    _slots[id] = slot;
    _evictIfNeeded(id);
    notifyListeners();
    // A WebView only starts loading once EngineHost has mounted it; the JS
    // engine needs no frame at all.
    if (slot.engine.controller != null) {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );
    }
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
      slot.capabilities = await _activateSlot(slot, source, script);
      final names = <String>{};
      for (final name in slot.capabilities.sources.keys) {
        if (slot.capabilities.supports(name, 'musicUrl')) names.add(name);
      }
      _supported[source.id] = names;
      slot.ready = true;
      if (active?.id == source.id) error = null;
      debugLog?.record('源就绪 ${source.name}', <String, Object?>{
        '平台': names.join('、'),
        '引擎': slot.engine is JsSourceEngine ? 'JS（锁屏可用）' : 'WebView',
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

  /// Activate a source, transparently falling back to the WKWebView sandbox if
  /// the in-process JS runtime cannot start. The fallback is a one-way switch
  /// for this slot: a script the in-process runtime rejects is retried once in
  /// the same browser engine the app used before.
  Future<SourceCapabilities> _activateSlot(
    _SourceSlot slot,
    CustomSourceInfo source,
    String script,
  ) async {
    try {
      return await slot.engine.activate(source, script);
    } on JsEngineUnavailable catch (error) {
      if (slot.engine is! JsSourceEngine) rethrow;
      debugLog?.record('JS 后台引擎不可用，回退 WebView', <String, Object?>{
        '源': source.name,
        '原因': error.message,
      });
      await (slot.engine as JsSourceEngine).dispose();
      slot.engine = SourceEngine(http);
      slot.bindLog(debugLog);
      slot.ready = false;
      slot.capabilities = SourceCapabilities.empty();
      notifyListeners();
      // EngineHost must mount the new WebView before loadFlutterAsset runs.
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );
      return slot.engine.activate(source, script);
    }
  }

  void _dropSlot(String id) {
    final slot = _slots.remove(id);
    final engine = slot?.engine;
    if (engine is JsSourceEngine) {
      unawaited(engine.dispose());
    }
  }

  void _dropMissingSlots() {
    final stale = _slots.keys
        .where((id) => repository.byId(id) == null)
        .toList(growable: false);
    for (final id in stale) {
      _dropSlot(id);
      _supported.remove(id);
    }
    _supported.removeWhere((id, _) => repository.byId(id) == null);
  }

  void _evictIfNeeded(String keepId) {
    while (_slots.length >= _liveEngineCap) {
      String? victimId;
      _SourceSlot? victim;
      for (final entry in _slots.entries) {
        if (entry.key == keepId || entry.key == appState.settings.activeSourceId) continue;
        if (_initializing.containsKey(entry.key)) continue;
        // A batch worker is inside this sandbox right now; dropping it would make
        // the source look dead when all that happened is that a neighbour needed
        // the room.
        if (_pinned.contains(entry.key)) continue;
        if (victim == null || entry.value.lastUsed.isBefore(victim.lastUsed)) {
          victim = entry.value;
          victimId = entry.key;
        }
      }
      if (victimId == null) return;
      _dropSlot(victimId);
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
      _dropSlot(updated.id);
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
          _dropSlot(source.id);
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
    _dropSlot(id);
    if (appState.settings.activeSourceId == id) {
      // The song still needs a source to start from; hand over a live one rather
      // than leaving playback on 「尚未启用自定义源」.
      await _ensureActiveSource();
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
    int? generation,
    DateTime? deadline,
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
      _throwIfResolveAborted(generation: generation, deadline: deadline);
      final attemptId = 'url_${DateTime.now().microsecondsSinceEpoch % 100000}';
      final attemptStarted = DateTime.now();
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
          '脚本耗时': '${DateTime.now().difference(attemptStarted).inMilliseconds}ms',
          '探测耗时': '${probe.elapsedMs}ms',
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
          '耗时': '${DateTime.now().difference(attemptStarted).inMilliseconds}ms',
        });
      }
    }
    throw lastError ?? StateError('自定义源没有返回播放链接');
  }

  /// Raised between attempts of one resolve so a forced skip does not have to wait
  /// out the rest of the ladder.
  void _throwIfResolveAborted({int? generation, DateTime? deadline}) {
    if (generation != null && generation != _resolveGeneration) {
      throw StateError('取链已被新的播放请求取消');
    }
    if (deadline != null && DateTime.now().isAfter(deadline)) {
      throw StateError('取链已超过时限');
    }
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
    bool background = false,
    Duration? budget,
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
    final generation = _resolveGeneration;
    final startedAt = DateTime.now();
    final deadline = budget == null ? null : startedAt.add(budget);
    debugLog?.record('取链开始 ${song.name} - ${song.singer}', <String, Object?>{
      '平台': song.source,
      '首选源': selected.name,
      '可用源': enabled.length,
      '已禁用': sources.length - enabled.length,
      '后台': background,
      '预算': budget == null ? '不限' : '${budget.inSeconds}s',
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
    var tried = 0;
    for (final candidate in candidates) {
      tried++;
      // Checked *between* sources as well as between qualities: one source alone
      // can burn tens of seconds, and a user who already skipped past this song
      // must not pay for the rest of the list.
      final aborted = generation != _resolveGeneration ||
          (deadline != null && DateTime.now().isAfter(deadline));
      if (aborted) {
        final cancelled = generation != _resolveGeneration;
        debugLog?.record('取链中止 ${song.name}', <String, Object?>{
          '原因': cancelled ? '被新的播放请求取消' : '超过预算 ${budget?.inSeconds ?? 0}s',
          '已试源': tried,
          '剩余源': candidates.length - tried,
          '耗时': '${DateTime.now().difference(startedAt).inMilliseconds}ms',
        });
        throw StateError(cancelled ? '取链已被新的播放请求取消' : '取链已超过时限');
      }
      final existing = _slots[candidate.id];
      // Behind the lock screen a WebView sandbox cannot answer: its JavaScript
      // is frozen. Skipping those candidates immediately beats waiting for a
      // 30 s timeout for every source. A source with no live slot yet is still
      // worth initializing — new slots use the in-process engine.
      if (background && existing != null && existing.engine is! JsSourceEngine) {
        continue;
      }
      final slot = existing;
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
        final resolved = await _resolveVia(
          candidate,
          song,
          quality: quality,
          generation: generation,
          deadline: deadline,
        );
        _supported.putIfAbsent(candidate.id, () => <String>{}).add(song.source);
        return resolved;
      } catch (error) {
        // An abort is not a source failure — walking on to the next source would
        // rebuild exactly the delay the cancellation was meant to remove.
        if (generation != _resolveGeneration ||
            (deadline != null && DateTime.now().isAfter(deadline))) {
          rethrow;
        }
        lastError = error;
        _lastPoolError = '${candidate.name}: $error';
      }
    }
    final failure = lastError ?? StateError('没有可用的自定义源返回播放链接');
    debugLog?.record('取链全部失败 ${song.name}', <String, Object?>{
      '最后错误': _lastPoolError ?? '$failure',
      '已试源': tried,
      '候选源': candidates.length,
      '耗时': '${DateTime.now().difference(startedAt).inMilliseconds}ms',
    });
    throw failure;
  }

  /// Fetch the lx-hub list and turn it into the seeds of one batch group.
  ///
  /// The hub's own daily scan is taken at face value here: this step only needs
  /// the script text, and anything it imports gets measured by the app afterwards
  /// in [probeGroup] — the same path playback uses. Nothing is written here; the
  /// caller decides whether the group gets replaced.
  Future<HubImportOutcome> scanHubSources({
    required String group,
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
    _beginHubRun('正在读取 lx-hub 源列表…');

    final candidates = <HubCandidateResult>[];
    final seeds = <SourceSeed>[];
    String? failure;
    DateTime? generatedAt;
    var poolSize = 0;
    var cancelled = false;

    try {
      final index = await _hubGuarded(_hub.fetchIndex);
      _hubIndex = index.entries;
      generatedAt = index.generatedAt;
      final published = index.entries
          .where((entry) => entry.name.trim().isNotEmpty)
          .toList(growable: false);
      poolSize = published.length;
      // The static export lists the scripts the hub could resolve, together with
      // the platforms it managed on each. Those are the only useful candidates; a
      // script with no usable platform would just be imported and then disabled by
      // the measurement step.
      final cap = maxCandidates ?? _hubImportCap;
      final targets = published
          .where((entry) => entry.hasUsablePlatform)
          .take(cap)
          .toList(growable: false);

      hubTotal = targets.length;
      hubStatus = _hubScanIntro(targets.length);
      notifyListeners();

      // Indexed rather than appended: several workers finish out of order, and the
      // verdict sheet is far easier to read when it still matches the list on
      // screen.
      final verdicts = List<HubCandidateResult?>.filled(targets.length, null);
      final picked = List<SourceSeed?>.filled(targets.length, null);
      await _runPool(targets, _hubWorkers, (entry, index) async {
        hubStatus = _hubActivity(entry.name);
        notifyListeners();

        HubDownload download;
        try {
          download = await _hubGuarded(
            () => _hub.downloadFirst(entry.downloadCandidates),
            budget: _hubBudget,
          );
        } on HubScanCancelled {
          cancelled = true;
          return;
        } catch (error) {
          verdicts[index] = HubCandidateResult(
            entry: entry,
            ok: false,
            detail: error is _HubProbeTimeout
                ? '脚本下载超时（${_hubBudget.inSeconds}s）'
                : '脚本下载失败：$error',
          );
          hubDone++;
          notifyListeners();
          return;
        }

        final script = download.script;
        final scriptUrl = download.url;
        final platforms = entry.usablePlatforms;
        verdicts[index] = HubCandidateResult(
          entry: entry,
          ok: platforms.isNotEmpty,
          detail: '${entry.platformSummary}（web 实测）',
          platforms: platforms,
        );
        if (platforms.isNotEmpty) {
          picked[index] = SourceSeed(
            script: script,
            importUrl: scriptUrl,
            label: entry.name,
            platforms: platforms,
          );
        }
        hubDone++;
        notifyListeners();
      });

      candidates.addAll(verdicts.whereType<HubCandidateResult>());
      seeds.addAll(picked.whereType<SourceSeed>());
    } on HubScanCancelled {
      // 停止 pressed: the verdicts gathered so far are still worth showing, and
      // nothing is written until the user approves the list.
      cancelled = true;
    } catch (error) {
      failure = '$error';
    } finally {
      _endHubRun();
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

  Future<Song?> _testSongFor(String platform) {
    final cached = _hubTestSongs[platform];
    if (_hubTestSongs.containsKey(platform)) return Future.value(cached);
    // Several workers can ask for the same platform in the same instant. Sharing
    // one search keeps a slow platform from costing the batch a search per worker.
    final pending = _testSongRequests[platform];
    if (pending != null) return pending;
    final task = _searchTestSong(platform);
    _testSongRequests[platform] = task;
    return task.whenComplete(() => _testSongRequests.remove(platform));
  }

  Future<Song?> _searchTestSong(String platform) async {
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

  /// Batch version of tapping 探测 on every row of [group] by hand.
  ///
  /// Each imported script is mounted and asked for a real link against a song
  /// fetched for one of the platforms it claims, which is the same path playback
  /// uses. `web探测导入源` inherits the hub's *daily* verdict, so a whole group
  /// can quietly rot between refreshes; this is how the user finds out without
  /// pressing twenty buttons. Anything that cannot serve a link is switched off
  /// straight away — a dead script left enabled slows down every song, because
  /// playback waits for it before falling through to the next source.
  ///
  /// A source that could not be judged at all (no test song could be fetched for
  /// any of its platforms) keeps its current state: the batch punishes broken
  /// scripts, not an app that had nothing to test them with. Running out of the
  /// user's 探测超时 is a different matter — a script that cannot answer within
  /// the budget the user set is treated as unusable and gets disabled too.
  Future<GroupProbeOutcome> probeGroup(String group) async {
    if (hubWorking) {
      return GroupProbeOutcome(
        group: group,
        reports: const <GroupProbeReport>[],
        error: '已有一批源在检测中，请等待它结束',
      );
    }
    final targets = repository.byGroup(group);
    if (targets.isEmpty) {
      return GroupProbeOutcome(
        group: group,
        reports: const <GroupProbeReport>[],
        error: '「${sourceGroupName(group)}」里还没有源',
      );
    }
    _beginHubRun('「${sourceGroupName(group)}」共 ${targets.length} 个源，正在准备…');

    final reports = <GroupProbeReport>[];
    var cancelled = false;
    try {
      hubTotal = targets.length;
      hubStatus = '「${sourceGroupName(group)}」共 ${targets.length} 个源，'
          '${_hubWorkers > 1 ? '$_hubWorkers 路并发' : '逐个'}实测'
          '（每个 ${_hubBudget.inSeconds}s 上限）…';
      notifyListeners();

      // Indexed, exactly as in scanHubSources: workers finish out of order and the
      // sheet should still read like the list on screen.
      final verdicts = List<GroupProbeReport?>.filled(targets.length, null);
      await _runPool(targets, _hubWorkers, (source, index) async {
        hubStatus = _hubWorkers > 1
            ? '探测中：「${source.name}」（$_hubWorkers 路并发）'
            : '正在探测「${source.name}」';
        notifyListeners();

        // The slot this source is being tested in must survive while a neighbour's
        // worker fills its own sandbox.
        _pinned.add(source.id);
        GroupProbeReport? judged;
        // One budget per source: 取测试歌曲 uses part of it, 实测取链 gets the rest.
        final elapsed = Stopwatch()..start();
        Duration left() {
          final rest = _hubBudget - elapsed.elapsed;
          return rest < Duration.zero ? Duration.zero : rest;
        }

        try {
          final song = await _hubGuarded(
            () => _songForGroupProbe(source),
            budget: _hubBudget,
          );
          if (song == null) {
            judged = GroupProbeReport(
              id: source.id,
              name: source.name,
              state: GroupProbeState.skipped,
              detail: '拿不到测试歌曲，未做任何改动',
            );
          } else {
            final remaining = left();
            if (remaining <= Duration.zero) throw _HubProbeTimeout(_hubBudget);
            final probe = await _hubGuarded(
              () => probeSource(source, song: song),
              budget: remaining,
            );
            if (probe.ok) {
              judged = GroupProbeReport(
                id: source.id,
                name: source.name,
                state: GroupProbeState.usable,
                detail: source.disabled
                    ? '${probe.headline}（禁用状态保持不变，要用的话手动启用）'
                    : probe.headline,
              );
            } else if (probe.headline == '缺少在线歌曲') {
              judged = GroupProbeReport(
                id: source.id,
                name: source.name,
                state: GroupProbeState.skipped,
                detail: '没有可测试的歌曲，未做任何改动',
              );
            } else {
              await repository.setDisabled(source.id, true);
              judged = GroupProbeReport(
                id: source.id,
                name: source.name,
                state: GroupProbeState.disabled,
                detail: '${probe.headline}：${probe.detail}',
              );
            }
          }
        } on HubScanCancelled {
          cancelled = true;
          // Nothing to record: a press is not a verdict about this source.
          return;
        } on _HubProbeTimeout catch (timeout) {
          // 超时按「取不到链」处理：用户设定的预算内答不上来，就是不能用的源。
          await repository.setDisabled(source.id, true);
          judged = GroupProbeReport(
            id: source.id,
            name: source.name,
            state: GroupProbeState.disabled,
            detail: '${timeout.message}，已禁用',
          );
        } catch (error) {
          // A source that throws while being asked for a link is a source that
          // cannot serve one, so it goes the same way as a failed probe.
          await repository.setDisabled(source.id, true);
          judged = GroupProbeReport(
            id: source.id,
            name: source.name,
            state: GroupProbeState.disabled,
            detail: '$error',
          );
        } finally {
          _pinned.remove(source.id);
        }
        verdicts[index] = judged;
        hubDone++;
        notifyListeners();
      });

      reports.addAll(verdicts.whereType<GroupProbeReport>());
    } finally {
      _endHubRun();
    }

    final disabledCount =
        reports.where((report) => report.state == GroupProbeState.disabled).length;
    // A probe switches dead sources off, and a switched-off source cannot stay the
    // selected one — so the run that just judged the group is also the one that has
    // to hand playback a source it proved can serve a link.
    await _ensureActiveSource(
      preferredIds: reports
          .where((report) => report.state == GroupProbeState.usable)
          .map((report) => report.id)
          .toList(growable: false),
    );
    debugLog?.record('批量探测结束', <String, Object?>{
      '分组': sourceGroupName(group),
      '检测': reports.length,
      '可用': reports.where((report) => report.state == GroupProbeState.usable).length,
      '禁用': disabledCount,
      '未判定': reports.where((report) => report.state == GroupProbeState.skipped).length,
      '取消': cancelled,
    });
    return GroupProbeOutcome(
      group: group,
      reports: reports,
      cancelled: cancelled,
    );
  }

  /// The song a group probe tests one source against.
  ///
  /// Picking the wrong platform is worse than picking no platform: testing a
  /// `QQ`-only script with a 网易云 song is answered by [probeSource] as
  /// "不支持 WY", which would batch-deactivate a perfectly healthy source. So the
  /// script is initialized first and the song is chosen from the platforms it
  /// actually claims — with the currently-playing track preferred when it happens
  /// to be one of them.
  Future<Song?> _songForGroupProbe(CustomSourceInfo source) async {
    await _initialize(source);
    final slot = _slots[source.id];
    final claimed = <String>[
      if (slot != null && slot.ready)
        ...slot.capabilities.sources.keys.where(
          (name) => slot.capabilities.supports(name, 'musicUrl'),
        ),
    ];
    if (claimed.isEmpty) {
      // Nothing usable was read from the script itself: fall back to what the hub
      // said about it, then to every platform the app knows how to search.
      claimed.addAll(_hubEntryFor(source)?.usablePlatforms ?? const <String>[]);
      if (claimed.isEmpty) claimed.addAll(hubPlatformNames.keys);
    }
    final playing = appState.settings.lastSong;
    if (playing != null &&
        !playing.isLocal &&
        playing.source.isNotEmpty &&
        claimed.contains(playing.source)) {
      return playing;
    }
    for (final platform in claimed) {
      final song = await _testSongFor(platform);
      if (song != null) return song;
    }
    return null;
  }

  /// Guess which published hub entry an imported script came from, so a batch
  /// probe knows which platform is worth searching a test song for. The id is
  /// kept stable by [repository], but older imports and hand-pasted scripts carry
  /// no trace of it, hence the name match and the address fallback.
  HubSourceEntry? _hubEntryFor(CustomSourceInfo source) {
    final index = _hubIndex;
    if (index == null) return null;
    HubSourceEntry? find(bool Function(HubSourceEntry) test) {
      for (final entry in index) {
        if (test(entry)) return entry;
      }
      return null;
    }

    final suffix = source.id.startsWith('hub_')
        ? source.id.substring('hub_'.length)
        : null;
    final byId = suffix == null ? null : find((entry) => entry.id == suffix);
    if (byId != null) return byId;
    final byName = find((entry) => entry.name == source.name);
    if (byName != null) return byName;
    final url = source.importUrl;
    if (url == null || url.isEmpty) return null;
    return find((entry) => entry.rawUrl == url || entry.mirrors.contains(url));
  }

  /// Sources switched off by a probe, across every group. They stay imported and
  /// refreshable, but the 自定义源 page offers one tap to drop all of them.
  List<CustomSourceInfo> get disabledSources => repository.sources
      .where((source) => source.disabled)
      .toList(growable: false);

  /// 一键删除所有禁用源. Enabled sources — including the hand-imported ones — are
  /// never touched, so the button only ever removes what a probe already proved
  /// dead. With [group] the sweep stays inside that batch group, which is what an
  /// unattended update does: a hand-imported script the user left switched off is
  /// theirs to delete, not ours.
  Future<int> deleteDisabledSources({String? group}) async {
    final targets = disabledSources
        .where((source) => group == null || source.group == group)
        .toList(growable: false);
    for (final source in targets) {
      await deleteSource(source.id);
    }
    if (targets.isNotEmpty) {
      debugLog?.record('删除全部禁用源', <String, Object?>{
        '数量': targets.length,
        if (group != null) '限定分组': sourceGroupName(group),
        '源': targets.map((source) => source.name).join('、'),
      });
    }
    return targets.length;
  }

  /// Overwrite one batch group with the seeds the user just approved.
  Future<int> applyHubGroup(String group, List<SourceSeed> seeds) async {
    if (seeds.isEmpty) return 0;
    final added = await repository.replaceGroup(group, seeds);
    // Scripts that the scan replaced no longer exist; drop their sandboxes.
    _dropMissingSlots();
    notifyListeners();
    // Whatever was selected is gone with the old group, so take the first of the
    // new one; the measurement that follows may still prove it dead, in which
    // case 一键更新 picks again from what survived.
    await _ensureActiveSource(preferredIds: added.map((source) => source.id).toList());
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
    _dropMissingSlots();
    notifyListeners();
    // 清空整组之后如果别的分组还有源，播放照样要有东西可试；一个都不剩才回落到未启用。
    await _ensureActiveSource();
    debugLog?.record('清空分组 $group', <String, Object?>{'删除': removed});
    return removed;
  }

  /// 一键更新源: the four presses the manual routine takes — fetch the hub's daily
  /// list, write it over the batch group, measure every one of them here, and drop
  /// the ones that cannot serve audio — run through without a confirm dialog.
  ///
  /// Two properties make it safe to do unattended:
  ///  - nothing is written unless the hub answered with at least one usable script,
  ///    so an outage can never empty the very group it replaces;
  ///  - the measurement only ever disables sources inside that group, so a hand-
  ///    imported script is untouched no matter how badly the pass goes.
  ///
  /// A run that drifts into the background stops at once (see
  /// [didChangeAppLifecycleState]) and deletes nothing, because a partly measured
  /// group says nothing about the sources it never reached.
  Future<SourceRefreshOutcome> refreshSources({bool automatic = false}) async {
    if (hubWorking) {
      return const SourceRefreshOutcome(error: '已有一批源在获取中，请等待它结束');
    }
    if (!_foreground) {
      return const SourceRefreshOutcome(
        error: '应用不在前台，本次源更新没有开始',
        cancelled: true,
      );
    }
    final label = automatic ? '自动更新源' : '一键更新源';
    final started = DateTime.now();
    final scan = await scanHubSources(group: sourceGroupWeb);
    // 停止 pressed during the fetch: a partial list would be imported as if it were
    // the whole day's results, so the run ends here with the sources untouched.
    if (scan.cancelled) {
      return const SourceRefreshOutcome(
        error: '已停止，现有源保持不变',
        cancelled: true,
      );
    }
    if (scan.seeds.isEmpty) {
      debugLog?.record('$label：现有源保持不变', <String, Object?>{
        '原因': scan.error ?? '列表里没有可导入的脚本',
        '候选': scan.poolSize,
        '取消': scan.cancelled,
      });
      return SourceRefreshOutcome(
        error: scan.error ?? '没有取到可导入的源，现有源保持不变',
        cancelled: scan.cancelled,
      );
    }

    final imported = await applyHubGroup(sourceGroupWeb, scan.seeds);
    if (imported == 0) {
      return const SourceRefreshOutcome(error: '脚本写入失败，现有源保持不变');
    }

    final probe = await probeGroup(sourceGroupWeb);
    if (probe.error != null) {
      return SourceRefreshOutcome(imported: imported, error: probe.error);
    }
    final disabled = probe.disabled.length;
    if (probe.cancelled || !_foreground) {
      debugLog?.record('$label：中途停止', <String, Object?>{
        '写入': imported,
        '已禁用': disabled,
        '原因': _foreground ? '手动停止' : '应用退到后台',
      });
      return SourceRefreshOutcome(
        imported: imported,
        disabled: disabled,
        cancelled: true,
      );
    }

    final removed = await deleteDisabledSources(group: sourceGroupWeb);
    final chosen = await _ensureActiveSource(
      preferredIds: probe.usable.map((report) => report.id).toList(growable: false),
    );
    final kept = repository.byGroup(sourceGroupWeb).length;
    await appState.update((settings) =>
        settings.lastSourceRefreshAt = DateTime.now().millisecondsSinceEpoch);
    debugLog?.record('$label完成', <String, Object?>{
      '写入': imported,
      '禁用': disabled,
      '删除': removed,
      '剩余': kept,
      '选用': chosen?.name ?? '无可用源',
      '耗时': '${DateTime.now().difference(started).inSeconds}s',
    });
    return SourceRefreshOutcome(
      imported: imported,
      disabled: disabled,
      removed: removed,
      kept: kept,
      activeName: chosen?.name,
    );
  }

  /// Arm the self-started update after launch when 开机自动后台检查源 is on.
  ///
  /// Nothing here waits on the result: the queue keeps playing from the sources it
  /// already has, and the run happens beside it.
  void maybeScheduleAutoRefresh() {
    if (!appState.settings.autoSourceRefresh) return;
    if (_autoRefreshTimer != null || !_autoRefreshDue()) return;
    _autoRefreshTimer = Timer(_autoRefreshLead, () {
      _autoRefreshTimer = null;
      if (_disposed || !_autoRefreshDue()) return;
      if (!appState.settings.autoSourceRefresh) return;
      unawaited(refreshSources(automatic: true));
    });
  }

  /// True when no update has ever finished, or the last one is a day old.
  bool _autoRefreshDue() {
    final last = appState.settings.lastSourceRefreshAt;
    if (last <= 0) return true;
    return DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(last)) >=
        _autoRefreshInterval;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only a real suspension freezes the sandbox. The short `inactive` window —
    // app switcher, notification shade, an incoming call banner — must not cut a
    // pass off, since playback keeps running through all of it.
    final foreground =
        state != AppLifecycleState.paused && state != AppLifecycleState.detached;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (!foreground) {
      // A pass that continues behind the lock screen would measure nothing but
      // timeouts, and every one of those is written off as a dead source.
      if (hubWorking) cancelHubScan();
      return;
    }
    // Coming back with the switch still on and the day still unmet re-arms the
    // pass that going to the background cut short.
    maybeScheduleAutoRefresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    for (final slot in _slots.values) {
      final engine = slot.engine;
      if (engine is JsSourceEngine) unawaited(engine.dispose());
    }
    _slots.clear();
    super.dispose();
  }
}

/// What one 一键更新 run did, in the numbers the page and the log show.
class SourceRefreshOutcome {
  const SourceRefreshOutcome({
    this.imported = 0,
    this.disabled = 0,
    this.removed = 0,
    this.kept = 0,
    this.activeName,
    this.cancelled = false,
    this.error,
  });

  /// Scripts written over the batch group.
  final int imported;

  /// Sources the measurement switched off.
  final int disabled;

  /// Disabled sources deleted at the end of the same run.
  final int removed;

  /// Sources left in the group afterwards.
  final int kept;

  /// The source the run left selected, so the toast can say the queue is ready to
  /// play instead of leaving the user to work out that a tap is still needed.
  final String? activeName;

  /// Stopped before the whole group was measured, so nothing was deleted and the
  /// next launch tries again.
  final bool cancelled;

  /// Why nothing happened, when nothing happened.
  final String? error;

  bool get ok => error == null && !cancelled;

  /// One line for the toast: `更新完成：写入 24 个，实测淘汰 6 个，剩 18 个可用`.
  String get summary {
    if (error != null) return error!;
    if (cancelled) return '已停止：写入 $imported 个，实测未完成，下次启动继续';
    final tail = kept == 0
        ? '没有源通过实测，请再更新一次'
        : '剩 $kept 个可用${activeName == null ? '' : '，已选用「$activeName」'}';
    return '更新完成：写入 $imported 个，实测淘汰 $removed 个，$tail';
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

/// 停止 abandoned a batch step. It is an exception only so a press can unwind the
/// loop from inside whatever the current candidate is awaiting; the batch swallows
/// it and reports `cancelled` instead.
class HubScanCancelled implements Exception {
  const HubScanCancelled();
}

/// Internal: which side of the abort race in [_SourceState._hubGuarded] won.
enum _HubStepState { done, failed, aborted, timedOut }

/// Internal: one source ran out of the user's 探测超时 while a batch was running.
/// The batch disables that source — a script that cannot answer inside the budget
/// is treated as one that cannot serve a link — and carries on with the others.
class _HubProbeTimeout implements Exception {
  const _HubProbeTimeout(this.budget);

  final Duration budget;

  String get message => '超过 ${budget.inSeconds}s 没有结果';
}

/// What a batch probe decided about one source.
enum GroupProbeState {
  /// Returned a real audio link; left enabled.
  usable,

  /// Could not serve a link, or never answered inside the timeout, so it has
  /// been switched off.
  disabled,

  /// Nothing was proven — no test song could be fetched for any of its
  /// platforms. Its enabled state is untouched.
  skipped,
}

/// One line of a batch probe result.
class GroupProbeReport {
  const GroupProbeReport({
    required this.id,
    required this.name,
    required this.state,
    required this.detail,
  });

  /// Which source this verdict is about, so a batch run can hand playback a
  /// source it just proved works (see [_ensureActiveSource]).
  final String id;
  final String name;
  final GroupProbeState state;
  final String detail;
}

/// Outcome of [SourceState.probeGroup]: what was judged, and how much of the run
/// the stop button cut short.
class GroupProbeOutcome {
  const GroupProbeOutcome({
    required this.group,
    required this.reports,
    this.cancelled = false,
    this.error,
  });

  final String group;
  final List<GroupProbeReport> reports;
  final bool cancelled;

  /// Set when the batch refused to start (another run, or an empty group).
  final String? error;

  List<GroupProbeReport> get usable =>
      reports.where((report) => report.state == GroupProbeState.usable).toList(growable: false);

  List<GroupProbeReport> get disabled =>
      reports.where((report) => report.state == GroupProbeState.disabled).toList(growable: false);

  List<GroupProbeReport> get skipped =>
      reports.where((report) => report.state == GroupProbeState.skipped).toList(growable: false);
}
