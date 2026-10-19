import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import '../models/lyric.dart';
import '../models/song.dart';
import '../services/lyric_parser.dart';
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
  }) {
    _subscriptions.add(
      service.positionStream.listen((position) {
        _position = position;
        if (_lyrics.isNotEmpty) {
          final nextLine = LyricParser.activeIndex(_lyrics, position);
          if (nextLine != _activeLine) _activeLine = nextLine;
        }
        if (_duration.inSeconds > 10 &&
            (_duration - position).inSeconds <= 15) {
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
    sourceState.addListener(_onSourceChanged);
    WidgetsBinding.instance.addObserver(this);
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _restoreLastPlayback();
  }

  final FlmPlayerService service;
  final SourceState sourceState;
  final AppState appState;
  final LibraryState libraryState;
  final OnlineEngine onlineEngine;

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

  void _restoreLastPlayback() {
    if (!appState.settings.saveProgress) return;
    final song = appState.settings.lastSong;
    if (song == null) return;
    _queue = <Song>[song];
    _index = 0;
    _current = song;
    _position = Duration(milliseconds: appState.settings.lastPositionMs);
    _statusText = '上次播放 · 点击继续';
    service.setMediaItem(song);
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

    try {
      if (song.isLocal) {
        await service.playFile(song.localPath!, initialPosition: initialPosition);
      } else {
        final url = await _resolveUrl(song);
        await service.playUrl(url, initialPosition: initialPosition);
      }
      if (token != _playToken || _disposed) return;

      _loading = false;
      _statusText = null;
      _errorText = null;
      _isPlaying = true;
      final actualDuration = service.player.duration ?? service.duration;
      await service.setMediaItem(song, duration: actualDuration);
      if (song.interval.trim().isEmpty && actualDuration > Duration.zero) {
        libraryState.updateSongInterval(song, formatDuration(actualDuration));
      }
      appState.settings.lastSongJson = song.toJson();
      appState.settings.lastPositionMs = initialPosition.inMilliseconds;
      unawaited(appState.repository.save());
      unawaited(_loadLyrics(song));
      unawaited(_preloadNext());
      _notify();
    } catch (error) {
      if (token != _playToken || _disposed) return;
      if (allowRetry && !song.isLocal && sourceState.hasActiveSource) {
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
      _errorText = _friendlyError(error);
      _statusText = _errorText;
      _notify();
    }
  }

  String _songKey(Song song) => '${song.source}:${song.id}';

  Future<String> _resolveUrl(Song song) async {
    final key = _songKey(song);
    final activeSourceId = sourceState.active?.id ?? '';
    final cached = _urlCache[key];
    if (cached != null &&
        cached.sourceId == activeSourceId &&
        cached.expiresAt.isAfter(DateTime.now())) {
      return cached.url;
    }
    final resolved = await sourceState.resolveMusicUrlAutoSwitch(song);
    final url = '${resolved['url'] ?? ''}';
    if (url.isEmpty) throw StateError('没有获取到播放链接');
    final servingSourceId = sourceState.active?.id ?? '';
    if (_urlCache.length > 30) _urlCache.clear();
    _urlCache[key] = _CachedUrl(
      url: url,
      sourceId: servingSourceId,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    return url;
  }

  Future<void> _preloadNext() async {
    if (_queue.length < 2 || _current == null || !sourceState.hasActiveSource) return;
    final nextIndex = _nextIndex(auto: true);
    if (nextIndex < 0 || nextIndex >= _queue.length || nextIndex == _index) return;
    final song = _queue[nextIndex];
    if (song.isLocal || appState.isDisliked(song)) return;
    final key = _songKey(song);
    final cacheSourceId = sourceState.active?.id ?? '';
    final cached = _urlCache[key];
    if (cached != null &&
        cached.sourceId == cacheSourceId &&
        cached.expiresAt.isAfter(DateTime.now())) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastPreloadAttempt) < const Duration(seconds: 8)) return;
    _lastPreloadAttempt = now;
    if (!_preloading.add(key)) return;
    try {
      final resolved = await sourceState.resolveMusicUrl(song);
      final url = '${resolved['url'] ?? ''}';
      if (url.isEmpty) return;
      if (_urlCache.length > 30) _urlCache.clear();
      _urlCache[key] = _CachedUrl(
        url: url,
        sourceId: cacheSourceId,
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
    } catch (_) {
      // Preloading is best effort.
    } finally {
      _preloading.remove(key);
    }
  }

  String _friendlyError(Object error) {
    var message = error.toString();
    for (final prefix in <String>['Exception: ', 'StateError: ', 'Bad state: ']) {
      if (message.startsWith(prefix)) message = message.substring(prefix.length);
    }
    return message;
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
    if (_isPlaying) {
      await service.pause();
      return;
    }
    if (service.player.processingState == ProcessingState.idle ||
        service.player.processingState == ProcessingState.completed ||
        _errorText != null) {
      await _loadAndPlay(_current!, initialPosition: _position);
    } else {
      await service.play();
    }
  }

  Future<void> play() async {
    if (_current == null) {
      await togglePlay();
      return;
    }
    if (service.player.processingState == ProcessingState.idle ||
        service.player.processingState == ProcessingState.completed ||
        _errorText != null) {
      await _loadAndPlay(_current!, initialPosition: _position);
    } else {
      await service.play();
    }
  }

  Future<void> pause() => service.pause();

  Future<void> seek(Duration position) async {
    if (_current == null) return;
    _position = position;
    _notify();
    await service.seek(position);
  }

  Future<void> next({bool auto = false}) async {
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
    if (_loading || _isPlaying) return;
    if (_errorText == null) return;
    final song = _current;
    if (song == null || song.isLocal) return;
    if (!sourceState.hasActiveSource) return;
    unawaited(_loadAndPlay(song, initialPosition: _position));
  }

  /// iOS suspends the app shortly after it is backgrounded or the screen locks,
  /// which pauses the audio even though `UIBackgroundModes: audio` is set (most
  /// visibly on a re-signed / free-provisioning build). When the user comes back
  /// we resume automatically instead of forcing another tap on play. We only do
  /// this if audio was actually playing when we left, so a deliberate pause is
  /// never hijacked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_isPlaying && !_loading) _resumeOnForeground = true;
        break;
      case AppLifecycleState.resumed:
        if (!_resumeOnForeground) return;
        _resumeOnForeground = false;
        final song = _current;
        if (song == null || _isPlaying || _loading) return;
        final processing = service.player.processingState;
        if (processing == ProcessingState.idle ||
            processing == ProcessingState.completed) {
          unawaited(_loadAndPlay(song, initialPosition: _position));
        } else {
          unawaited(service.play());
        }
        break;
      case AppLifecycleState.detached:
        break;
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
    _queue = <Song>[];
    _index = -1;
    _current = null;
    _lyrics = const <LyricLine>[];
    _position = Duration.zero;
    _duration = Duration.zero;
    _statusText = null;
    _errorText = null;
    _urlCache.clear();
    await service.stop();
    _notify();
  }

  void _saveProgress() {
    if (!appState.settings.saveProgress || _current == null) return;
    appState.settings.lastSongJson = _current!.toJson();
    appState.settings.lastPositionMs = _position.inMilliseconds;
    unawaited(appState.repository.save());
  }

  @override
  void dispose() {
    _disposed = true;
    _sleepTimer?.cancel();
    _settingsSaveTimer?.cancel();
    _progressTimer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    sourceState.removeListener(_onSourceChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    service.onSkipNext = null;
    service.onSkipPrevious = null;
    service.onCompleted = null;
    super.dispose();
  }
}

class _CachedUrl {
  const _CachedUrl({
    required this.url,
    required this.sourceId,
    required this.expiresAt,
  });

  final String url;
  final String sourceId;
  final DateTime expiresAt;
}
