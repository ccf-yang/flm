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
    this.debugLog,
  }) {
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
    service.onSkipNext = () => next();
    service.onSkipPrevious = () => previous();
    service.onPlayRequest = play;
    service.onCompleted = _handleCompleted;
    service.onPlayError = (message) {
      debugLog?.record('播放器报错 ${_current?.name}', <String, Object?>{
        '错误': message,
        '前台': _appInForeground,
        '在加载': _loading,
      });
      unawaited(_handlePlayerError(message));
    };
    service.onExternalPause = () {
      // A pause from the lock screen / control centre is deliberate: never
      // auto-restart it when the app comes back, not even if an audio
      // interruption was still flagged as resumable.
      _userPaused = true;
      _resumeAfterInterruption = false;
      _resumeOnForeground = false;
    };
    sourceState.addListener(_onSourceChanged);
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
  final Map<String, _CachedUrl> _urlCache = <String, _CachedUrl>{};
  final Set<String> _preloading = <String>{};
  DateTime _lastPreloadAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _settingsSaveTimer;
  bool _resumeOnForeground = false;
  int _autoSkips = 0;
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

  /// A resolve started while backgrounded is waiting on frozen JavaScript, so cap
  /// how long an advance blocks on it. Returning to the foreground restarts the
  /// load once JavaScript runs again.
  static const Duration _backgroundResolveTimeout = Duration(seconds: 12);

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
    if (_disposed || _current == null || !_shouldPlay) return;
    final now = DateTime.now();
    final started = _loadStartedAt;

    // The source sandbox is a frozen WKWebView once the screen locks, so a link
    // that was not resolved before then can never be resolved. Abandon that load
    // rather than sitting on "正在获取播放链接…" — and hand the queue to the first
    // track whose link is already cached, which keeps background playback running.
    if (_loading && !_handedOff && started != null) {
      if (!_appInForeground &&
          now.difference(started) > const Duration(seconds: 20)) {
        _silentHeals = 0;
        debugLog?.record('后台取链停滞，放弃本次加载 ${_current?.name}', <String, Object?>{
          '已等待': '${now.difference(started).inSeconds}s',
          '下一首已缓存链接': _nextPlayableIndex() != null,
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
    if (queue != null) {
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
        _queue = <Song>[song];
        _index = 0;
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
    await _loadAndPlay(song, reason: reason);
  }

  Future<void> _loadAndPlay(
    Song song, {
    Duration initialPosition = Duration.zero,
    bool allowRetry = true,
    String? reason,
  }) async {
    final token = ++_playToken;
    _loading = true;
    _shouldPlay = true;
    _handedOff = false;
    _loadStartedAt = DateTime.now();
    _lastProgressChangeAt = DateTime.now();
    _statusText = '正在获取播放链接…';
    _errorText = null;
    _notify();
    var handedUrl = song.isLocal ? (song.localPath ?? '') : '(未取到)';
    debugLog?.record('播放开始 ${song.name}', <String, Object?>{
      '歌曲': '${song.name} - ${song.singer}',
      '平台': song.source,
      '本地': song.isLocal,
      '前台': _appInForeground,
      '起始位置': '${initialPosition.inSeconds}s',
      if (reason != null) '触发': reason,
    });

    try {
      if (song.isLocal) {
        _handedOff = true;
        await _activateSession(reason: '本地起播');
        await service.playFile(song.localPath!, initialPosition: initialPosition);
      } else {
        final url = await _resolveUrl(song);
        handedUrl = url;
        // A newer play request may have been issued while the URL was being
        // resolved. Starting this stale track now would silently play the
        // wrong song, so drop it.
        if (token != _playToken || _disposed) return;
        _handedOff = true;
        final sessionIsOurs = await _activateSession(reason: '起播前激活');
        if (token != _playToken || _disposed) return;
        await service.playUrl(url, initialPosition: initialPosition);
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
      _autoSkips = 0;
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
      unawaited(_preloadNext());
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
        _urlCache.remove(_songKey(song));
        _statusText = '播放失败，正在重试…';
        _notify();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (token != _playToken || _disposed) return;
        return _loadAndPlay(
          song,
          initialPosition: initialPosition,
          allowRetry: false,
        );
      }
      _loading = false;
      _isPlaying = false;
      _shouldPlay = false;
      // All configured sources failed for this song: keep moving to the next
      // one instead of stalling, until either something plays or the whole
      // queue has failed a full round. Behind the lock screen the source sandbox
      // cannot resolve anything, so only a track whose link is already cached
      // counts as playable there — that is what keeps a background session
      // running instead of dying on the first unresolvable song.
      final advance = _nextPlayableIndex();
      if (advance != null &&
          !_userPaused &&
          !song.isLocal &&
          sourceState.hasActiveSource &&
          _queue.length > 1 &&
          _autoSkips < _queue.length) {
        _autoSkips++;
        _statusText = sourceState.lastPoolError == null
            ? '这首无法播放，正在试下一首…'
            : '无法播放：${sourceState.lastPoolError}';
        debugLog?.record('自动跳歌 → ${_queue[advance].name}', <String, Object?>{
          '失败歌曲': song.name,
          '错误': '$error',
          '失败地址': handedUrl,
          '源侧原因': sourceState.lastPoolError,
          '已跳数': _autoSkips,
          '前台': _appInForeground,
          '下一首已缓存链接': _hasUsableCache(_queue[advance]),
        });
        _notify();
        await playSong(_queue[advance], queue: _queue, index: advance);
        return;
      }
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

  bool _hasUsableCache(Song song) {
    final cached = _urlCache[_songKey(song)];
    return cached != null && cached.expiresAt.isAfter(DateTime.now());
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
  /// nothing can be played right now. Behind the lock screen only a song whose
  /// link is already in hand counts as playable, since the source sandbox cannot
  /// resolve anything while its JavaScript is frozen.
  int? _nextPlayableIndex() {
    final indices = _upcoming(count: 3);
    if (indices.isEmpty) return null;
    if (_appInForeground) return indices.first;
    for (final item in indices) {
      final song = _queue[item];
      if (song.isLocal || _hasUsableCache(song)) return item;
    }
    return null;
  }

  /// Forget the decided order after the queue, the position or the play mode
  /// changed. [_upcoming] repopulates it on the next call.
  void _invalidatePlan() => _nextPlan = <int>[];

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

  void _cacheUrl(String key, String url) {
    _urlCache[key] = _CachedUrl(
      url: url,
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
      // Backgrounded, the sandbox is frozen, so even a nearly-expired link beats
      // a resolve that can never finish. In the foreground, refresh proactively.
      if (!_appInForeground || !_isGoingStale(cached, now)) return cached.url;
    }
    final pending = sourceState.resolveMusicUrlAutoSwitch(song);
    try {
      final resolved = _appInForeground
          ? await pending
          : await pending.timeout(
              _backgroundResolveTimeout,
              onTimeout: () => throw StateError(
                '后台取链超时（音源脚本在锁屏时被系统冻结），回前台后会自动重试',
              ),
            );
      final url = '${resolved['url'] ?? ''}';
      if (url.isEmpty) throw StateError('没有获取到播放链接');
      _cacheUrl(key, url);
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

  /// Pre-fetch links for the tracks the queue will actually reach next. iOS
  /// suspends the WKWebView that runs the source sandbox as soon as the app is
  /// backgrounded, so a URL that has not been resolved *before* the screen locks
  /// can never be fetched until the user returns.
  Future<void> _preloadNext() async {
    if (_current == null || !sourceState.hasActiveSource) return;
    final now = DateTime.now();
    if (now.difference(_lastPreloadAttempt) < const Duration(seconds: 8)) {
      return;
    }

    final candidates = _upcoming(count: 4);
    for (final index in candidates) {
      final song = _queue[index];
      if (song.isLocal) continue;
      final key = _songKey(song);
      final cached = _urlCache[key];
      if (cached != null && cached.expiresAt.isAfter(now) && !_isGoingStale(cached, now)) {
        continue;
      }
      if (!_preloading.add(key)) continue;
      _lastPreloadAttempt = now;
      try {
        final resolved = _appInForeground
            ? await sourceState.resolveMusicUrlAutoSwitch(song)
            : await sourceState
                .resolveMusicUrlAutoSwitch(song)
                .timeout(_backgroundResolveTimeout);
        final url = '${resolved['url'] ?? ''}';
        if (url.isEmpty) continue;
        _cacheUrl(key, url);
        debugLog?.record('预取链接成功 ${song.name}', <String, Object?>{
          '队列位置': index,
          '有效期': '${_urlTtl.inMinutes}分钟',
        });
      } catch (_) {
        // Preloading is best effort.
      } finally {
        _preloading.remove(key);
      }
    }
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
      if (lines.isEmpty && !song.isLocal) {
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
    final processing = service.player.processingState;
    if (processing == ProcessingState.idle ||
        processing == ProcessingState.completed ||
        _errorText != null) {
      // A finished track reports its duration as the current position; start
      // over from zero instead of reloading the final second.
      final start =
          processing == ProcessingState.completed ? Duration.zero : _position;
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

    // Automatic advances follow the pre-computed order, so the track that starts
    // is one whose link may already be in hand; manual taps run in the
    // foreground where a fresh resolve is possible and use the plain order.
    int nextIndex;
    if (auto) {
      final plan = _upcoming(count: 3);
      nextIndex = _nextPlayableIndex() ?? (plan.isEmpty ? -1 : plan.first);
    } else {
      var candidate = _nextIndex(auto: false);
      var attempts = 0;
      while (candidate >= 0 &&
          candidate < _queue.length &&
          attempts < _queue.length &&
          appState.isDisliked(_queue[candidate])) {
        candidate = _indexAfter(candidate, auto: false);
        attempts++;
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
    if (_disposed) return;
    await next(auto: true);
  }

  /// Once a custom source becomes ready, silently retry a song that failed only
  /// because no usable source existed yet (for example the user just imported
  /// one). Gated on [_errorText] so it never steals playback from the restored
  /// "tap to continue" state or from a foreground resume.
  void _onSourceChanged() {
    if (_disposed) return;
    if (_loading || willPlay || _userPaused) return;
    if (_errorText == null) return;
    final song = _current;
    if (song == null || song.isLocal) return;
    if (!sourceState.hasActiveSource) return;
    unawaited(_loadAndPlay(song, initialPosition: _position, reason: '源就绪后重试'));
  }

  /// iOS suspends the app shortly after it is backgrounded or the screen locks.
  /// The source sandbox is a WKWebView, and its JavaScript (and therefore every
  /// URL resolution) freezes at that moment, while the native audio player
  /// keeps running. When the user comes back we recover automatically instead
  /// of forcing another tap on play. We only do this if playback (or a load)
  /// was active when we left, so a deliberate pause is never hijacked.
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
        unawaited(_resumeAfterForeground(song, awayFor: awayFor));
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _resumeAfterForeground(Song song, {Duration awayFor = Duration.zero}) async {
    _userPaused = false;
    final owned = await _activateSession(reason: '回前台');
    if (_disposed) return;

    // A load started while we were suspended is stuck waiting for the frozen
    // WebView. Cancel it and restart now that JavaScript runs again.
    if (_loading) {
      _playToken++;
      await _loadAndPlay(song, initialPosition: _position, reason: '回前台重启加载');
      return;
    }

    final processing = service.player.processingState;
    if (_errorText != null || processing == ProcessingState.idle) {
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
    if (appState.settings.playMode != mode) _invalidatePlan();
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
    _notify();
  }

  Future<void> clearQueue() async {
    _playToken++;
    _autoSkips = 0;
    _shouldPlay = false;
    _invalidatePlan();
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
    service.onCompleted = null;
    service.onExternalPause = null;
    service.onPlayError = null;
    super.dispose();
  }
}

class _CachedUrl {
  const _CachedUrl({
    required this.url,
    required this.expiresAt,
  });

  final String url;
  final DateTime expiresAt;
}
