import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import '../models/lyric.dart';
import '../models/song.dart';
import '../services/lyric_parser.dart';
import '../services/debug_log.dart';
import '../services/online_engine.dart';
import '../services/player_service.dart';
import '../services/runway_cache.dart';
import 'app_state.dart';
import 'library_state.dart';
import 'source_state.dart';

class PlayerController extends ChangeNotifier with WidgetsBindingObserver {
  PlayerController({
    required this.service,
    required this.sourceState,
    required this.appState,
    required this.libraryState,
    required this.onlineEngine,
    this.runway,
    this.debugLog,
  }) {
    runway?.labelFor = (key) {
      for (final song in _queue) {
        if (_songKey(song) == key) return song.name;
      }
      final current = _current;
      if (current != null && _songKey(current) == key) return current.name;
      return key;
    };
    _subscriptions.add(
      service.positionStream.listen((position) {
        if (position > _position) _lastProgressChangeAt = DateTime.now();
        _position = position;
        if (_lyrics.isNotEmpty) {
          final nextLine = LyricParser.activeIndex(_lyrics, position);
          if (nextLine != _activeLine) _activeLine = nextLine;
        }
        if (_duration.inSeconds > 10 &&
            (_duration - position).inSeconds <= _preloadLeadSeconds) {
          unawaited(_preloadNext());
        }
        // The runway cache holds the *whole* files of the next tracks, and a song
        // takes far longer to transfer than its link does to resolve. Start that
        // while the current track still has minutes left, so the file — not just
        // the URL — is on disk by the time the boundary arrives.
        if (_duration.inSeconds > 10 &&
            (_duration - position).inSeconds <= _runwayLeadSeconds) {
          unawaited(_prefetchLookahead());
        }
        _notify();
      }),
    );
    _subscriptions.add(
      service.durationStream.listen((duration) {
        _duration = duration ?? Duration.zero;
        _notify();
      }),
    );
    _subscriptions.add(
      service.playerStateStream.listen((state) {
        _isPlaying = state.playing && state.processingState != ProcessingState.completed;
        // Safety net: once the link has been handed to the native player and it
        // reports real playback, the resolving step is over. Drop the loading
        // flag so the play button stops spinning even if a load future is still
        // parked on a frozen source sandbox.
        if (_loading &&
            _handedOff &&
            _isPlaying &&
            state.processingState == ProcessingState.ready) {
          _loading = false;
          _statusText = null;
        }
        _notify();
      }),
    );
    service.onSkipNext = _handleRemoteSkipNext;
    service.onSkipPrevious = _handleRemoteSkipPrevious;
    service.onPlayRequest = play;
    service.onPauseRequest = _handleRemotePause;
    service.onSeekRequest = seek;
    service.onStopRequest = _handleSystemStop;
    service.onCompleted = _handleCompleted;
    // The standby item was swapped in at the track boundary and is already
    // producing sound; the controller only has to mirror the new index/state.
    service.onPromoted = _handlePromotedNext;
    // The standby player rejected the planned link. Nothing else reports this:
    // there is no promotion, no active-track error, and the current song is
    // still playing fine, so the queue would just go silent at the boundary.
    service.onPreloadFailed = _handleStandbyLoadFailed;
    service.onPlayError = (message) {
      debugLog?.record('播放器报错 ${_current?.name}', <String, Object?>{
        '错误': message,
        '前台': _appInForeground,
        '在加载': _loading,
      });
      unawaited(_handlePlayerError(message));
    };
    service.onExternalPause = () {
      // Bluetooth head units often put a pause immediately before or after the
      // next/previous command. Honouring that pause stops the track that was
      // just started and is exactly the "it says it changed but there is no
      // sound" failure in a car. Treat a pause glued to a skip as part of the
      // skip and ignore it.
      final recentSkip =
          DateTime.now().difference(_lastRemoteSkipAt) < _remotePauseGuard;
      _ignoreRemotePause = recentSkip;
      if (recentSkip) return;
      // A pause from the lock screen / control centre is deliberate: never
      // auto-restart it when the app comes back, not even if an audio
      // interruption was still flagged as resumable.
      _userPaused = true;
      // Clear the play intent here as well, so even a fallback that does not go
      // through [pause] cannot be undone by the silence watchdog.
      _shouldPlay = false;
      _resumeAfterInterruption = false;
      _resumeOnForeground = false;
    };
    sourceState.addListener(_onSourceChanged);
    _lastActiveSourceId = sourceState.active?.id;
    WidgetsBinding.instance.addObserver(this);
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkAudible());
    unawaited(_listenToAudioSession());
    _restoreLastPlayback();
    debugLog?.record('应用启动', <String, Object?>{
      '恢复歌曲': _current?.name,
      '队列长度': _queue.length,
      '活动源': sourceState.active?.name,
    });
  }

  final FlmPlayerService service;
  final SourceState sourceState;
  final AppState appState;
  final LibraryState libraryState;
  final OnlineEngine onlineEngine;

  /// Optional hidden full-file cache of the tracks the queue is about to reach.
  /// When present (and its setting is on) a track boundary can be a plain local
  /// file open, which is the only shape of "next song ready" that survives an
  /// expiring link, a dead source host, or a cellular hole behind the lock
  /// screen.
  final RunwayCache? runway;

  /// When set (and its switch is on), playback decisions are mirrored to the
  /// in-app debug page: what URL was handed to the player, why a load failed
  /// (with stack), lifecycle and audio-interruption events.
  final DebugLog? debugLog;

  final List<StreamSubscription<dynamic>> _subscriptions = <StreamSubscription<dynamic>>[];
  late final Timer _progressTimer;
  late final Timer _watchdogTimer;
  Timer? _sleepTimer;
  DateTime? _sleepEndsAt;

  /// Player position sampled on the previous watchdog tick, so a stalled native
  /// clock can be told apart from a running one.
  Duration _watchPosition = Duration.zero;
  /// Last time the native player's clock moved. The watchdog's only evidence of
  /// audible audio, because `playing == true` keeps being reported while the
  /// shared session is muted behind the lock screen.
  DateTime _lastProgressChangeAt = DateTime.now();
  int _silentHeals = 0;
  bool _sessionConfirmedActive = false;
  /// Set when playback is running as the app leaves the foreground and cleared
  /// when it comes back; drives the preventive re-arm in [_checkAudible].
  DateTime? _backgroundSince;

  /// Whether the one preventive re-arm for the current background stretch has
  /// been spent. Reset every time the app leaves the foreground.
  bool _proactiveHealDone = false;
  static const Duration _proactiveHealAfter = Duration(seconds: 12);

  /// How long the native clock may stand still while the user wants sound before
  /// the watchdog re-arms the pipeline. Covers both a muted-but-advancing session
  /// and a stream that never started producing samples.
  static const Duration _noProgressWindow = Duration(seconds: 15);
  static const int _maxSilentHeals = 3;

  List<Song> _queue = <Song>[];
  int _index = -1;
  Song? _current;
  bool _isPlaying = false;

  /// Whether the user wants sound right now. Kept apart from [_isPlaying], which
  /// is only ever the native player's own claim — behind the lock screen that
  /// claim stays true while the speaker is silent, so every recovery decision is
  /// driven by this intent flag instead.
  bool _shouldPlay = false;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  List<LyricLine> _lyrics = const <LyricLine>[];
  int _activeLine = -1;
  String? _statusText;
  String? _errorText;
  int _playToken = 0;
  bool _disposed = false;
  DateTime? _loadStartedAt;

  /// Queue indices still to be played, decided once and reused (see [_upcoming]).
  List<int> _nextPlan = <int>[];
  /// True once the resolved URL has been given to the native player, i.e. the
  /// only thing left is buffering/audio, not link fetching.
  bool _handedOff = false;
  /// How many times a mid-stream player error was retried for the current song.
  int _playErrorAttempts = 0;
  /// Guards the automatic advance against duplicate `completed` events.
  /// just_audio can report the same completion more than once; the second call
  /// would run `next` again after the first one already moved the index, which
  /// silently skips a track.
  bool _advancing = false;
  final Map<String, _CachedUrl> _urlCache = <String, _CachedUrl>{};
  final Set<String> _preloading = <String>{};

  /// Songs this pass through the queue could not be given a working link — every
  /// source failed to resolve it, or the native player refused the standby load.
  /// They are treated as *already played*: the planner and the advance walk past
  /// them, and nothing is retried until the queue wraps around, which is the only
  /// moment the source may have recovered. The set is cleared when a full pass
  /// finds nothing left to play, when the queue or play mode changes, when the
  /// active source changes, and as soon as one of its songs plays.
  final Set<String> _skippedThisRound = <String>{};

  /// Songs skipped since the last audible one. A queue-wide problem (no network,
  /// every source down) looks exactly like a dead song from here, so past this
  /// bound the controller stops consuming tracks and waits with a backoff instead
  /// of marking the whole list unplayable one song at a time.
  int _consecutiveSkips = 0;
  static const int _maxConsecutiveSkips = 5;

  /// Nothing in the queue can be started right now while the user still wants
  /// sound. The play intent therefore stays set — instead of the old "pause and
  /// wait for the app to be opened" state that also killed the watchdog and left
  /// the headset and car controls with nothing to act on — and the watchdog
  /// retries the queue on [_stockRetryLead] intervals.
  bool _waitingForStock = false;
  DateTime _nextStockRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _stockRetryLeadForeground = Duration(seconds: 20);
  static const Duration _stockRetryLeadBackground = Duration(seconds: 60);

  /// Active source the cooldowns were earned against; a different script may well
  /// serve the same songs, so the marks are dropped when it changes.
  String? _lastActiveSourceId;
  DateTime _lastPreloadAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLookaheadAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  /// What the standby player holds right now. It is the contract between the
  /// preloader and the track-boundary promotion: the service swaps the standby
  /// in, and this record tells the controller which song/index that was.
  Song? _plannedNextSong;
  int _plannedNextIndex = -1;
  String? _plannedNextUrl;
  /// How many standby loads in a row have been refused while trying to get one
  /// track actually prepared. Each refusal re-plans and re-arms once, so without
  /// a bound a whole queue of dead links would chain-load back to back.
  int _armChain = 0;
  static const int _maxArmChain = 3;
  /// Bumped whenever the queue/order changes, so an in-flight link resolve for
  /// the old plan is thrown away instead of arming the standby with a stale
  /// track.
  int _preloadEpoch = 0;

  /// Whether the load currently in flight came from an explicit song selection
  /// rather than a heal/retry of the track that just ended. A boundary
  /// promotion must not let a stale retry hand that finished track back to the
  /// player afterwards.
  bool _loadingIsSelection = false;

  /// Last time a Bluetooth/car/remote skip command arrived, and whether the
  /// pause that some head units send alongside it should be swallowed.
  DateTime _lastRemoteSkipAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _ignoreRemotePause = false;
  Timer? _settingsSaveTimer;
  bool _resumeOnForeground = false;
  bool _resumeAfterInterruption = false;
  bool _appInForeground = true;
  bool _userPaused = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _noisySubscription;

  /// How far before the end of the current track the following links are
  /// fetched. The source sandbox is a WKWebView whose JavaScript stops the
  /// moment the app is backgrounded or the screen locks, so a link that was not
  /// resolved *before* that point cannot be resolved until the user returns —
  /// and the queue goes silent in the meantime. A generous lead plus several
  /// candidates keeps a ready URL for the whole background stretch.
  static const int _preloadLeadSeconds = 150;

  /// How many upcoming tracks one prewarm pass will walk while skipping the ones
  /// this round already gave up on. Deeper than one so a single dead song cannot
  /// leave the standby empty for the whole track.
  static const int _planSearchWidth = 3;

  /// How far an automatic or remote advance is allowed to look for something it
  /// can actually start. Several dead tracks in a row are a normal sight on an
  /// unstable source, and the queue must walk past all of them in one go rather
  /// than stopping after the third.
  static const int _maxAdvanceScan = 12;

  /// How far before the end of the current track a following song's *file* is
  /// pulled into the runway cache. Transferring a whole track costs far more time
  /// than resolving its link, so this lead is several times [_preloadLeadSeconds].
  static const int _runwayLeadSeconds = 420;

  /// A resolve started while backgrounded is waiting on frozen JavaScript, so cap
  /// how long an advance blocks on it. Returning to the foreground restarts the
  /// load once JavaScript runs again.
  // The in-process source engine can resolve while backgrounded; 12 s used to
  // be the safe ceiling for a frozen WebView, but a real cross-source lookup
  // (script -> native HTTP -> probe) can legitimately take longer.
  static const Duration _backgroundResolveTimeout = Duration(seconds: 25);

  /// How long a start may wait for the *following* link to be resolved. The
  /// standby has to be armed before the screen can lock, but a slow source must
  /// not hold the song the user just tapped hostage.
  static const Duration _warmBudget = Duration(seconds: 2);

  /// A remote pause arriving this soon after a remote skip is treated as part
  /// of the same head-unit button press, not as a deliberate pause.
  static const Duration _remotePauseGuard = Duration(milliseconds: 1200);

  /// How long a resolved link is trusted for, how close to that deadline it gets
  /// re-fetched while the app is awake, and how many links are kept.
  static const Duration _urlTtl = Duration(minutes: 10);
  static const Duration _urlRefreshLead = Duration(minutes: 4);
  static const int _maxCachedUrls = 60;

  List<Song> get queue => List<Song>.unmodifiable(_queue);
  int get index => _index;
  Song? get current => _current;
  bool get isPlaying => _isPlaying;

  /// Whether sound is supposed to be coming out right now — the user's intent,
  /// independent of what the native player claims. The play/pause button reads
  /// this because behind the lock screen `playing` stays true while the speaker is
  /// muted, and because a fresh load is not "paused" just because the platform
  /// has not acknowledged it yet.
  bool get willPlay => _shouldPlay || _isPlaying;
  bool get loading => _loading;
  Duration get position => _position;
  Duration get duration => _duration;
  List<LyricLine> get lyrics => _lyrics;
  int get activeLine => _activeLine;
  String? get statusText => _statusText;
  String? get errorText => _errorText;
  PlayMode get playMode => appState.settings.playMode;
  Duration? get sleepRemaining {
    final end = _sleepEndsAt;
    if (end == null) return null;
    final remaining = end.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool isCurrent(Song song) => _current?.id == song.id && _current?.source == song.source;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// iOS can interrupt or deactivate the audio session (calls, Siri, unplugged
  /// headphones, locking a re-signed build). Without re-activating it,
  /// `playing == true` can be reported while no sound is audible, which is the
  /// "it says it is playing but the next track is silent" symptom.
  Future<void> _listenToAudioSession() async {
    try {
      final session = await AudioSession.instance;
      debugLog?.record('音频会话', <String, Object?>{
        '已配置': session.isConfigured,
        '类别': '${session.configuration?.avAudioSessionCategory}',
        '中断监听': Platform.isIOS ? 'iOS' : '其他平台',
      });
      _interruptionSubscription = session.interruptionEventStream.listen((event) {
        if (_disposed) return;
        debugLog?.record('音频中断 ${event.begin ? "开始" : "结束"}', <String, Object?>{
          '类型': '${event.type}',
          '当时在播': _isPlaying,
          '想要声音': _shouldPlay,
          '当时在加载': _loading,
        });
        if (event.begin) {
          _resumeAfterInterruption = _shouldPlay || _isPlaying;
          // While the interruption is in progress there is nothing to heal: the
          // session cannot be activated again (phone call, Siri) and a watchdog
          // pause+play would only fight the system.
          _shouldPlay = false;
          if (_isPlaying) unawaited(service.pause());
          return;
        }
        if (!_resumeAfterInterruption) return;
        _resumeAfterInterruption = false;
        if (event.type == AudioInterruptionType.pause ||
            event.type == AudioInterruptionType.unknown) {
          unawaited(() async {
            if (_disposed || _current == null) return;
            // The interrupted item is usually still loaded but the session was
            // released, so resume through the re-arm path — it takes ownership of
            // the session again and reloads the song when the item is gone.
            _userPaused = false;
            _shouldPlay = true;
            _silentHeals = 0;
            await _healSilence();
          }());
        }
      });
      _noisySubscription = session.becomingNoisyEventStream.listen((_) {
        debugLog?.record('音频路线变为静音(耳机拔出等)', <String, Object?>{
          '当时在播': _isPlaying,
          '动作': _isPlaying ? '暂停' : '忽略',
        });
        if (_isPlaying) unawaited(pause());
      });
    } catch (_) {
      // Audio-session helpers are best effort; playback still works.
    }
  }

  /// Make this app the owner of the shared `AVAudioSession` again.
  ///
  /// The source sandbox is a WKWebView, and WebKit reclaims the process-wide
  /// session as soon as no *web* media is audible — which happens the moment the
  /// screen locks. From then on the native player keeps advancing its clock and
  /// keeps reporting `playing == true` while nothing comes out of the speaker.
  ///
  /// `audio_session` only re-configures when its own Dart-side `isConfigured`
  /// flag is unset, and that flag says nothing about what the OS currently has,
  /// so the category is applied unconditionally here: locking the screen can drop
  /// us back to the default category, and the default category is muted by the OS.
  /// Returns whether the session ended up active; a false answer means playback
  /// is very likely silent, so the caller must not treat "started" as "audible".
  Future<bool> _activateSession({String? reason}) async {
    _sessionConfirmedActive = false;
    const configuration = AudioSessionConfiguration.music();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final session = await AudioSession.instance;
        await session.configure(configuration);
        final active = await session.setActive(true);
        _sessionConfirmedActive = active;
        if (active) return true;
        if (attempt == 0) {
          debugLog?.record('音频会话激活失败，重试 ${_current?.name}', <String, Object?>{
            '原因': reason,
            '前台': _appInForeground,
            '在播': _isPlaying,
            '原生状态': '${service.player.processingState}',
          });
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        debugLog?.record('音频会话激活失败 ${_current?.name}', <String, Object?>{
          '原因': reason,
          '前台': _appInForeground,
          '在播': _isPlaying,
          '原生状态': '${service.player.processingState}',
        });
        return false;
      } catch (error) {
        debugLog?.record('音频会话配置异常 ${_current?.name}', <String, Object?>{
          '原因': reason,
          '错误': '$error',
        });
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
      }
    }
    return false;
  }

  /// Silence watchdog. It trusts neither the `playing` flag nor the loading
  /// spinner: both stay green while the speaker is mute, which is precisely the
  /// lock-screen failure the user reported ("进度条在走，按钮是播放状态，就是没有声音").
  /// The only evidence it acts on is *the native clock advancing* plus the intent
  /// captured in [_shouldPlay], so a stalled or never-handed-off load is healed
  /// instead of being mistaken for ordinary buffering.
  void _checkAudible() {
    if (_disposed || _current == null || !_shouldPlay || _userPaused) return;
    final now = DateTime.now();
    final started = _loadStartedAt;

    // The queue has nothing playable at the moment. This is handled here rather
    // than by the stall logic below on purpose: re-arming a song that never made
    // it to the player would only repeat the failed load every fifteen seconds,
    // while the user still hears nothing.
    if (_waitingForStock) {
      if (_loading) return;
      if (now.isBefore(_nextStockRetryAt)) {
        // Keep preparing during the wait: a late link or a finished download is
        // exactly what ends it. The session gets re-claimed once per background
        // stretch so the lock-screen controls stay ours for the next attempt.
        if (!service.hasPreparedNext && !_advancing) unawaited(_preloadNext());
        if (!_appInForeground && !_proactiveHealDone) {
          _proactiveHealDone = true;
          unawaited(_activateSession(reason: '等待可用资源'));
        }
        return;
      }
      unawaited(_retryStock());
      return;
    }

    // The source sandbox is a frozen WKWebView once the screen locks, so a link
    // that was not resolved before then can never be resolved. Abandon that load
    // rather than sitting on "正在获取播放链接…" — and hand the queue to the first
    // track whose link is already cached, which keeps background playback running.
    if (_loading && !_handedOff && started != null) {
      if (!_appInForeground &&
          !sourceState.canResolveInBackground &&
          now.difference(started) > const Duration(seconds: 20)) {
        _silentHeals = 0;
        debugLog?.record('后台取链停滞，放弃本次加载 ${_current?.name}', <String, Object?>{
          '已等待': '${now.difference(started).inSeconds}s',
          '下一首有货': _nextPlayableIndex() != null,
          '已下整曲': runway?.cachedCount,
        });
        _playToken++;
        _loading = false;
        _statusText = '锁屏时取不到链接，正在用已缓存的地址继续';
        _resumeOnForeground = true;
        _notify();
        unawaited(_handleCompleted());
      }
      return;
    }

    if (_sessionConfirmedActive) {
      // A fresh activation just landed; give the pipeline one full window to
      // produce audio before this tick starts judging it.
      _sessionConfirmedActive = false;
      _lastProgressChangeAt = now;
      _watchPosition = service.player.position;
      return;
    }

    if (!_appInForeground && _backgroundSince == null) {
      // A track that started while already backgrounded has no stretch to
      // measure yet.
      _backgroundSince = now;
      _proactiveHealDone = false;
    }

    final position = service.player.position;
    final advanced = position > _watchPosition;
    if (advanced) {
      _lastProgressChangeAt = now;
      // Audio is demonstrably flowing, so spend the whole re-arm budget again on
      // the next problem instead of running out after a long album.
      _silentHeals = 0;
    }
    _watchPosition = position;

    // Nothing is prepared for the boundary: try again now, even outside the
    // 150-second lead window. Behind the lock screen this is the only place that
    // notices a dead "next" early enough for the runway to walk past it and arm a
    // later track before the current one ends — which is what keeps a background
    // session playing instead of stopping on the first song no source can serve.
    // [_preloadNext] throttles itself, so a healthy queue costs one cheap check.
    if (!service.hasPreparedNext && !_advancing) {
      unawaited(_preloadNext());
    }

    final quietFor = now.difference(_lastProgressChangeAt);
    final stalled = !advanced && quietFor > _noProgressWindow;
    if (_silentHeals >= _maxSilentHeals) return;
    final away = _backgroundSince == null ? null : now.difference(_backgroundSince!);
    // Exactly one preventive re-arm per background stretch: the muted-but-
    // advancing clock it corrects also resets the stall budget, so leaving this
    // condition on the budget would click-pause the track every few seconds.
    final needsProactive = !_proactiveHealDone &&
        !_appInForeground &&
        away != null &&
        away > _proactiveHealAfter;
    if (!stalled && !needsProactive) return;
    _silentHeals++;
    if (needsProactive) _proactiveHealDone = true;
    debugLog?.record(
        stalled ? '没有声音输出，自动重挂 ${_current?.name}' : '锁屏后预防性重挂 ${_current?.name}',
        <String, Object?>{
          '前台': _appInForeground,
          '位置': '${position.inSeconds}s',
          '无进展时长': '${quietFor.inSeconds}s',
          '后台时长': away == null ? '-' : '${away.inSeconds}s',
          '原生状态': '${service.player.processingState}',
          '播放器自称在播': _isPlaying,
          '已重挂次数': _silentHeals,
        });
    unawaited(_healSilence());
  }

  /// Re-arm the audio pipeline without touching the queue: activating the session
  /// is not enough on its own, the item has to be started again — the same thing
  /// a manual pause + play did, including the case where the item was released
  /// outright and has to be fed the cached link again.
  Future<void> _healSilence() async {
    final token = _playToken;
    final song = _current;
    if (_disposed || song == null) return;
    await _activateSession(reason: 'watchdog');
    if (_disposed || token != _playToken) return;
    final processing = service.player.processingState;
    if (processing == ProcessingState.completed) {
      await _handleCompleted();
      return;
    }
    if (processing == ProcessingState.idle || processing == ProcessingState.loading) {
      await _loadAndPlay(song, initialPosition: _position, reason: 'watchdog 重载');
      return;
    }
    await service.pause();
    if (_disposed || token != _playToken) return;
    await service.play();
    if (_disposed) return;
    // Re-anchor the watchdog samples so the next tick measures the clock after
    // the re-arm rather than against the position it just declared stale.
    _watchPosition = service.player.position;
    _lastProgressChangeAt = DateTime.now();
    _notify();
  }

  void _restoreLastPlayback() {
    if (!appState.settings.saveProgress) return;
    final song = appState.settings.lastSong;
    var queue = appState.settings.lastQueue;
    if (queue.isEmpty && song != null) queue = <Song>[song];
    if (queue.isEmpty) return;
    var index = appState.settings.lastQueueIndex;
    if (song != null) {
      final match = queue.indexWhere(
        (item) => item.id == song.id && item.source == song.source,
      );
      if (match >= 0) index = match;
    }
    index = index.clamp(0, queue.length - 1);
    _queue = queue;
    _index = index;
    _current = queue[index];
    _position = Duration(milliseconds: appState.settings.lastPositionMs);
    _statusText = '上次播放 · 点击继续';
    service.setMediaItem(_current!);
    _notify();
  }

  Future<void> playSong(Song song, {List<Song>? queue, int? index, String? reason}) async {
    var invalidated = false;
    if (queue != null) {
      if (!identical(queue, _queue)) {
        // A different queue means the prepared "next" and the decided order no
        // longer describe what will actually play.
        _invalidatePreload();
        invalidated = true;
      }
      _queue = List<Song>.from(queue);
      _index = index ?? _queue.indexWhere((item) => item.id == song.id && item.source == song.source);
      if (_index < 0) {
        _queue.insert(0, song);
        _index = 0;
      }
    } else {
      final existing = _queue.indexWhere((item) => item.id == song.id && item.source == song.source);
      if (existing >= 0) {
        _index = existing;
      } else {
        _invalidatePreload();
        invalidated = true;
        _queue = <Song>[song];
        _index = 0;
      }
    }

    // If the selected song is exactly the item already loaded in the standby
    // player, keep it: `playUrl`/`playFile` will promote it without touching
    // the network or the frozen source sandbox. The link is handed to the load
    // path directly, so even a lock-screen skip needs no resolve.
    String? preparedUrl;
    if (!invalidated) {
      final plannedSong = _plannedNextSong;
      if (plannedSong != null &&
          plannedSong.id == song.id &&
          plannedSong.source == song.source) {
        preparedUrl = song.isLocal ? null : _plannedNextUrl;
        _plannedNextSong = null;
        _plannedNextIndex = -1;
        _plannedNextUrl = null;
      } else {
        _invalidatePreload();
      }
    }

    // Keep whatever remains of the pre-computed order so the links already in
    // hand for the following tracks are still used.
    _syncPlanAfterIndexChange();

    _current = song;
    _position = Duration.zero;
    _duration = Duration.zero;
    _lyrics = const <LyricLine>[];
    _activeLine = -1;
    _errorText = null;
    _userPaused = false;
    _playErrorAttempts = 0;
    _watchPosition = Duration.zero;
    _silentHeals = 0;
    _statusText = '正在准备播放…';
    _notify();
    await _loadAndPlay(
      song,
      selection: true,
      preferredUrl: preparedUrl,
      reason: reason,
    );
  }

  Future<void> _loadAndPlay(
    Song song, {
    Duration initialPosition = Duration.zero,
    bool allowRetry = true,
    bool selection = false,
    String? preferredUrl,
    String? reason,
  }) async {
    final token = ++_playToken;
    _loading = true;
    _loadingIsSelection = selection;
    _shouldPlay = true;
    _handedOff = false;
    _loadStartedAt = DateTime.now();
    _lastProgressChangeAt = DateTime.now();
    _statusText = '正在获取播放链接…';
    _errorText = null;
    _notify();
    // A track whose whole file already sits in the runway cache starts from disk:
    // no link, no network, no source — the boundary that used to die on an
    // expiring address becomes a file open.
    final runwayPath = song.isLocal ? null : _runwayPath(song);
    final filePath = song.isLocal ? song.localPath : runwayPath;
    var handedUrl = filePath ?? '(未取到)';
    debugLog?.record('播放开始 ${song.name}', <String, Object?>{
      '歌曲': '${song.name} - ${song.singer}',
      '平台': song.source,
      '本地': song.isLocal,
      if (runwayPath != null) '整曲缓存': true,
      '前台': _appInForeground,
      '起始位置': '${initialPosition.inSeconds}s',
      if (preferredUrl != null) '已预排': true,
      if (reason != null) '触发': reason,
    });

    // Resolve the following track's link in parallel with this one. Once the
    // screen locks the source sandbox is frozen; the next link therefore has to
    // exist before playback becomes audible, or the queue goes silent at the
    // boundary. Bounded by [_warmBudget] so a slow source cannot delay this song.
    final warm = _warmNextLink()
        .catchError((Object _) => Future<void>.value());
    // Arming the standby with a link that arrives late is only safe once the
    // current item has been handed to the service (which synchronously clears
    // or promotes the old standby); otherwise that clear would throw it away.
    var handedToPlayer = false;
    unawaited(warm.then((_) {
      if (!handedToPlayer || _disposed || token != _playToken) return;
      _armPreparedNext();
      unawaited(_prefetchLookahead());
    }));

    try {
      if (song.isLocal && filePath == null) {
        throw StateError('本地文件已不存在');
      }
      if (filePath != null) {
        _handedOff = true;
        // A local file must start immediately; the following link keeps
        // resolving in parallel and is armed by the success path below.
        await _activateSession(reason: song.isLocal ? '本地起播' : '整曲缓存起播');
        if (token != _playToken || _disposed) return;
        final load = service.playFile(filePath, initialPosition: initialPosition);
        // The service has cleared/replaced its standby by now; arm the new one
        // with the following track while this item is still loading.
        handedToPlayer = true;
        _armPreparedNext();
        await load;
      } else {
        final url = preferredUrl ?? await _resolveUrl(song);
        handedUrl = url;
        // A newer play request may have been issued while the URL was being
        // resolved. Starting this stale track now would silently play the
        // wrong song, so drop it.
        if (token != _playToken || _disposed) return;
        if (preferredUrl == null) {
          // Fresh track: give the following link a bounded chance to resolve
          // before this one becomes audible, so an immediate screen lock cannot
          // catch the queue without its next URL. A item already prepared in
          // standby is handed over instantly instead.
          await warm.timeout(_warmBudget, onTimeout: () {});
          if (token != _playToken || _disposed) return;
        }
        _handedOff = true;
        final sessionIsOurs = await _activateSession(reason: '起播前激活');
        if (token != _playToken || _disposed) return;
        final load = service.playUrl(url, initialPosition: initialPosition);
        // `playUrl` has synchronously invalidated/promoted the standby before
        // starting the load, so this arms the *next* item's player without
        // racing the current one. The standby load is native and survives the
        // screen locking, unlike a URL resolve.
        handedToPlayer = true;
        _armPreparedNext();
        await load;
        if (!sessionIsOurs) {
          // The session refused to become ours, so this item would run silently.
          // Re-arm once right after the handoff; if it is still mute the
          // watchdog catches it within one window instead of leaving the user to
          // discover it by tapping the play button.
          debugLog?.record('会话未接管，起播后补激活 ${song.name}', <String, Object?>{
            'URL': handedUrl,
            '前台': _appInForeground,
          });
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (token != _playToken || _disposed) return;
          await _activateSession(reason: '激活失败补救');
        }
      }
      if (token != _playToken || _disposed) return;

      _loading = false;
      _statusText = null;
      _errorText = null;
      // This song just reached the native player, so any earlier "can't get a
      // link for it" verdict is obsolete — the automatic planner may use it again.
      _skippedThisRound.remove(_songKey(song));
      // Audible again: the queue-wide failure tally and the stock backoff are
      // history, and the pass through the list restarts from here.
      _consecutiveSkips = 0;
      _waitingForStock = false;
      _stockTried.clear();
      _lastProgressChangeAt = DateTime.now();
      final actualDuration = service.player.duration ?? service.duration;
      debugLog?.record('播放成功 ${song.name}', <String, Object?>{
        'URL': handedUrl,
        '时长': formatDuration(actualDuration),
        '播放器状态': '${service.player.processingState}',
      });
      await service.setMediaItem(song, duration: actualDuration);
      if (song.interval.trim().isEmpty && actualDuration > Duration.zero) {
        libraryState.updateSongInterval(song, formatDuration(actualDuration));
      }
      appState.settings.lastSongJson = song.toJson();
      appState.settings.lastPositionMs = initialPosition.inMilliseconds;
      _persistQueue();
      unawaited(appState.repository.save());
      unawaited(_loadLyrics(song));
      // Arm the following track immediately (not near the end of this one): the
      // user may lock the screen at any moment after playback starts.
      unawaited(_preloadNext(force: true));
      _notify();
    } catch (error, stack) {
      if (token != _playToken || _disposed) {
        debugLog?.record('播放作废 ${song.name}', <String, Object?>{
          '原因': '被新的播放请求取代或已销毁',
          '错误': '$error',
        });
        return;
      }
      if (allowRetry && !song.isLocal && sourceState.hasActiveSource) {
        debugLog?.record('播放失败重试 ${song.name}', <String, Object?>{
          '错误': '$error',
          '地址': handedUrl,
          '前台': _appInForeground,
          '堆栈': '$stack',
        });
        if (!_appInForeground) _resumeOnForeground = true;
        // A cached file that the player refused is worse than a bad link — it
        // would be preferred again on every attempt. Throw it away and let the
        // retry fall back to the remote address.
        if (runwayPath != null && handedUrl == runwayPath) {
          debugLog?.record('整曲缓存文件无法播放，丢弃 ${song.name}', <String, Object?>{
            '文件': runwayPath,
            '错误': '$error',
          });
          unawaited(runway?.drop(_songKey(song)));
        }
        _urlCache.remove(_songKey(song));
        _statusText = '播放失败，正在重试…';
        _notify();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (token != _playToken || _disposed) return;
        return _loadAndPlay(
          song,
          initialPosition: initialPosition,
          allowRetry: false,
          selection: selection,
        );
      }
      _loading = false;
      _isPlaying = false;
      // The current song did not reach the native player (or did not survive
      // the load). The native clock therefore still belongs to the previous
      // track; keeping its position would make a later foreground retry start
      // the next song near its end.
      _handedOff = false;
      _position = Duration.zero;
      _watchPosition = Duration.zero;
      // All configured sources failed for this song: keep moving to the next
      // one instead of stalling, until either something plays or this pass
      // through the queue runs out. Behind the lock screen the source sandbox
      // cannot resolve anything, so only a track whose link — or whole file — is
      // already on the device counts as playable there.
      _markUnplayable(song, _friendlyError(error));
      final advance = _nextPlayableIndex();
      if (advance != null &&
          !_userPaused &&
          sourceState.hasActiveSource &&
          _queue.length > 1 &&
          _consecutiveSkips < _maxConsecutiveSkips) {
        _statusText = sourceState.lastPoolError == null
            ? '这首无法播放，正在试下一首…'
            : '无法播放：${sourceState.lastPoolError}';
        debugLog?.record('自动跳歌 → ${_queue[advance].name}', <String, Object?>{
          '失败歌曲': song.name,
          '错误': '$error',
          '失败地址': handedUrl,
          '源侧原因': sourceState.lastPoolError,
          '本轮已跳': _skippedThisRound.length,
          '连续跳过': _consecutiveSkips,
          '前台': _appInForeground,
          '下一首有货': _hasUsableCache(_queue[advance]),
        });
        _notify();
        await playSong(_queue[advance], queue: _queue, index: advance);
        return;
      }
      // Nothing to advance to, for one of two very different reasons: the queue
      // really ended (顺序播放 reaching its last track) or this pass simply has no
      // playable track left. Only the first may clear the play intent — clearing
      // it in the second case is what switched the lock screen to "paused",
      // disarmed the watchdog, and left the headset and car buttons inert until
      // the app was opened again.
      final ended = _upcoming(count: 1).isEmpty;
      if (!ended && !_userPaused && sourceState.hasActiveSource) {
        await _enterStockWait(
          song: song,
          reason: _friendlyError(error),
          error: '$error',
          stack: '$stack',
          url: handedUrl,
        );
        return;
      }
      _shouldPlay = false;
      _errorText = _friendlyError(error);
      if (!_appInForeground) {
        // Nothing can be fetched while suspended: queue an automatic retry for
        // the moment the app is back in the foreground.
        _resumeOnForeground = true;
      }
      var reason = _errorText!;
      final poolError = sourceState.lastPoolError;
      if (!song.isLocal && poolError != null && !reason.contains('音源')) {
        reason = '$reason（$poolError）';
      }
      _errorText = reason;
      _statusText = reason;
      debugLog?.record('播放终止 ${song.name}', <String, Object?>{
        '错误': '$error',
        '堆栈': '$stack',
        'URL': handedUrl,
      });
      _notify();
    }
  }

  String _songKey(Song song) => '${song.source}:${song.id}';

  /// Whether an address handed to the player points at a file on this device
  /// rather than a URL a source issued. Those need neither a network nor a link
  /// that has not expired yet.
  static bool _isLocalPath(String value) =>
      value.startsWith('/') || value.startsWith('file://');

  /// Whether a track can be started *now* without asking a source for anything:
  /// its whole file is on disk, or its link is still inside its validity window.
  bool _hasUsableCache(Song song) {
    if (_runwayPath(song) != null) return true;
    final cached = _urlCache[_songKey(song)];
    return cached != null && cached.expiresAt.isAfter(DateTime.now());
  }

  /// Whether [song] has been given up on during this pass through the queue.
  bool _isMarkedUnplayable(Song song) => _skippedThisRound.contains(_songKey(song));

  /// Takes [song] out of this pass. Nothing is remembered about *why* — the next
  /// round re-derives it from the sources, which is the point: a track that is
  /// skipped today may be perfectly fine after a network hop or a source reload.
  ///
  /// Only called when a resolve could honestly have succeeded: behind the lock
  /// screen with a frozen WebView, or with no source enabled at all, a failure
  /// says nothing about the song.
  void _markUnplayable(Song song, String reason) {
    final key = _songKey(song);
    if (song.isLocal) {
      // The file itself is gone or unreadable: walking past it is the only way
      // the queue can continue, and the round reset gives it another try later.
      if (_skippedThisRound.add(key)) {
        _consecutiveSkips++;
        debugLog?.record('本地文件不可播，本轮跳过 ${song.name}', <String, Object?>{
          '原因': reason,
          '路径': song.localPath,
        });
      }
      return;
    }
    if (!sourceState.hasActiveSource) return;
    if (!_appInForeground && !sourceState.canResolveInBackground) return;
    // A missing route is a queue-wide problem. Marking the song anyway would let
    // one bad network walk the whole list into "already played" and stop playback
    // for good; the caller backs off and retries instead.
    if (_isQueueLevelFailure(reason)) {
      debugLog?.record('网络或取链失败，不判死这首歌 ${song.name}', <String, Object?>{
        '原因': reason,
        '前台': _appInForeground,
      });
      return;
    }
    if (_skippedThisRound.contains(key)) return;
    _skippedThisRound.add(key);
    _consecutiveSkips++;
    debugLog?.record('本轮跳过 ${song.name}', <String, Object?>{
      '原因': reason,
      '本轮已跳': _skippedThisRound.length,
      '连续跳过': _consecutiveSkips,
      '前台': _appInForeground,
    });
  }

  /// Failures that describe the connection or the source pool rather than the
  /// track: a timeout, an unroutable host, a request the system refused.
  static bool _isQueueLevelFailure(String text) {
    final lower = text.toLowerCase();
    for (final needle in <String>[
      '网络',
      '超时',
      'timeout',
      'timed out',
      'socketexception',
      '连接',
      '连不上',
      'unreachable',
      'not online',
      'offline',
      'dns',
      '代理',
      'ssl handshake',
      '无法解析地址',
    ]) {
      if (text.contains(needle) || lower.contains(needle)) return true;
    }
    return false;
  }

  /// Whether the runway cache is switched on for this run.
  bool get preloadRunwayOn => appState.settings.preloadRunway && runway != null;

  /// The runway copy of [song] when the cache is on and holds one — a whole track
  /// that needs no link, no source and no network to start.
  String? _runwayPath(Song song) {
    final cache = runway;
    if (cache == null || !preloadRunwayOn) return null;
    return cache.pathFor(_songKey(song));
  }

  /// Skips already served from local stock during the current wait, so the retry
  /// cadence cannot re-play the same fallback over and over.
  final Set<String> _stockTried = <String>{};
  bool _inStockWait = false;
  String? _lastFallbackKey;

  /// Nothing in the queue can be started right now, yet the user still wants
  /// sound.
  ///
  /// The old behaviour cleared the play intent and paused, which stopped the
  /// silence watchdog (it returns without an intent), showed "paused" on the lock
  /// screen, and left the headset and car buttons doing nothing until the app was
  /// opened. Here the intent stays alive so [_checkAudible] keeps retrying on a
  /// backoff, and anything already on the device gets a chance to play before the
  /// wait even starts.
  Future<void> _enterStockWait({
    Song? song,
    String? reason,
    String? error,
    String? stack,
    String? url,
  }) async {
    if (_inStockWait) return;
    _inStockWait = true;
    try {
      final now = DateTime.now();
      _nextStockRetryAt = now.add(
        _appInForeground ? _stockRetryLeadForeground : _stockRetryLeadBackground,
      );
      _waitingForStock = true;
      _isPlaying = false;
      _errorText = reason;
      _statusText = '暂无可用资源，正在自动重试（${_skippedThisRound.length} 首已跳过）';
      // A track that can only be fetched by JavaScript still has to wait for the
      // foreground; the retry below covers the in-process engine case.
      _resumeOnForeground = !_appInForeground;
      debugLog?.record('队列暂无可用资源 ${song?.name ?? _current?.name}', <String, Object?>{
        '原因': reason,
        '错误': error,
        '地址': url,
        '堆栈': stack,
        '本轮已跳': _skippedThisRound.length,
        '连续跳过': _consecutiveSkips,
        '下次重试': '${_nextStockRetryAt.difference(now).inSeconds}s',
        '前台': _appInForeground,
        '已下整曲': runway?.cachedCount,
      });
      _notify();
      // Something on this device may already be playable: a downloaded file of a
      // later track, or a song from the library. Trying it first is what turns a
      // silent stall into continuous audio.
      if (await _playBoundaryStock()) return;
      await service.pause();
    } finally {
      _inStockWait = false;
    }
  }

  /// One retry of the queue while it had nothing to play.
  Future<void> _retryStock() async {
    if (_disposed || !_waitingForStock || _userPaused) return;
    _stockTried.clear();
    _consecutiveSkips = 0;
    debugLog?.record('重试队列取链', <String, Object?>{
      '前台': _appInForeground,
      '本轮已跳': _skippedThisRound.length,
      '已下整曲': runway?.cachedCount,
      '当前': _current?.name,
    });
    var target = _nextPlayableIndex();
    // A pass that has walked past every track is a finished round: the sources
    // have had another minute to come back, so all songs get a fresh chance.
    if (target == null && _skippedThisRound.isNotEmpty) {
      _startNewRound();
      target = _nextPlayableIndex();
    }
    if (target != null) {
      _waitingForStock = false;
      await playSong(_queue[target],
          queue: _queue, index: target, reason: '等待资源后重试');
      return;
    }
    // Still nothing the queue can start — local stock is the only sound left.
    if (await _playBoundaryStock()) return;
    _nextStockRetryAt = DateTime.now().add(
      _appInForeground ? _stockRetryLeadForeground : _stockRetryLeadBackground,
    );
  }

  /// Start anything already on this device that the queue can still use.
  ///
  /// The runway copy of a track the list is about to reach comes first, because
  /// that is the real queue continuing. Only when the device has none of those
  /// left does the library fallback take over.
  Future<bool> _playBoundaryStock() async {
    if (_disposed || _userPaused || !_shouldPlay) return false;
    if (_queue.isEmpty || _index < 0) return false;
    for (final index in _upcoming(count: _maxAdvanceScan)) {
      if (_disposed || index < 0 || index >= _queue.length) continue;
      final song = _queue[index];
      if (appState.isDisliked(song)) continue;
      final key = _songKey(song);
      if (_stockTried.contains(key)) continue;
      if (!song.isLocal && _runwayPath(song) == null) continue;
      if (song.isLocal && (song.localPath == null || song.localPath!.isEmpty)) continue;
      _stockTried.add(key);
      debugLog?.record(
          song.isLocal ? '边界改播队列内本地曲 ${song.name}' : '边界走整曲文件 ${song.name}',
          <String, Object?>{
            '队列位置': index,
            '前台': _appInForeground,
            '本轮已跳': _skippedThisRound.length,
          });
      _waitingForStock = false;
      await playSong(song, queue: _queue, index: index, reason: song.isLocal ? '本地兜底' : '整曲缓存');
      return true;
    }
    return _playLibraryFallback();
  }

  /// A song the device can play without any source at all.
  Song? _pickLibraryFallback() {
    final pools = <List<Song>>[
      libraryState.localPlaylist.songs,
      libraryState.lovePlaylist.songs,
      for (final playlist in libraryState.userPlaylists) playlist.songs,
    ];
    final currentKey = _current == null ? '' : _songKey(_current!);
    for (final pool in pools) {
      for (final song in pool) {
        if (!song.isLocal) continue;
        final path = song.localPath;
        if (path == null || path.isEmpty) continue;
        final key = _songKey(song);
        if (key == currentKey || key == _lastFallbackKey) continue;
        if (!File(path).existsSync()) continue;
        return song;
      }
    }
    return null;
  }

  /// Last resort: keep making sound with a song the device already has.
  ///
  /// Chosen by the user and downloaded earlier, so it is closer to what they want
  /// than silence is. The queue itself is left where it was — the playhead does
  /// not move — so the next boundary resumes the real playlist as soon as the
  /// sources answer again.
  Future<bool> _playLibraryFallback() async {
    final song = _pickLibraryFallback();
    if (song == null) return false;
    _lastFallbackKey = _songKey(song);
    _waitingForStock = true;
    _nextStockRetryAt = DateTime.now().add(
      _appInForeground ? _stockRetryLeadForeground : _stockRetryLeadBackground,
    );
    debugLog?.record('兜底改播本机已下载的歌 ${song.name}', <String, Object?>{
      '歌手': song.singer,
      '队列位置': _index,
      '前台': _appInForeground,
      '原因': _errorText,
    });
    _current = song;
    _position = Duration.zero;
    _duration = Duration.zero;
    _lyrics = const <LyricLine>[];
    _activeLine = -1;
    _errorText = null;
    _statusText = '音源暂无可用资源，先播本机已下载的歌曲';
    _notify();
    // The queue must resume at the same place: this song is not part of it, so
    // [_index] and the plan are deliberately untouched.
    await _loadAndPlay(song, reason: '本机兜底');
    return true;
  }

  /// A full pass found nothing left to play: the round ends here and every song
  /// gets another chance.
  void _startNewRound() {
    if (_skippedThisRound.isEmpty) return;
    debugLog?.record('过完一轮，重新给每首歌机会', <String, Object?>{
      '跳过数量': _skippedThisRound.length,
      '前台': _appInForeground,
    });
    _skippedThisRound.clear();
  }

  /// The next [count] upcoming tracks that this pass has not given up on, in the
  /// order an automatic advance would use them. The search window is wider than
  /// [count] so a dead song in front does not shorten the runway.
  ///
  /// An empty result means the whole queue has been walked past: that is the end
  /// of the round, and the caller decides whether to start a new one. Planning a
  /// skipped track here would re-fail it on every pass and keep a broken source
  /// from ever letting the list move on.
  List<int> _upcomingUnmarked({int count = _planSearchWidth}) {
    final result = <int>[];
    for (final item in _upcoming(count: count + _skippedThisRound.length + 2)) {
      if (result.length >= count) break;
      if (item < 0 || item >= _queue.length) continue;
      if (_isMarkedUnplayable(_queue[item])) continue;
      result.add(item);
    }
    return result;
  }

  /// Indices still to be played, in the order an automatic advance will actually
  /// use them. Random mode used to re-roll at the moment of switching, so the
  /// links that had been pre-fetched belonged to different tracks and a
  /// single-loop queue never pre-fetched anything at all; deciding the order once
  /// here makes the pre-fetch and the advance agree.
  List<int> _upcoming({int count = 3}) {
    if (_queue.isEmpty || _index < 0) return const <int>[];
    _nextPlan.removeWhere((item) => item < 0 || item >= _queue.length);
    while (_nextPlan.length < count + 2) {
      final tail = _nextPlan.isEmpty ? _index : _nextPlan.last;
      final step = _stepAfter(tail);
      if (step < 0) break;
      // A single-loop plan needs exactly one self entry: it is the link the
      // replay reuses, and repeating it would only re-resolve the same song.
      if (step == tail && _nextPlan.isNotEmpty) break;
      if (playMode != PlayMode.singleLoop && _nextPlan.contains(step)) break;
      _nextPlan.add(step);
    }
    final result = <int>[];
    for (final item in _nextPlan) {
      if (result.length >= count) break;
      // Repeating the current track is the point in single-loop mode, and in any
      // mode when the queue holds only that song.
      if (item == _index && playMode != PlayMode.singleLoop && _queue.length > 1) {
        continue;
      }
      if (appState.isDisliked(_queue[item])) continue;
      result.add(item);
    }
    return result;
  }

  /// The track a failure or an automatic advance should move to, or null when
  /// nothing can be started right now. Behind the lock screen this only depends
  /// on what the device already holds — a downloaded file, a cached link, the
  /// standby item — when the source script had to fall back to a WKWebView; the
  /// in-process engine can resolve like it does in the foreground.
  ///
  /// Tracks this pass already skipped are never returned: they count as already
  /// played until the round ends. Returning the plain order anyway was what made
  /// a single dead song soak up every advance attempt behind the lock screen.
  int? _nextPlayableIndex() {
    final choices = _upcomingUnmarked(count: _maxAdvanceScan);
    if (choices.isEmpty) return null;
    if (_appInForeground || sourceState.canResolveInBackground) {
      return choices.first;
    }
    for (final item in choices) {
      final song = _queue[item];
      if (song.isLocal || _playableWithoutSandbox(item)) return item;
    }
    return null;
  }

  /// Forget the decided order after the queue, the position or the play mode
  /// changed. [_upcoming] repopulates it on the next call.
  void _invalidatePlan() {
    _nextPlan = <int>[];
    // A new queue or a new play order is new evidence: every song gets a clean
    // pass instead of inheriting the last one's verdicts.
    if (_skippedThisRound.isNotEmpty) {
      debugLog?.record('队列或模式变化，清空本轮跳过标记', <String, Object?>{
        '数量': _skippedThisRound.length,
      });
    }
    _skippedThisRound.clear();
    _consecutiveSkips = 0;
    _waitingForStock = false;
    _stockTried.clear();
  }

  /// After the index moved, keep whatever is left of the plan that still applies
  /// so an already pre-fetched link is not thrown away.
  void _syncPlanAfterIndexChange() {
    if (_nextPlan.isEmpty) return;
    final at = _nextPlan.indexOf(_index);
    _nextPlan = at >= 0 ? _nextPlan.sublist(at + 1) : <int>[];
  }

  int _stepAfter(int from) {
    if (_queue.isEmpty) return -1;
    switch (playMode) {
      case PlayMode.random:
        // A one-track queue has nowhere to randomise to; repeat it like the
        // other loop modes instead of ending playback.
        if (_queue.length <= 1) return from;
        return _randomIndexAwayFrom(<int>{from, ..._nextPlan});
      case PlayMode.listLoop:
        return (from + 1) % _queue.length;
      case PlayMode.sequence:
        return from + 1 < _queue.length ? from + 1 : -1;
      case PlayMode.singleLoop:
        return from;
    }
  }

  int _randomIndexAwayFrom(Set<int> used) {
    final available = <int>[];
    for (var i = 0; i < _queue.length; i++) {
      if (!used.contains(i)) available.add(i);
    }
    if (available.isEmpty) return -1;
    return available[Random().nextInt(available.length)];
  }

  /// A cached link that is about to expire must be replaced, not served: on a
  /// four-minute track plus a long lock-screen stretch the tail of the queue would
  /// otherwise die on URLs that expired while nothing was listening.
  static bool _isGoingStale(_CachedUrl cached, DateTime now) =>
      cached.expiresAt.difference(now) <= _urlRefreshLead;

  void _cacheUrl(String key, String url, {String type = 'mp3'}) {
    _urlCache[key] = _CachedUrl(
      url: url,
      type: type,
      expiresAt: DateTime.now().add(_urlTtl),
    );
    if (_urlCache.length <= _maxCachedUrls) return;
    // Drop the entries closest to expiry instead of wiping the whole map: one
    // long queue walked end-to-end used to throw away the links the next
    // few tracks depend on.
    final keep = _current == null ? <String>{} : {_songKey(_current!)};
    final doomed = _urlCache.entries.toList()
      ..sort((a, b) => a.value.expiresAt.compareTo(b.value.expiresAt));
    for (final entry in doomed) {
      if (_urlCache.length <= _maxCachedUrls) break;
      if (keep.contains(entry.key)) continue;
      _urlCache.remove(entry.key);
    }
  }

  Future<String> _resolveUrl(Song song) async {
    final key = _songKey(song);
    final now = DateTime.now();
    final cached = _urlCache[key];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      // With a frozen WebView even a nearly-expired link beats a resolve that
      // can never finish. The in-process engine has no such limit, so it can
      // refresh proactively in the background as well.
      final cannotResolve =
          !_appInForeground && !sourceState.canResolveInBackground;
      if (cannotResolve || !_isGoingStale(cached, now)) return cached.url;
    }
    final pending = sourceState.resolveMusicUrlAutoSwitch(
      song,
      background: !_appInForeground,
    );
    try {
      final resolved = _appInForeground
          ? await pending
          : await pending.timeout(
              _backgroundResolveTimeout,
              onTimeout: () => throw StateError(
                '后台取链超时，回前台后会自动重试',
              ),
            );
      final url = '${resolved['url'] ?? ''}';
      if (url.isEmpty) throw StateError('没有获取到播放链接');
      _cacheUrl(key, url, type: '${resolved['type'] ?? 'mp3'}');
      unawaited(_stockFromUrl(song));
      return url;
    } catch (error) {
      // A refresh that failed must not lose the song we could still play.
      if (cached != null && cached.expiresAt.isAfter(now)) {
        debugLog?.record('刷新链接失败，沿用旧地址 ${song.name}', <String, Object?>{
          '错误': '$error',
          '旧地址剩余': '${cached.expiresAt.difference(now).inSeconds}s',
        });
        return cached.url;
      }
      rethrow;
    }
  }

  /// Queue the whole file of a song into the runway cache now that its link is
  /// known.
  ///
  /// Answering immediately, this only starts a transfer when nothing else is
  /// downloading, so the next tracks are fetched in the background without ever
  /// competing with the audio the user is hearing. A link is worth minutes; the
  /// file behind it is worth the whole track boundary.
  Future<void> _stockFromUrl(Song song) async {
    final cache = runway;
    if (cache == null || !preloadRunwayOn || song.isLocal) return;
    final depth = appState.settings.runwayDepthClamped;
    if (depth == 0) return;
    final key = _songKey(song);
    // Only the few tracks the setting asks for are worth a transfer. Links of the
    // tracks further ahead are still resolved — they just stay as links until the
    // playhead gets close enough for the file to matter.
    final ahead = _upcomingUnmarked(count: depth);
    if (!ahead.any((index) => _songKey(_queue[index]) == key)) return;
    if (cache.pathFor(key) != null || cache.isBusy(key)) return;
    final cached = _urlCache[key];
    if (cached == null || !cached.expiresAt.isAfter(DateTime.now())) return;
    await cache.ensure(key: key, url: cached.url, type: cached.type);
  }

  /// Trim the runway down to the tracks the queue can still reach.
  ///
  /// Called at every boundary: what has been heard is deleted, so a long drive
  /// cannot quietly fill the device with audio that is already in the past, and
  /// the cache keeps its few slots for the tracks ahead.
  Future<void> _pruneRunway() async {
    final cache = runway;
    if (cache == null || !preloadRunwayOn) return;
    final ahead = <String>[
      if (_index >= 0 && _index < _queue.length) _songKey(_queue[_index]),
      ..._upcomingUnmarked(count: appState.settings.runwayDepthClamped + 1)
          .map((index) => _songKey(_queue[index])),
    ];
    await cache.prune(ahead: ahead);
  }

  /// Drop the prepared standby item and forget which track it belonged to.
  /// Called whenever the queue, the play mode or the selected song changes, so
  /// a stale "next" can never be promoted at the boundary.
  void _invalidatePreload() {
    _preloadEpoch++;
    _plannedNextSong = null;
    _plannedNextIndex = -1;
    _plannedNextUrl = null;
    _armChain = 0;
    unawaited(service.clearPreload());
  }

  /// Resolve the link of the track the queue will play next — without touching
  /// the standby player. This runs while the current track is being loaded, so
  /// the link is in hand even if the screen locks the instant playback starts.
  ///
  /// With the in-process source engine this also works behind the lock screen;
  /// for a script that had to fall back to the WKWebView only an already cached
  /// link can be used, but computing the plan and arming the standby from that
  /// cache is exactly what keeps consecutive lock-screen skips playing.
  Future<void> _warmNextLink() async {
    if (_disposed || _queue.isEmpty || _index < 0) return;

    final plannedIndex = _plannedNextIndex;
    final plannedSong = _plannedNextSong;
    final plannedUrl = _plannedNextUrl;
    if (plannedIndex >= 0 &&
        plannedIndex < _queue.length &&
        plannedSong != null &&
        plannedUrl != null &&
        _queue[plannedIndex].id == plannedSong.id &&
        _queue[plannedIndex].source == plannedSong.source &&
        !_isMarkedUnplayable(plannedSong)) {
      // Already decided and resolved; `_armPreparedNext` only has to make sure
      // the standby is (or will be) loaded. A file — the song's own or a runway
      // copy — never expires; a remote link is only reused while it is loaded or
      // still cached.
      if (plannedSong.isLocal ||
          _isLocalPath(plannedUrl) ||
          service.hasPrepared(plannedUrl)) {
        return;
      }
      final cached = _urlCache[_songKey(plannedSong)];
      if (cached != null &&
          cached.url == plannedUrl &&
          cached.expiresAt.isAfter(DateTime.now())) {
        return;
      }
      // The link expired before the standby ever loaded it: decide again.
      _plannedNextSong = null;
      _plannedNextIndex = -1;
      _plannedNextUrl = null;
    }

    // Walk the runway until something can actually be prepared. A song no source
    // can serve must not leave the standby empty — that is exactly what makes the
    // queue go silent at the boundary until the app is opened again.
    for (final nextIndex in _upcomingUnmarked(count: _planSearchWidth)) {
      if (_disposed) return;
      if (nextIndex < 0 || nextIndex >= _queue.length) continue;
      final song = _queue[nextIndex];
      if (appState.isDisliked(song)) continue;

      if (song.isLocal) {
        final path = song.localPath;
        if (path == null || path.isEmpty) continue;
        _plannedNextSong = song;
        _plannedNextIndex = nextIndex;
        _plannedNextUrl = path;
        return;
      }

      // A downloaded file is the best possible standby: the boundary then opens a
      // file, and neither an expiring link nor a source that stopped answering can
      // reach it. Prefer it over the remote address even when both are available.
      final runwayPath = _runwayPath(song);
      if (runwayPath != null) {
        _plannedNextSong = song;
        _plannedNextIndex = nextIndex;
        _plannedNextUrl = runwayPath;
        unawaited(_prefetchLookahead());
        return;
      }

      final key = _songKey(song);
      final cached = _urlCache[key];
      if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
        _plannedNextSong = song;
        _plannedNextIndex = nextIndex;
        _plannedNextUrl = cached.url;
        unawaited(_stockFromUrl(song));
        // Keep filling the cache for the tracks after this one while JavaScript
        // still runs.
        unawaited(_prefetchLookahead());
        return;
      }

      if (!sourceState.hasActiveSource) return;
      if (!_preloading.add(key)) return;
      final epoch = _preloadEpoch;
      try {
        final resolved = await sourceState.resolveMusicUrlAutoSwitch(
          song,
          background: !_appInForeground,
        );
        if (_disposed || epoch != _preloadEpoch) return;
        final url = '${resolved['url'] ?? ''}';
        if (url.isEmpty) {
          _markUnplayable(song, '所有源都没有返回播放链接');
          continue;
        }
        _cacheUrl(key, url, type: '${resolved['type'] ?? 'mp3'}');
        unawaited(_stockFromUrl(song));
        _plannedNextSong = song;
        _plannedNextIndex = nextIndex;
        _plannedNextUrl = url;
        debugLog?.record('预热下一首 ${song.name}', <String, Object?>{
          '队列位置': nextIndex,
          '前台': _appInForeground,
          '本轮已跳过': _skippedThisRound.length,
        });
        unawaited(_prefetchLookahead());
        return;
      } catch (error) {
        if (_disposed || epoch != _preloadEpoch) return;
        // Nobody could serve this song, so cool it down and try the one behind it
        // inside this same pass instead of waiting for the next position tick.
        _markUnplayable(song, _friendlyError(error));
      } finally {
        _preloading.remove(key);
      }
    }
  }

  /// Hand the resolved "next" link to the standby player.
  ///
  /// Must be called *after* the current item has been handed to the service:
  /// `playUrl`/`playFile` invalidate or promote the old standby synchronously
  /// before starting their load, so arming here cannot race the current track.
  void _armPreparedNext() {
    final song = _plannedNextSong;
    final url = _plannedNextUrl;
    if (_disposed || song == null || url == null || url.isEmpty) return;
    if (service.hasPrepared(url)) return;
    if (song.isLocal || _isLocalPath(url)) {
      unawaited(service.preloadFile(url));
    } else {
      unawaited(service.preloadUrl(url));
    }
  }

  /// The standby refused the link we planned for the next track.
  ///
  /// This is the background case that used to stall the queue: the current song
  /// is still audible, so no error reaches [_handlePlayerError] and no boundary
  /// has happened yet — without this the standby simply stays empty and the
  /// queue goes silent as soon as the track ends. Mark the song and immediately
  /// plan and arm the one behind it, bounded so a queue of dead links cannot
  /// chain-load forever.
  void _handleStandbyLoadFailed(String url, String error) {
    if (_disposed) return;
    if (_plannedNextUrl != url) return;
    final song = _plannedNextSong;
    if (song == null) return;
    _markUnplayable(song, '备用播放器拒绝加载：${_friendlyError(error)}');
    _plannedNextSong = null;
    _plannedNextIndex = -1;
    _plannedNextUrl = null;
    if (_armChain >= _maxArmChain) {
      debugLog?.record('下一首连续装填失败，暂停顺延', <String, Object?>{
        '已试': _armChain,
        '前台': _appInForeground,
        '最后错误': _friendlyError(error),
      });
      return;
    }
    _armChain++;
    unawaited(_warmNextLink().then((_) => _armPreparedNext()));
  }

  /// Resolve the links of the tracks *after* the prepared next one while the
  /// source sandbox is still running. These are what the lock-screen
  /// next-button chain uses once JavaScript is frozen.
  Future<void> _prefetchLookahead() async {
    if (_disposed || _current == null) return;
    if (!sourceState.hasActiveSource) return;
    final now = DateTime.now();
    if (now.difference(_lastLookaheadAttempt) < const Duration(seconds: 45)) {
      return;
    }
    _lastLookaheadAttempt = now;
    final epoch = _preloadEpoch;
    // A car drive can last through many tracks while the screen stays locked,
    // and every skip consumes one cached link. Resolve a deeper runway while
    // the sandbox is still awake.
    for (final index in _upcoming(count: 6)) {
      if (index < 0 || index >= _queue.length) continue;
      final song = _queue[index];
      if (song.isLocal || appState.isDisliked(song)) continue;
      // Cooling-down tracks are left alone: they get another chance through the
      // plan, and re-resolving them here would only burn the source's budget.
      if (_isMarkedUnplayable(song)) continue;
      final key = _songKey(song);
      final cached = _urlCache[key];
      if (cached != null &&
          cached.expiresAt.isAfter(now.add(const Duration(minutes: 2))) &&
          !_isGoingStale(cached, now)) {
        continue;
      }
      if (_preloading.contains(key)) continue;
      _preloading.add(key);
      try {
        final resolved = await sourceState.resolveMusicUrlAutoSwitch(
          song,
          background: !_appInForeground,
        );
        if (_disposed || epoch != _preloadEpoch) return;
        final url = '${resolved['url'] ?? ''}';
        if (url.isEmpty) {
          _markUnplayable(song, '所有源都没有返回播放链接');
          continue;
        }
        _cacheUrl(key, url, type: '${resolved['type'] ?? 'mp3'}');
        // The link is only worth minutes; its file is worth the whole track. This
        // is where a deep runway actually gets filled — one download at a time,
        // behind whatever the player is already doing.
        unawaited(_stockFromUrl(song));
        debugLog?.record('预取链接成功 ${song.name}', <String, Object?>{
          '队列位置': index,
          '有效期': '${_urlTtl.inMinutes}分钟',
          '已下整曲': runway?.cachedCount,
        });
      } catch (error) {
        // Preloading is best effort, but a song no source can serve is worth
        // remembering: the deeper the runway, the less often the preloader has
        // to retry a dead track while the screen is locked.
        if (_disposed || epoch != _preloadEpoch) return;
        _markUnplayable(song, _friendlyError(error));
      } finally {
        _preloading.remove(key);
      }
    }
  }

  /// Periodic preload entry point (position ticks, lifecycle transitions).
  /// Ensures the following track is decided, resolved and handed to the
  /// standby player.
  Future<void> _preloadNext({bool force = false}) async {
    if (_current == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPreloadAttempt) < const Duration(seconds: 8)) {
      return;
    }
    _lastPreloadAttempt = now;
    // This is the periodic pass, so it owns the retry pacing: give a burst of
    // standby reloads a fresh budget here rather than letting the failure
    // handler chain on its own forever.
    _armChain = 0;
    await _warmNextLink();
    if (_disposed) return;
    _armPreparedNext();
    unawaited(_prefetchLookahead());
    // A boundary or a fresh plan means the order moved: drop what the playhead
    // has left behind so the cache keeps its slots for the tracks still to come.
    unawaited(_pruneRunway());
  }

  /// A link can fail only once the player starts reading its stream (an expired
  /// token answering 403, a body that turns out not to be audio). `play()` is no
  /// longer awaited, so those errors arrive here; reuse the normal load path so
  /// retry / 换源 / 自动跳歌 still apply, bounded so a permanently dead link cannot
  /// loop.
  ///
  /// The old guard was `if (_loading) return`, which threw away every error that
  /// landed while a retry was in flight — the background silence looked like an
  /// ordinary fetch. An error can only belong to a URL the native player already
  /// has, so the presence of a hand-off is what makes it ours.
  Future<void> _handlePlayerError(String message) async {
    if (_disposed) return;
    final song = _current;
    if (song == null || song.isLocal || _userPaused) return;
    if (_loading && !_handedOff) return;
    if (_playErrorAttempts >= 2) {
      debugLog?.record('播放器报错已达上限 ${song.name}', <String, Object?>{
        '错误': message,
        '前台': _appInForeground,
      });
      // The link is dead and this song has used up its retries. Sitting here is
      // what looked like "the queue stops behind the lock screen until the app is
      // opened": cool the song down and move on, bounded by the same round limit
      // the load path uses so a wholly unplayable queue cannot loop.
      _urlCache.remove(_songKey(song));
      _markUnplayable(song, _friendlyError(message));
      if (_consecutiveSkips < _maxConsecutiveSkips) {
        _playErrorAttempts = 0;
        unawaited(next(auto: true));
      } else {
        // Every candidate died on its stream in a row: the queue is out of
        // playable tracks, not just this one. Back off and keep trying instead of
        // stopping on a song the player refuses to buffer.
        unawaited(_enterStockWait(
          song: song,
          reason: _friendlyError(message),
          error: message,
        ));
      }
      return;
    }
    _playErrorAttempts++;
    debugLog?.record('播放器报错处理 ${song.name}', <String, Object?>{
      '错误': message,
      '第几次补救': _playErrorAttempts,
      '前台': _appInForeground,
      '在加载': _loading,
    });
    _urlCache.remove(_songKey(song));
    await _loadAndPlay(song, initialPosition: _position, reason: '播放器报错');
  }

  /// iOS surfaces failed media links as bare AVFoundation/NSURLError codes,
  /// which say nothing useful on screen. The debug log keeps the raw error.
  static const Map<String, String> _playerHints = <String, String>{
    '-1102': '音频地址被拒绝或已过期，正在换源',
    '-11850': '音频流中断，这个地址大概不是音频',
    '-11800': '播放器无法加载这个音频地址',
    '-11821': '音频格式无法识别',
    '-1004': '连不上音频服务器',
    '-1009': '网络不可用，取不到音频',
    '-1022': '该音频地址的连接方式被系统拦截',
  };

  String _friendlyError(Object error) {
    var message = error.toString();
    for (final prefix in <String>['Exception: ', 'StateError: ', 'Bad state: ']) {
      if (message.startsWith(prefix)) message = message.substring(prefix.length);
    }
    final code = RegExp(r'Code=(-?\d+)').firstMatch(message)?.group(1) ??
        RegExp(r'\((-1\d{3,4})\)').firstMatch(message)?.group(1);
    final hint = code == null ? null : _playerHints[code];
    return hint ?? message;
  }

  Future<void> _loadLyrics(Song song) async {
    List<LyricLine> lines = const <LyricLine>[];
    try {
      if (song.isLocal && song.localPath != null) {
        final lrcFile = File(p.setExtension(song.localPath!, '.lrc'));
        if (await lrcFile.exists()) {
          lines = LyricParser.parse(await lrcFile.readAsString());
        }
      }
      // The built-in engine still lives in a WKWebView; asking it for lyrics
      // behind the lock screen would only park a 35 s timeout per track. The
      // text is not visible then anyway — the foreground resume fetches it.
      if (lines.isEmpty && !song.isLocal && _appInForeground) {
        final result = await onlineEngine.call(
          'lyric',
          <String, dynamic>{'source': song.source, 'song': song.raw},
        );
        if (result is Map) {
          final map = Map<String, dynamic>.from(result);
          lines = LyricParser.parse(
            '${map['lyric'] ?? ''}',
            translation: appState.settings.showTranslation ? '${map['tlyric'] ?? ''}' : null,
          );
        }
      }
    } catch (_) {
      lines = const <LyricLine>[];
    }
    if (_current?.id != song.id || _disposed) return;
    _lyrics = lines;
    _activeLine = LyricParser.activeIndex(lines, _position);
    _notify();
  }

  Future<void> togglePlay() async {
    if (_current == null) {
      if (_queue.isNotEmpty) {
        await playSong(_queue.first, queue: _queue, index: 0, reason: '队列首曲');
      }
      return;
    }
    // Pressing the button while the queue is still probing for a link stops the
    // chain outright: the stale attempt is dropped by its token and nothing
    // advances until the user presses play again.
    if (_loading && !_handedOff) {
      _playToken++;
      _loading = false;
      _handedOff = false;
      _isPlaying = false;
      _shouldPlay = false;
      _userPaused = true;
      _resumeAfterInterruption = false;
      _statusText = '已停止';
      _errorText = null;
      unawaited(service.pause());
      debugLog?.record('用户按键停止跳歌', <String, Object?>{
        '当时在加载': true,
        '歌曲': _current?.name,
      });
      _notify();
      return;
    }
    final processing = service.player.processingState;
    if (_waitingForStock && !_handedOff) {
      // The play button while the queue has nothing to say: run the recovery
      // immediately instead of re-loading the single song that failed.
      _nextStockRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
      await _retryStock();
      return;
    }
    if (_shouldPlay && processing != ProcessingState.ready) {
      // The button says playing while the native player holds nothing playable.
      // That tap means "give me sound", not "pause" — re-arm the pipeline in
      // place instead of putting the user through pause + play.
      _silentHeals = 0;
      debugLog?.record('按键重挂音频 ${_current?.name}', <String, Object?>{
        '原生状态': '$processing',
        '位置': '${_position.inSeconds}s',
        '前台': _appInForeground,
      });
      await _healSilence();
      return;
    }
    if (willPlay) {
      await pause();
      return;
    }
    await play();
  }

  Future<void> play() async {
    _userPaused = false;
    if (_current == null) {
      await togglePlay();
      return;
    }
    if (_waitingForStock) {
      // The queue was empty of playable tracks; the lock-screen play button
      // means "try again now", so skip the rest of the backoff.
      _nextStockRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
      await _retryStock();
      return;
    }
    final processing = service.player.processingState;
    if (processing == ProcessingState.idle ||
        processing == ProcessingState.completed ||
        _errorText != null) {
      // A finished track reports its duration as the current position; start
      // over from zero instead of reloading the final second. The same goes for
      // a load that failed: whatever the native clock says belongs to the
      // previous track, not to this song.
      final start = processing == ProcessingState.completed || _errorText != null
          ? Duration.zero
          : _position;
      await _loadAndPlay(_current!, initialPosition: start, reason: '手动/控制中心播放');
      return;
    }
    _shouldPlay = true;
    // just_audio no longer activates the session on our behalf, so every resume
    // path — including the lock-screen play button routed here — has to take
    // ownership of it before the player is started.
    await _activateSession(reason: '恢复播放');
    if (_disposed) return;
    await service.play();
    _silentHeals = 0;
    _lastProgressChangeAt = DateTime.now();
    _notify();
  }

  Future<void> pause() async {
    _playToken++;
    _loading = false;
    _handedOff = false;
    _shouldPlay = false;
    _userPaused = true;
    _resumeAfterInterruption = false;
    // The fetching hint belongs to a load that is now abandoned; leaving it up
    // makes a paused track look like it is still looking for a link.
    if (_statusText == '正在获取播放链接…' ||
        _statusText == '正在准备播放…' ||
        _statusText == '播放失败，正在重试…') {
      _statusText = null;
    }
    await service.pause();
    _notify();
  }

  /// The platform stopped playback (for example the media session was torn
  /// down). Mirror that in the controller; otherwise [_shouldPlay] stays set and
  /// the watchdog would restart the queue a few seconds later.
  void _handleSystemStop() {
    _playToken++;
    _loading = false;
    _handedOff = false;
    _shouldPlay = false;
    _isPlaying = false;
    _userPaused = true;
    _statusText = null;
    _errorText = null;
  }

  Future<void> seek(Duration position) async {
    if (_current == null) return;
    _position = position;
    // A backwards seek would otherwise look like a stalled clock to the
    // watchdog, so re-anchor both samples.
    _watchPosition = position;
    _lastProgressChangeAt = DateTime.now();
    _notify();
    await service.seek(position);
  }

  /// Skip commands coming from the lock screen, a Bluetooth headset or a car
  /// head unit. The timestamp lets a pause sent as part of the same button
  /// press be recognised and ignored.
  Future<void> _handleRemoteSkipNext() async {
    _lastRemoteSkipAt = DateTime.now();
    _ignoreRemotePause = false;
    debugLog?.record('系统/蓝牙下一首', <String, Object?>{
      '前台': _appInForeground,
      '当前': _current?.name,
      '预排': _plannedNextSong?.name,
      '在播': _isPlaying,
      '在加载': _loading,
      '位置': '${_position.inSeconds}s',
    });
    await next();
  }

  Future<void> _handleRemoteSkipPrevious() async {
    _lastRemoteSkipAt = DateTime.now();
    _ignoreRemotePause = false;
    debugLog?.record('系统/蓝牙上一首', <String, Object?>{
      '前台': _appInForeground,
      '当前': _current?.name,
      '在播': _isPlaying,
      '位置': '${_position.inSeconds}s',
    });
    await previous();
  }

  /// System pause. A pause that head units send together with next/previous is
  /// swallowed: otherwise it stops the track that the skip just started.
  Future<void> _handleRemotePause() async {
    if (_ignoreRemotePause) {
      _ignoreRemotePause = false;
      debugLog?.record('忽略蓝牙切歌附带的暂停', <String, Object?>{
        '当前': _current?.name,
        '预排': _plannedNextSong?.name,
      });
      return;
    }
    await pause();
  }

  /// Whether [index] can be started without the source sandbox: a local file,
  /// the item already loaded in the standby player, or a link still cached.
  bool _playableWithoutSandbox(int index) {
    if (index < 0 || index >= _queue.length) return false;
    final song = _queue[index];
    if (song.isLocal) return true;
    // The custom-source script now runs in-process, so it can fetch a fresh
    // link even while the lock screen is up.
    if (sourceState.canResolveInBackground) return true;
    final preparedUrl = _plannedNextUrl;
    if (_plannedNextIndex == index &&
        preparedUrl != null &&
        service.hasPrepared(preparedUrl)) {
      return true;
    }
    return _hasUsableCache(song);
  }

  /// The track a skip lands on when the plain order cannot be started: the
  /// intended target first, then the closest later track this device can play
  /// without a source — its downloaded file, a live link, or the standby item.
  int? _findStockForSkip({required int start}) {
    if (_playableWithoutSandbox(start)) return start;
    for (final item in _upcomingUnmarked(count: _maxAdvanceScan)) {
      if (_playableWithoutSandbox(item)) return item;
    }
    return null;
  }

  Future<void> next({bool auto = false}) async {
    _userPaused = false;
    if (_queue.isEmpty) return;
    if (_current == null) {
      await playSong(_queue.first, queue: _queue, index: 0, reason: '队列首曲');
      return;
    }
    if (auto && playMode == PlayMode.singleLoop) {
      await _loadAndPlay(_current!, reason: '单曲循环');
      return;
    }

    // Both automatic and manual advances follow the pre-computed order, so the
    // track that starts is the one whose link and standby player are already
    // prepared. That is what lets the lock-screen next button start instantly
    // instead of waiting for a fresh network round trip.
    int nextIndex;
    if (auto) {
      final playable = _nextPlayableIndex();
      if (playable != null) {
        nextIndex = playable;
      } else if (_upcoming(count: 1).isEmpty) {
        // The list genuinely ran out (顺序播放 past its last track). Only this
        // case may end playback.
        nextIndex = -1;
      } else {
        // There are tracks left, but nothing this pass can start: no link, no
        // standby, no downloaded file. This used to pause and clear the play
        // intent, which silenced the lock screen, disarmed the watchdog, and made
        // the headset and car buttons inert until the app was opened again.
        // Keep the intent and let the retry cadence own it instead.
        await _enterStockWait(reason: _errorText);
        return;
      }
    } else {
      // Manual skips follow the same precomputed order as auto-advance, so the
      // track already sitting in the standby player (and its link) can be used
      // instantly — this is what makes the lock-screen next button work while
      // the source sandbox is frozen. Single-loop keeps the old meaning:
      // "next" is the following track, not a replay.
      int candidate;
      if (playMode == PlayMode.singleLoop) {
        candidate = _nextIndex(auto: false);
      } else {
        final planned = _plannedNextIndex;
        final plan = _upcoming(count: 3);
        candidate = planned >= 0 && planned < _queue.length
            ? planned
            : (plan.isEmpty ? -1 : plan.first);
      }
      var attempts = 0;
      while (candidate >= 0 &&
          candidate < _queue.length &&
          attempts < _queue.length &&
          appState.isDisliked(_queue[candidate])) {
        candidate = _indexAfter(candidate, auto: false);
        attempts++;
      }
      if (!_appInForeground && !_playableWithoutSandbox(candidate)) {
        // With a WebView fallback the source sandbox is frozen behind the lock
        // screen, so a fresh resolve can only time out and leave the car silent.
        // Take the next track this device can start without it; and when there is
        // none, still move the queue — a headset or car button that answers with
        // "下一首链接尚未准备好" and nothing else is the failure being fixed here.
        final stock = _findStockForSkip(start: candidate);
        if (stock == null) {
          debugLog?.record('后台切歌无现成资源，改为立即推进', <String, Object?>{
            '当前': _current?.name,
            '目标': candidate >= 0 && candidate < _queue.length
                ? _queue[candidate].name
                : null,
            '预排': _plannedNextSong?.name,
            '模式': playMode.label,
            '本轮已跳': _skippedThisRound.length,
            '已下整曲': runway?.cachedCount,
          });
          // The advance owns the recovery: it re-derives the order, walks past
          // what this pass skipped, and falls back to local stock.
          _waitingForStock = false;
          await next(auto: true);
          return;
        }
        candidate = stock;
      }
      nextIndex = candidate;
    }
    if (nextIndex < 0 || nextIndex >= _queue.length) {
      _isPlaying = false;
      _shouldPlay = false;
      _userPaused = true;
      _statusText = '播放完毕';
      await service.pause();
      _notify();
      return;
    }
    debugLog?.record('切歌 → ${_queue[nextIndex].name}', <String, Object?>{
      '触发': auto ? '自动（上一首播完）' : '手动',
      '前台': _appInForeground,
      '链接已缓存': _hasUsableCache(_queue[nextIndex]),
      '播放模式': playMode.label,
    });
    await playSong(_queue[nextIndex],
        queue: _queue, index: nextIndex, reason: auto ? '自动切歌' : '手动切歌');
  }

  int _nextIndex({bool auto = false}) {
    if (_queue.length <= 1) return _index;
    switch (playMode) {
      case PlayMode.random:
        return _randomIndex();
      case PlayMode.listLoop:
        return (_index + 1) % _queue.length;
      case PlayMode.sequence:
        return _index + 1;
      case PlayMode.singleLoop:
        return auto ? _index : (_index + 1) % _queue.length;
    }
  }

  int _indexAfter(int from, {bool auto = false}) {
    if (_queue.isEmpty) return -1;
    switch (playMode) {
      case PlayMode.random:
        return _randomIndex();
      case PlayMode.listLoop:
        return (from + 1) % _queue.length;
      case PlayMode.sequence:
        return from + 1 < _queue.length ? from + 1 : -1;
      case PlayMode.singleLoop:
        return from;
    }
  }

  int _randomIndex() {
    if (_queue.length <= 1) return _index;
    var next = _index;
    final random = Random();
    for (var i = 0; i < 10 && next == _index; i++) {
      next = random.nextInt(_queue.length);
    }
    if (next == _index) next = (_index + 1) % _queue.length;
    return next;
  }

  Future<void> previous() async {
    _userPaused = false;
    if (_current == null) return;
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_queue.isEmpty) return;
    int previousIndex;
    switch (playMode) {
      case PlayMode.random:
        previousIndex = _randomIndex();
        break;
      case PlayMode.sequence:
        previousIndex = max(0, _index - 1);
        break;
      case PlayMode.singleLoop:
        previousIndex = _index;
        break;
      case PlayMode.listLoop:
        previousIndex = (_index - 1 + _queue.length) % _queue.length;
        break;
    }
    await playSong(_queue[previousIndex],
        queue: _queue, index: previousIndex, reason: '上一首');
  }

  Future<void> _handleCompleted() async {
    if (_disposed || _advancing) return;
    // A duplicate completion arrives while the next track is already being
    // loaded; advancing again here would skip a song. The watchdog's
    // "abandoned background load" path clears [_loading] first, so it can still
    // take over from a load that never returned.
    if (_loading) return;
    if (_userPaused && !_shouldPlay) return;
    _advancing = true;
    try {
      await next(auto: true);
    } finally {
      _advancing = false;
    }
  }

  /// The service promoted the prepared standby at the track boundary and it is
  /// already audible. Mirror the new song; crucially, do **not** load anything:
  /// the whole point is that this path needs neither the network nor the frozen
  /// source sandbox, so it also works with the screen locked.
  void _handlePromotedNext() {
    if (_disposed) return;
    final song = _plannedNextSong;
    final index = _plannedNextIndex;
    _plannedNextSong = null;
    _plannedNextIndex = -1;
    _plannedNextUrl = null;
    if (song == null || index < 0 || index >= _queue.length) {
      if (_loading && _loadingIsSelection) {
        // The prepared item was consumed by the song selection that is already
        // loading; that load owns the state. Advancing here would skip a track.
        return;
      }
      // No usable record of what was promoted (should not happen): fall back to
      // the ordinary completion path so playback still continues.
      unawaited(_handleCompleted());
      return;
    }
    if (_loading && !_loadingIsSelection) {
      // A heal/retry of the track that just ended is still in flight. The
      // natural advance wins; cancel it before it can hand its stale item to
      // the player after this promotion.
      _playToken++;
    }
    _index = index;
    _current = song;
    _position = Duration.zero;
    _duration = service.duration;
    _lyrics = const <LyricLine>[];
    _activeLine = -1;
    _errorText = null;
    _statusText = null;
    _loading = false;
    _handedOff = true;
    _isPlaying = true;
    _shouldPlay = true;
    _userPaused = false;
    _playErrorAttempts = 0;
    // It is audible now, so this pass's verdict on it no longer applies.
    _skippedThisRound.remove(_songKey(song));
    _consecutiveSkips = 0;
    _waitingForStock = false;
    _stockTried.clear();
    _watchPosition = service.player.position;
    _silentHeals = 0;
    _lastProgressChangeAt = DateTime.now();
    _advancing = false;
    // The plan entry was just consumed; keep the remaining precomputed order so
    // the links that were already fetched for the following tracks still apply.
    _syncPlanAfterIndexChange();
    appState.settings.lastSongJson = song.toJson();
    appState.settings.lastPositionMs = 0;
    _persistQueue();
    unawaited(appState.repository.save());
    unawaited(service.setMediaItem(song, duration: service.duration));
    unawaited(_loadLyrics(song));
    // Arm the track after this one immediately, from cache if the screen is
    // still locked.
    unawaited(_preloadNext(force: true));
    debugLog?.record('边界晋升 ${song.name}', <String, Object?>{
      '队列位置': index,
      '前台': _appInForeground,
      '时长': formatDuration(service.duration),
    });
    _notify();
    if (appState.isDisliked(song)) {
      // It was marked "don't play" while waiting in the standby slot; keep the
      // queue moving instead of settling on it.
      unawaited(next(auto: true));
    }
  }

  /// Once a custom source becomes ready, silently retry a song that failed only
  /// because no usable source existed yet (for example the user just imported
  /// one). Gated on [_errorText] so it never steals playback from the restored
  /// "tap to continue" state or from a foreground resume.
  void _onSourceChanged() {
    if (_disposed) return;
    final activeId = sourceState.active?.id;
    if (activeId != _lastActiveSourceId) {
      _lastActiveSourceId = activeId;
      // The skip verdicts were earned against the previous script. A different
      // source may well serve the very same songs, so let every track compete
      // again instead of staying out of the plan.
      if (_skippedThisRound.isNotEmpty) {
        debugLog?.record('换源，清空本轮跳过标记', <String, Object?>{
          '数量': _skippedThisRound.length,
          '新源': sourceState.active?.name,
        });
      }
      _skippedThisRound.clear();
      _consecutiveSkips = 0;
      _stockTried.clear();
      _armChain = 0;
      // Waiting for stock was a verdict on the old source; give it a fresh
      // attempt now instead of sitting out the rest of the backoff.
      if (_waitingForStock) _nextStockRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
    }
    if (_loading || willPlay || _userPaused) return;
    if (_errorText == null) return;
    final song = _current;
    if (song == null || song.isLocal) return;
    if (!sourceState.hasActiveSource) return;
    unawaited(_loadAndPlay(song, initialPosition: _position, reason: '源就绪后重试'));
  }

  /// iOS freezes every WKWebView shortly after the app is backgrounded or the
  /// screen locks, while the native audio player keeps running. The custom
  /// source now executes in-process, but a script that had to fall back to the
  /// WebView still loses its JavaScript at that moment — so when the user comes
  /// back we recover automatically instead of forcing another tap on play. We
  /// only do this if playback (or a load) was active when we left, so a
  /// deliberate pause is never hijacked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _appInForeground = false;
        debugLog?.record('进入后台 ${state.name}', <String, Object?>{
          '在播': _isPlaying,
          '想要声音': _shouldPlay,
          '在加载': _loading,
          '歌曲': _current?.name,
        });
        if (_shouldPlay || _isPlaying || _loading) _resumeOnForeground = true;
        if (_shouldPlay) {
          // WebKit reclaims the shared audio session once the app is behind the
          // lock screen, which leaves the player running but mute. Start the
          // stretch clock the watchdog uses to decide on a preventive re-arm.
          _backgroundSince = DateTime.now();
          _silentHeals = 0;
          _proactiveHealDone = false;
          _sessionConfirmedActive = false;
        }
        // Persist immediately: iOS may kill a suspended app at any time.
        if (_current != null) _saveProgress();
        // Best effort — resolve upcoming URLs before the WebView freezes.
        unawaited(_preloadNext());
        break;
      case AppLifecycleState.resumed:
        _appInForeground = true;
        final song = _current;
        final wasBusy = _resumeOnForeground;
        final awayFor = _backgroundSince == null
            ? Duration.zero
            : DateTime.now().difference(_backgroundSince!);
        _backgroundSince = null;
        _resumeOnForeground = false;
        if (song == null) break;
        // Recover unless the user paused on purpose. Waiting on a link that the
        // frozen WebView could not fetch, an error left behind by a background
        // advance, and "playing" that produces no sound all have to be healed
        // without another tap on play; the restored "tap to continue" state with
        // nothing loaded must stay untouched.
        if (_userPaused && !_resumeAfterInterruption) break;
        final processing = service.player.processingState;
        if (!wasBusy &&
            !willPlay &&
            !_loading &&
            _errorText == null &&
            processing == ProcessingState.idle) {
          break;
        }
        debugLog?.record('回前台自动恢复', <String, Object?>{
          '歌曲': song.name,
          '离开时在用': wasBusy,
          '在加载': _loading,
          '在播': _isPlaying,
          '想要声音': _shouldPlay,
          '原生状态': '$processing',
          '位置': '${_position.inSeconds}s',
          '离开时长': '${awayFor.inSeconds}s',
        });
        if (_lyrics.isEmpty) unawaited(_loadLyrics(song));
        unawaited(_resumeAfterForeground(song, awayFor: awayFor));
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _resumeAfterForeground(Song song, {Duration awayFor = Duration.zero}) async {
    _userPaused = false;
    // Reaching this point means the user did not pause on purpose, so the
    // intended state is "playing". The watchdog needs that intent to cover the
    // resumed stream as well.
    _shouldPlay = true;
    if (_waitingForStock) {
      // The queue had nothing playable when the app went away. JavaScript runs
      // again, so retry the queue itself rather than reloading the one song that
      // failed — that is what the waiting backoff was standing in for.
      _nextStockRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
      unawaited(_retryStock());
      return;
    }
    final owned = await _activateSession(reason: '回前台');
    if (_disposed) return;

    // A load started while we were suspended is stuck waiting for the frozen
    // WebView. Cancel it and restart now that JavaScript runs again.
    if (_loading) {
      _playToken++;
      // Only a load that already reached the native player has a meaningful
      // position; one still waiting for a link starts from the beginning.
      await _loadAndPlay(
        song,
        initialPosition: _handedOff ? _position : Duration.zero,
        reason: '回前台重启加载',
      );
      return;
    }

    final processing = service.player.processingState;
    if (_errorText != null) {
      // The failed load never took ownership of the native player, so its clock
      // still belongs to the previous track — restart this song from zero.
      await _loadAndPlay(song, initialPosition: Duration.zero, reason: '回前台重载');
      return;
    }
    if (processing == ProcessingState.idle) {
      await _loadAndPlay(song, initialPosition: _position, reason: '回前台重载');
      return;
    }

    // The track genuinely finished while we were away — continue the queue
    // instead of replaying its final second.
    if (processing == ProcessingState.completed) {
      await _handleCompleted();
      return;
    }

    if (!_isPlaying || !owned) {
      // Either the player really stopped, or the session would not become ours
      // again — in both cases "keep going" cannot be trusted and the item has to
      // be re-armed rather than merely resumed.
      await _healSilence();
      return;
    }

    // The player *claims* to be playing, and after a lock screen that claim is
    // worthless: with the shared audio session reclaimed by the source sandbox's
    // WKWebView the native clock keeps advancing while nothing is audible — the
    // state the user used to clear by pausing and playing again. Re-arm it
    // ourselves once the app has genuinely been away.
    if (awayFor >= const Duration(seconds: 3) && _silentHeals < _maxSilentHeals) {
      _silentHeals++;
      debugLog?.record('回前台重挂音频 ${song.name}', <String, Object?>{
        '离开时长': '${awayFor.inSeconds}s',
        '位置': '${_position.inSeconds}s',
        '原生状态': '$processing',
        '会话已接管': owned,
        '已重挂次数': _silentHeals,
      });
      await _healSilence();
    }
  }

  Future<void> reloadLyrics() async {
    final song = _current;
    if (song != null) await _loadLyrics(song);
  }

  Future<void> setPlayMode(PlayMode mode) async {
    if (appState.settings.playMode != mode) {
      _invalidatePlan();
      // The prepared "next" belongs to the old mode's order.
      _invalidatePreload();
    }
    appState.settings.playMode = mode;
    await appState.repository.save();
    _notify();
  }

  Future<void> setVolume(double value) async {
    appState.settings.volume = value;
    await service.setVolume(value);
    _scheduleSettingsSave();
    _notify();
  }

  Future<void> setSpeed(double value) async {
    appState.settings.speed = value;
    await service.setSpeed(value);
    _scheduleSettingsSave();
    _notify();
  }

  void _scheduleSettingsSave() {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(appState.repository.save());
    });
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (duration == null) {
      _sleepEndsAt = null;
      _notify();
      return;
    }
    _sleepEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      unawaited(pause());
      _sleepEndsAt = null;
      _sleepTimer = null;
      _statusText = '定时停止已生效';
      _notify();
    });
    _notify();
  }

  Future<void> jumpToQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await playSong(_queue[index], queue: _queue, index: index);
  }

  Future<void> removeFromQueue(Song song) async {
    final index = _queue.indexWhere((item) => item.id == song.id && item.source == song.source);
    if (index < 0) return;
    _queue.removeAt(index);
    // Removing an entry shifts every later index, so the pre-computed order no
    // longer refers to the right songs.
    _invalidatePlan();
    _invalidatePreload();
    if (_queue.isEmpty) {
      _shouldPlay = false;
      await service.stop();
      _current = null;
      _index = -1;
      _lyrics = const <LyricLine>[];
      _notify();
      return;
    }
    if (index < _index) {
      _index--;
    } else if (index == _index) {
      _index = min(_index, _queue.length - 1);
      await playSong(_queue[_index], queue: _queue, index: _index, reason: '移出当前曲');
      return;
    }
    _notify();
  }

  void shuffleQueue() {
    if (_queue.length <= 1) return;
    final currentSong = _current;
    final shuffled = List<Song>.from(_queue)..shuffle(Random());
    if (currentSong != null) {
      shuffled.removeWhere((item) => item.id == currentSong.id && item.source == currentSong.source);
      shuffled.insert(0, currentSong);
    }
    _queue = shuffled;
    _index = 0;
    _invalidatePlan();
    _invalidatePreload();
    _notify();
  }

  Future<void> clearQueue() async {
    _playToken++;
    _shouldPlay = false;
    _invalidatePlan();
    _invalidatePreload();
    _queue = <Song>[];
    _index = -1;
    _current = null;
    _lyrics = const <LyricLine>[];
    _position = Duration.zero;
    _duration = Duration.zero;
    _statusText = null;
    _errorText = null;
    _urlCache.clear();
    appState.settings.lastQueueJson = null;
    appState.settings.lastQueueIndex = 0;
    appState.settings.lastSongJson = null;
    appState.settings.lastPositionMs = 0;
    unawaited(appState.repository.save());
    await service.stop();
    _notify();
  }

  void _saveProgress() {
    if (!appState.settings.saveProgress || _current == null) return;
    appState.settings.lastSongJson = _current!.toJson();
    appState.settings.lastPositionMs = _position.inMilliseconds;
    _persistQueue();
    unawaited(appState.repository.save());
  }

  /// Persist the whole queue (windowed to 300 around the current track) so an
  /// app restart restores the playlist instead of a single repeating song.
  void _persistQueue() {
    if (_queue.isEmpty || _index < 0) return;
    const cap = 300;
    var queue = _queue;
    var index = _index;
    if (queue.length > cap) {
      final start = max(0, min(index - 50, queue.length - cap));
      queue = queue.sublist(start, start + cap);
      index = index - start;
    }
    appState.settings.lastQueueJson =
        queue.map((song) => song.toJson()).toList();
    appState.settings.lastQueueIndex = index.clamp(0, queue.length - 1);
  }

  @override
  void dispose() {
    _disposed = true;
    _sleepTimer?.cancel();
    _settingsSaveTimer?.cancel();
    _progressTimer.cancel();
    _watchdogTimer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    sourceState.removeListener(_onSourceChanged);
    unawaited(_interruptionSubscription?.cancel() ?? Future<void>.value());
    unawaited(_noisySubscription?.cancel() ?? Future<void>.value());
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    service.onSkipNext = null;
    service.onSkipPrevious = null;
    service.onPlayRequest = null;
    service.onPauseRequest = null;
    service.onSeekRequest = null;
    service.onStopRequest = null;
    service.onCompleted = null;
    service.onPromoted = null;
    service.onPreloadFailed = null;
    service.onExternalPause = null;
    service.onPlayError = null;
    super.dispose();
  }
}

class _CachedUrl {
  const _CachedUrl({
    required this.url,
    required this.expiresAt,
    this.type = 'mp3',
  });

  final String url;
  final DateTime expiresAt;

  /// The container the source handed out with the link, kept so the runway cache
  /// can name its file the way the player expects.
  final String type;
}
