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
import '../services/url_probe.dart';
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
        _position = position;
        if (_lyrics.isNotEmpty) {
          final nextLine = LyricParser.activeIndex(_lyrics, position);
          if (nextLine != _activeLine) _activeLine = nextLine;
        }
        if (_duration.inSeconds > 10 &&
            (_duration - position).inSeconds <= 45) {
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
        _notify();
      }),
    );
    service.onSkipNext = () => next();
    service.onSkipPrevious = () => previous();
    service.onCompleted = _handleCompleted;
    service.onExternalPause = () {
      _resumeOnForeground = false;
    };
    sourceState.addListener(_onSourceChanged);
    WidgetsBinding.instance.addObserver(this);
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
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
  Timer? _sleepTimer;
  DateTime? _sleepEndsAt;

  List<Song> _queue = <Song>[];
  int _index = -1;
  Song? _current;
  bool _isPlaying = false;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  List<LyricLine> _lyrics = const <LyricLine>[];
  int _activeLine = -1;
  String? _statusText;
  String? _errorText;
  int _playToken = 0;
  bool _disposed = false;
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

  List<Song> get queue => List<Song>.unmodifiable(_queue);
  int get index => _index;
  Song? get current => _current;
  bool get isPlaying => _isPlaying;
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
      _interruptionSubscription = session.interruptionEventStream.listen((event) {
        if (_disposed) return;
        debugLog?.record('音频中断 ${event.begin ? "开始" : "结束"}', <String, Object?>{
          '类型': '${event.type}',
          '当时在播': _isPlaying,
          '当时在加载': _loading,
        });
        if (event.begin) {
          _resumeAfterInterruption = _isPlaying;
          if (_isPlaying) unawaited(service.pause());
          return;
        }
        if (!_resumeAfterInterruption) return;
        _resumeAfterInterruption = false;
        if (event.type == AudioInterruptionType.pause ||
            event.type == AudioInterruptionType.unknown) {
          unawaited(() async {
            await _activateSession();
            if (!_disposed && _current != null && !_isPlaying) {
              await service.play();
            }
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

  Future<void> _activateSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
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

  Future<void> playSong(Song song, {List<Song>? queue, int? index}) async {
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

    _current = song;
    _position = Duration.zero;
    _duration = Duration.zero;
    _lyrics = const <LyricLine>[];
    _activeLine = -1;
    _errorText = null;
    _userPaused = false;
    _statusText = '正在准备播放…';
    _notify();
    await _loadAndPlay(song);
  }

  Future<void> _loadAndPlay(
    Song song, {
    Duration initialPosition = Duration.zero,
    bool allowRetry = true,
  }) async {
    final token = ++_playToken;
    _loading = true;
    _statusText = '正在获取播放链接…';
    _errorText = null;
    _notify();
    var handedUrl = song.isLocal ? (song.localPath ?? '') : '(未取到)';
    debugLog?.record('播放开始 ${song.name}', <String, Object?>{
      '歌曲': '${song.name} - ${song.singer}',
      '平台': song.source,
      '本地': song.isLocal,
      '起始位置': '${initialPosition.inSeconds}s',
    });

    try {
      if (song.isLocal) {
        await service.playFile(song.localPath!, initialPosition: initialPosition);
      } else {
        final url = await _resolveUrl(song);
        handedUrl = url;
        // A newer play request may have been issued while the URL was being
        // resolved. Starting this stale track now would silently play the
        // wrong song, so drop it.
        if (token != _playToken || _disposed) return;
        final probe = await probeAudioUrl(url);
        debugLog?.record('播放前探测 ${song.name}', <String, Object?>{
          '地址': url,
          '状态': probe.networkFailed ? '请求失败' : probe.status,
          '类型': probe.contentType.isEmpty ? '未知' : probe.contentType,
          '长度': probe.length < 0 ? '未知' : probe.length,
          '耗时': '${probe.elapsedMs}ms',
          '错误': probe.error,
        });
        // A probe that fails on DNS/TLS must not veto playback: the player may
        // still reach the stream. Only a definite rejection or an HTML body is
        // treated as a dead link so the pool can move to the next source.
        if (probe.rejected) {
          throw StateError('播放地址被拒绝（HTTP ${probe.status}）');
        }
        if (probe.notAudio) {
          throw StateError('播放地址返回的是网页而不是音频（${probe.contentType}）');
        }
        if (token != _playToken || _disposed) return;
        await service.playUrl(url, initialPosition: initialPosition);
      }
      if (token != _playToken || _disposed) return;

      _loading = false;
      _statusText = null;
      _errorText = null;
      _isPlaying = true;
      _autoSkips = 0;
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
          '堆栈': '$stack',
        });
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
      // All configured sources failed for this song: keep moving to the next
      // one instead of stalling, until either something plays or the whole
      // queue has failed a full round.
      if (_appInForeground &&
          !_userPaused &&
          !song.isLocal &&
          sourceState.hasActiveSource &&
          _queue.length > 1 &&
          _autoSkips < _queue.length) {
        _autoSkips++;
        final nextIdx = (_index + 1) % _queue.length;
        _statusText = sourceState.lastPoolError == null
            ? '这首无法播放，正在试下一首…'
            : '无法播放：${sourceState.lastPoolError}';
        debugLog?.record('自动跳歌 → ${_queue[nextIdx].name}', <String, Object?>{
          '失败歌曲': song.name,
          '错误': '$error',
          '失败地址': handedUrl,
          '源侧原因': sourceState.lastPoolError,
          '已跳数': _autoSkips,
        });
        _notify();
        await playSong(_queue[nextIdx], queue: _queue, index: nextIdx);
        return;
      }
      _errorText = _friendlyError(error);
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

  Future<String> _resolveUrl(Song song) async {
    final key = _songKey(song);
    final cached = _urlCache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.url;
    }
    final resolved = await sourceState.resolveMusicUrlAutoSwitch(song);
    final url = '${resolved['url'] ?? ''}';
    if (url.isEmpty) throw StateError('没有获取到播放链接');
    if (_urlCache.length > 30) _urlCache.clear();
    _urlCache[key] = _CachedUrl(
      url: url,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    return url;
  }

  /// Resolve the next two tracks ahead of time. iOS suspends the WKWebView that
  /// runs the source sandbox as soon as the app is backgrounded, so a URL that
  /// has not been resolved *before* the screen locks can never be fetched until
  /// the user returns. Preloading gives background playback a ready URL.
  Future<void> _preloadNext() async {
    if (_queue.length < 2 || _current == null || !sourceState.hasActiveSource) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastPreloadAttempt) < const Duration(seconds: 8)) {
      return;
    }

    final first = _nextIndex(auto: true);
    final second = first >= 0 ? _indexAfter(first, auto: true) : -1;
    final candidates = <int>{
      if (first >= 0) first,
      if (second >= 0) second,
    };

    for (final index in candidates) {
      if (index < 0 || index >= _queue.length || index == _index) continue;
      final song = _queue[index];
      if (song.isLocal || appState.isDisliked(song)) continue;
      final key = _songKey(song);
      final cached = _urlCache[key];
      if (cached != null && cached.expiresAt.isAfter(now)) continue;
      if (!_preloading.add(key)) continue;
      _lastPreloadAttempt = now;
      try {
        final resolved = await sourceState.resolveMusicUrlAutoSwitch(song);
        final url = '${resolved['url'] ?? ''}';
        if (url.isEmpty) continue;
        if (_urlCache.length > 30) _urlCache.clear();
        _urlCache[key] = _CachedUrl(
          url: url,
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        );
      } catch (_) {
        // Preloading is best effort.
      } finally {
        _preloading.remove(key);
      }
    }
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
        await playSong(_queue.first, queue: _queue, index: 0);
      }
      return;
    }
    // Pressing the button while the auto-skip chain is probing unreachable
    // sources stops the chain outright: the stale attempt is dropped by its
    // token and nothing advances until the user presses play again.
    if (_loading) {
      _playToken++;
      _loading = false;
      _isPlaying = false;
      _userPaused = true;
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
    if (_isPlaying) {
      _userPaused = true;
      await service.pause();
      return;
    }
    _userPaused = false;
    final processing = service.player.processingState;
    if (processing == ProcessingState.idle ||
        processing == ProcessingState.completed ||
        _errorText != null) {
      // A finished track reports its duration as the current position; start
      // over from zero instead of reloading the final second.
      final start =
          processing == ProcessingState.completed ? Duration.zero : _position;
      await _loadAndPlay(_current!, initialPosition: start);
    } else {
      await service.play();
    }
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
      final start =
          processing == ProcessingState.completed ? Duration.zero : _position;
      await _loadAndPlay(_current!, initialPosition: start);
    } else {
      await service.play();
    }
  }

  Future<void> pause() async {
    _playToken++;
    _loading = false;
    _userPaused = true;
    await service.pause();
    _notify();
  }

  Future<void> seek(Duration position) async {
    if (_current == null) return;
    _position = position;
    _notify();
    await service.seek(position);
  }

  Future<void> next({bool auto = false}) async {
    _userPaused = false;
    if (_queue.isEmpty) return;
    if (_current == null) {
      await playSong(_queue.first, queue: _queue, index: 0);
      return;
    }
    if (auto && playMode == PlayMode.singleLoop) {
      await _loadAndPlay(_current!);
      return;
    }
    if (playMode == PlayMode.sequence && _index >= _queue.length - 1) {
      _isPlaying = false;
      _statusText = '播放完毕';
      await service.pause();
      _notify();
      return;
    }

    var nextIndex = _nextIndex(auto: auto);
    var attempts = 0;
    while (nextIndex >= 0 &&
        attempts < _queue.length &&
        appState.isDisliked(_queue[nextIndex])) {
      nextIndex = _indexAfter(nextIndex, auto: auto);
      attempts++;
    }
    if (nextIndex < 0) {
      _statusText = '播放完毕';
      await service.pause();
      _notify();
      return;
    }
    await playSong(_queue[nextIndex], queue: _queue, index: nextIndex);
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
    await playSong(_queue[previousIndex], queue: _queue, index: previousIndex);
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
    if (_loading || _isPlaying || _userPaused) return;
    if (_errorText == null) return;
    final song = _current;
    if (song == null || song.isLocal) return;
    if (!sourceState.hasActiveSource) return;
    unawaited(_loadAndPlay(song, initialPosition: _position));
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
          '在加载': _loading,
          '歌曲': _current?.name,
        });
        if (_isPlaying || _loading) _resumeOnForeground = true;
        // Persist immediately: iOS may kill a suspended app at any time.
        if (_current != null) _saveProgress();
        // Best effort — resolve upcoming URLs before the WebView freezes.
        unawaited(_preloadNext());
        break;
      case AppLifecycleState.resumed:
        _appInForeground = true;
        if (!_resumeOnForeground) return;
        _resumeOnForeground = false;
        final song = _current;
        if (song == null) return;
        debugLog?.record('回前台自动恢复', <String, Object?>{
          '歌曲': song.name,
          '在加载': _loading,
          '在播': _isPlaying,
          '位置': '${_position.inSeconds}s',
        });
        unawaited(_resumeAfterForeground(song));
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _resumeAfterForeground(Song song) async {
    _userPaused = false;
    await _activateSession();
    if (_disposed) return;

    // A load started while we were suspended is stuck waiting for the frozen
    // WebView. Cancel it and restart now that JavaScript runs again.
    if (_loading) {
      _playToken++;
      await _loadAndPlay(song, initialPosition: _position);
      return;
    }

    final processing = service.player.processingState;
    if (_errorText != null || processing == ProcessingState.idle) {
      await _loadAndPlay(song, initialPosition: _position);
      return;
    }

    // The track genuinely finished while we were away — continue the queue
    // instead of replaying its final second.
    if (processing == ProcessingState.completed) {
      await _handleCompleted();
      return;
    }

    if (!_isPlaying) {
      await service.play();
      return;
    }

    // The player *claims* to be playing, but after a lock/suspend the audio
    // session may be inert — `playing` is true while the position never moves
    // and no sound comes out (most visible when the next track started in the
    // background). Sample the native position twice: a live player advances.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_disposed) return;
    final first = service.player.position;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (_disposed) return;
    final second = service.player.position;
    if (service.player.playing &&
        !_loading &&
        second <= first &&
        service.player.processingState == ProcessingState.ready) {
      await service.pause();
      await _activateSession();
      await service.play();
    }
  }

  Future<void> reloadLyrics() async {
    final song = _current;
    if (song != null) await _loadLyrics(song);
  }

  Future<void> setPlayMode(PlayMode mode) async {
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
    if (_queue.isEmpty) {
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
      await playSong(_queue[_index], queue: _queue, index: _index);
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
    _notify();
  }

  Future<void> clearQueue() async {
    _playToken++;
    _autoSkips = 0;
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
    WidgetsBinding.instance.removeObserver(this);
    sourceState.removeListener(_onSourceChanged);
    unawaited(_interruptionSubscription?.cancel() ?? Future<void>.value());
    unawaited(_noisySubscription?.cancel() ?? Future<void>.value());
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    service.onSkipNext = null;
    service.onSkipPrevious = null;
    service.onCompleted = null;
    service.onExternalPause = null;
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
