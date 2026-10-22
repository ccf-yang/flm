import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';

class FlmAudioHandler extends BaseAudioHandler {
  FlmAudioHandler(this._service);

  final FlmPlayerService _service;

  @override
  Future<void> play() {
    // Resuming from the lock screen / control centre has to run through the
    // controller: the player no longer activates the audio session itself, so a
    // bare `AudioPlayer.play()` would restart a track that stays silent.
    final callback = _service.onPlayRequest;
    if (callback != null) return callback();
    return _service.play();
  }

  @override
  Future<void> pause() async {
    // A pause coming from the lock screen / control centre is deliberate; it
    // must cancel any automatic resume-on-foreground.
    _service.onExternalPause?.call();
    final callback = _service.onPauseRequest;
    if (callback != null) {
      await callback();
      return;
    }
    await _service.pause();
  }

  @override
  Future<void> stop() async {
    // Tell the controller before the player is torn down, otherwise its play
    // intent stays set and the watchdog would resurrect playback.
    _service.onStopRequest?.call();
    await _service.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) {
    // Route through the controller so the watchdog's position samples are
    // re-anchored; a backwards seek would otherwise look like a stalled clock.
    final callback = _service.onSeekRequest;
    if (callback != null) return callback(position);
    return _service.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    final callback = _service.onSkipNext;
    if (callback != null) await callback();
  }

  @override
  Future<void> skipToPrevious() async {
    final callback = _service.onSkipPrevious;
    if (callback != null) await callback();
  }

  @override
  Future<void> fastForward() async {
    // Many car head units map their steering-wheel "next" button to the
    // fast-forward/seek-forward AVRCP command rather than to skipToNext. The
    // app never exposes a fast-forward control (only previous/play/next), so
    // treating seek-forward as "next track" is what the driver expects.
    final callback = _service.onSkipNext;
    if (callback != null) await callback();
  }

  @override
  Future<void> rewind() async {
    final callback = _service.onSkipPrevious;
    if (callback != null) await callback();
  }
}

/// Owns two [AudioPlayer] instances: the *active* one produces sound and the
/// *standby* one has the next track fully loaded.
///
/// The source sandbox is a WKWebView whose JavaScript freezes the moment the
/// screen locks. A design that resolves a link and calls `setUrl` when the
/// current track ends therefore stops producing audio at exactly the moment iOS
/// starts suspending the app — the next track either never starts or starts
/// muted, which is the "screen locked, it says it is playing, no sound" bug.
///
/// With two players the boundary is a swap: the standby is already loaded, so
/// the end of a track never needs JavaScript, the network or the Dart isolate
/// to *start* audio. That keeps the audio pipeline running continuously, which
/// is also what stops iOS from suspending the app behind the lock screen.
class FlmPlayerService {
  FlmPlayerService() {
    _handler = FlmAudioHandler(this);
    _bind(_active);
  }

  AudioPlayer _active = AudioPlayer(handleAudioSessionActivation: false);
  AudioPlayer _standby = AudioPlayer(handleAudioSessionActivation: false);

  late final FlmAudioHandler _handler;
  final List<StreamSubscription<dynamic>> _bound = <StreamSubscription<dynamic>>[];
  final StreamController<Duration> _positionCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationCtrl =
      StreamController<Duration?>.broadcast();
  final StreamController<PlayerState> _stateCtrl =
      StreamController<PlayerState>.broadcast();

  Duration _duration = Duration.zero;
  String? _standbyKey;
  bool _standbyReady = false;
  bool _preloadBusy = false;
  bool _switching = false;
  bool _disposed = false;
  int _preloadGeneration = 0;
  String? _pendingPreloadKey;
  Future<void> Function(AudioPlayer player)? _pendingPreloadLoad;

  Future<void> Function()? onSkipNext;
  Future<void> Function()? onSkipPrevious;

  /// Called when the active track finished and there is **no** prepared
  /// standby item; the controller has to resolve and load the next track.
  Future<void> Function()? onCompleted;

  /// Called when the standby item was promoted and is already playing. The
  /// controller must only mirror its own state here — not reload anything.
  void Function()? onPromoted;

  /// Called when the standby player **refused** a preload (expired link, body
  /// that is not audio). The promotion never happened, so nothing else would
  /// ever tell the controller that its planned next track cannot start.
  void Function(String key, String error)? onPreloadFailed;

  /// System (lock screen / control centre) commands routed through the
  /// controller so they share the same state machine as the in-app buttons.
  Future<void> Function()? onPlayRequest;
  Future<void> Function()? onPauseRequest;
  Future<void> Function(Duration position)? onSeekRequest;
  void Function()? onStopRequest;

  void Function()? onExternalPause;
  void Function(String error)? onPlayError;

  AudioPlayer get player => _active;
  FlmAudioHandler get handler => _handler;
  Duration get duration => _duration;

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration?> get durationStream => _durationCtrl.stream;
  Stream<PlayerState> get playerStateStream => _stateCtrl.stream;

  /// True when a fully loaded next item is sitting in the standby player.
  bool get hasPreparedNext => _standbyReady && _standbyKey != null;

  /// True when [key] (a URL or a file path) is the item prepared in standby.
  bool hasPrepared(String key) => _standbyReady && _standbyKey == key;

  void _bind(AudioPlayer player) {
    _bound.add(
      player.positionStream.listen(
        (position) {
          if (!_disposed && player == _active) _positionCtrl.add(position);
        },
        onError: (_, __) {},
      ),
    );
    _bound.add(
      player.durationStream.listen(
        (duration) {
          if (_disposed || player != _active) return;
          _duration = duration ?? Duration.zero;
          _durationCtrl.add(duration);
          _broadcastState();
        },
        onError: (_, __) {},
      ),
    );
    _bound.add(
      player.playbackEventStream.listen(
        (_) {
          if (!_disposed && player == _active) _broadcastState();
        },
        onError: (_, __) {},
      ),
    );
    _bound.add(
      player.playerStateStream.listen(
        (state) => _onPlayerState(player, state),
        onError: (_, __) {},
      ),
    );
  }

  void _rebind() {
    for (final subscription in _bound) {
      unawaited(subscription.cancel());
    }
    _bound.clear();
    _bind(_active);
  }

  void _onPlayerState(AudioPlayer player, PlayerState state) {
    // Events from a player that has just been swapped out must not drive the
    // new active player's state or trigger another promotion.
    if (_disposed || player != _active) return;
    _stateCtrl.add(state);
    _broadcastState();
    if (state.processingState == ProcessingState.completed) {
      unawaited(_handleActiveCompleted());
    }
  }

  Future<void> _handleActiveCompleted() async {
    if (_disposed || _switching) return;
    if (!hasPreparedNext) {
      final callback = onCompleted;
      if (callback != null) unawaited(callback());
      return;
    }
    _switching = true;
    try {
      final old = _active;
      final next = _standby;
      _active = next;
      _standby = old;
      _standbyKey = null;
      _standbyReady = false;
      // The player that *held* this item is now the active one, and the player
      // that became the standby has just finished. A preload still awaiting
      // `setUrl` on the old standby must not arm it: its generation is dead, so
      // a later boundary can never promote an already-consumed item.
      _preloadGeneration++;
      _duration = next.duration ?? Duration.zero;
      _rebind();
      _broadcastState();
      // The old item already reached its end; pausing is effectively a no-op
      // but keeps the two players in a predictable state. Starting the standby
      // immediately is what keeps the audio alive through the boundary.
      unawaited(old.pause());
      _startPlayer(next);
      _broadcastState();
      onPromoted?.call();
    } finally {
      _switching = false;
    }
  }

  void _broadcastState() {
    if (_disposed) return;
    final processingState = switch (_active.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
    final playing = _active.playing;
    _handler.playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{MediaAction.seek},
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: processingState,
        playing: playing,
        updatePosition: _active.position,
        bufferedPosition: _active.bufferedPosition,
        speed: _active.speed,
      ),
    );
  }

  Future<void> setMediaItem(Song song, {Duration? duration}) async {
    Uri? artUri;
    final coverPath = song.localCoverPath;
    if (coverPath != null && coverPath.isNotEmpty) {
      artUri = Uri.file(coverPath);
    } else if (song.picUrl.isNotEmpty) {
      artUri = Uri.tryParse(song.picUrl);
    }
    _handler.mediaItem.add(
      MediaItem(
        id: song.id,
        title: song.displayTitle,
        artist: song.displaySinger,
        album: song.album,
        artUri: artUri,
        duration: duration ?? _duration,
      ),
    );
  }

  /// Load and play [url] on the active player. If the standby player already
  /// holds this exact link it is promoted instead, so switching to an
  /// already-prepared track does not touch the network at all.
  Future<void> playUrl(String url, {Duration initialPosition = Duration.zero}) async {
    await _playKey(url, initialPosition, (AudioPlayer player) async {
      await player.setUrl(url);
    });
  }

  Future<void> playFile(String path, {Duration initialPosition = Duration.zero}) async {
    await _playKey(path, initialPosition, (AudioPlayer player) async {
      await player.setFilePath(path);
    });
  }

  Future<void> _playKey(
    String key,
    Duration initialPosition,
    Future<void> Function(AudioPlayer player) load,
  ) async {
    if (_standbyReady && _standbyKey == key) {
      final old = _active;
      final next = _standby;
      _active = next;
      _standby = old;
      _standbyKey = null;
      _standbyReady = false;
      _preloadGeneration++;
      _duration = next.duration ?? Duration.zero;
      _rebind();
      await old.pause();
      if (initialPosition > Duration.zero) {
        await next.seek(initialPosition);
      }
      _startPlayer(next);
      _broadcastState();
      return;
    }
    // Any standby item belongs to a different track now; a later boundary must
    // not promote it. The controller preloads the correct next track again
    // after this load succeeds.
    _preloadGeneration++;
    _standbyKey = null;
    _standbyReady = false;
    _pendingPreloadKey = null;
    _pendingPreloadLoad = null;
    unawaited(_standby.stop().catchError((_) {}));
    await load(_active);
    if (initialPosition > Duration.zero) {
      await _active.seek(initialPosition);
    }
    _start();
    _broadcastState();
  }

  /// Load the next track into the standby player while the active one keeps
  /// playing. Best effort: failures are ignored and retried by the controller.
  Future<void> preloadUrl(String url) {
    return _preload(url, (AudioPlayer player) async {
      await player.setUrl(url);
    });
  }

  Future<void> preloadFile(String path) {
    return _preload(path, (AudioPlayer player) async {
      await player.setFilePath(path);
    });
  }

  Future<void> _preload(
    String key,
    Future<void> Function(AudioPlayer player) load,
  ) async {
    if (_disposed) return;
    if (_standbyReady && _standbyKey == key) return;
    // A request for a different track must invalidate the previous standby
    // immediately. Otherwise a transition racing this load could promote the
    // wrong song.
    if (_standbyReady && _standbyKey != key) {
      _standbyReady = false;
      _standbyKey = null;
    }
    if (_preloadBusy) {
      // Remember only the latest request; it will run as soon as the current
      // load finishes. This keeps "the last planned next track wins".
      _pendingPreloadKey = key;
      _pendingPreloadLoad = load;
      return;
    }
    _preloadBusy = true;
    var nextKey = key;
    var nextLoad = load;
    try {
      while (!_disposed) {
        final currentKey = nextKey;
        final currentLoad = nextLoad;
        final generation = ++_preloadGeneration;
        final target = _standby;
        // A swap while this await is running turns the standby into the active
        // player; only the player that is still the standby may be armed.
        final stillStandby = !_disposed && identical(target, _standby);
        try {
          await currentLoad(target);
          if (stillStandby && generation == _preloadGeneration) {
            _standbyKey = currentKey;
            _standbyReady = true;
          }
        } catch (error) {
          if (stillStandby && generation == _preloadGeneration) {
            _standbyKey = null;
            _standbyReady = false;
            // The controller planned this link; only it knows the song has to be
            // dropped from the runway and replaced by a later track.
            onPreloadFailed?.call(currentKey, '$error');
          }
        }
        final queuedKey = _pendingPreloadKey;
        final queuedLoad = _pendingPreloadLoad;
        _pendingPreloadKey = null;
        _pendingPreloadLoad = null;
        if (queuedKey != null && queuedLoad != null && queuedKey != currentKey) {
          nextKey = queuedKey;
          nextLoad = queuedLoad;
          _standbyKey = null;
          _standbyReady = false;
        } else {
          break;
        }
      }
    } finally {
      _preloadBusy = false;
    }
  }

  /// Drop the prepared standby item. Called when the queue, the play mode or
  /// the selected song changes so a stale "next" can never be promoted.
  Future<void> clearPreload() async {
    _preloadGeneration++;
    _standbyKey = null;
    _standbyReady = false;
    _pendingPreloadKey = null;
    _pendingPreloadLoad = null;
    try {
      await _standby.stop();
    } catch (_) {}
  }

  /// `AudioPlayer.play()` only completes when playback *stops* — awaiting it
  /// would hang the caller for the whole track.
  void _start() => _startPlayer(_active);

  void _startPlayer(AudioPlayer player) {
    player.play().catchError((Object error) {
      // A swapped-out player can surface a stale error while the new active
      // item is already playing; only the current one's failures matter.
      if (_disposed || player != _active) return;
      // Failures that only appear once the stream is being read (expired link
      // answering 403, a body that is not audio) arrive here instead of in the
      // awaited load call.
      onPlayError?.call('$error');
    });
  }

  Future<void> play() async => _start();

  Future<void> pause() => _active.pause();

  Future<void> stop() async {
    _preloadGeneration++;
    _standbyKey = null;
    _standbyReady = false;
    _pendingPreloadKey = null;
    _pendingPreloadLoad = null;
    await _active.stop();
    await _active.seek(Duration.zero);
    try {
      await _standby.stop();
    } catch (_) {}
  }

  Future<void> seek(Duration position) => _active.seek(position);

  Future<void> setVolume(double value) async {
    final volume = value.clamp(0.0, 1.0).toDouble();
    await _active.setVolume(volume);
    await _standby.setVolume(volume);
  }

  Future<void> setSpeed(double value) async {
    final speed = value.clamp(0.25, 3.0).toDouble();
    await _active.setSpeed(speed);
    await _standby.setSpeed(speed);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final subscription in _bound) {
      await subscription.cancel();
    }
    _bound.clear();
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _stateCtrl.close();
    await _active.dispose();
    await _standby.dispose();
  }
}
