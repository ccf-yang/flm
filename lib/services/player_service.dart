import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';

class FlmAudioHandler extends BaseAudioHandler {
  FlmAudioHandler(this._service);

  final FlmPlayerService _service;

  @override
  Future<void> play() => _service.play();

  @override
  Future<void> pause() {
    // A pause coming from the lock screen / control centre is deliberate; it
    // must cancel any automatic resume-on-foreground.
    _service.onExternalPause?.call();
    return _service.pause();
  }

  @override
  Future<void> stop() async {
    await _service.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _service.seek(position);

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
}

class FlmPlayerService {
  FlmPlayerService() {
    _handler = FlmAudioHandler(this);
    _subscriptions.add(
      _player.playbackEventStream.listen(
        (_) => _broadcastState(),
        onError: (_, __) {},
      ),
    );
    _subscriptions.add(
      _player.playerStateStream.listen(
        (state) {
          _broadcastState();
          if (state.processingState == ProcessingState.completed) {
            final callback = onCompleted;
            if (callback != null) unawaited(callback());
          }
        },
        onError: (_, __) {},
      ),
    );
    _subscriptions.add(
      _player.durationStream.listen(
        (duration) {
          _duration = duration ?? Duration.zero;
          _broadcastState();
        },
        onError: (_, __) {},
      ),
    );
  }

  final AudioPlayer _player = AudioPlayer();
  late final FlmAudioHandler _handler;
  final List<StreamSubscription<dynamic>> _subscriptions = <StreamSubscription<dynamic>>[];
  Duration _duration = Duration.zero;

  Future<void> Function()? onSkipNext;
  Future<void> Function()? onSkipPrevious;
  Future<void> Function()? onCompleted;
  void Function()? onExternalPause;

  AudioPlayer get player => _player;
  FlmAudioHandler get handler => _handler;
  Duration get duration => _duration;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  void _broadcastState() {
    final processingState = switch (_player.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
    final playing = _player.playing;
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
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
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

  Future<void> playUrl(String url, {Duration initialPosition = Duration.zero}) async {
    await _player.setUrl(url);
    if (initialPosition > Duration.zero) {
      await _player.seek(initialPosition);
    }
    await _player.play();
  }

  Future<void> playFile(String path, {Duration initialPosition = Duration.zero}) async {
    await _player.setFilePath(path);
    if (initialPosition > Duration.zero) {
      await _player.seek(initialPosition);
    }
    await _player.play();
  }

  Future<void> play() => _player.play();

  Future<void> pause() => _player.pause();

  Future<void> stop() async {
    await _player.stop();
    await _player.seek(Duration.zero);
  }

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> setVolume(double value) => _player.setVolume(value.clamp(0.0, 1.0).toDouble());

  Future<void> setSpeed(double value) => _player.setSpeed(value.clamp(0.25, 3.0).toDouble());

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
  }
}
