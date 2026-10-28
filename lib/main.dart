import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'data/custom_source_repository.dart';
import 'data/library_repository.dart';
import 'data/settings_repository.dart';
import 'services/backup_service.dart';
import 'services/debug_log.dart';
import 'services/download_service.dart';
import 'services/http_bridge.dart';
import 'services/local_music_service.dart';
import 'services/online_engine.dart';
import 'services/player_service.dart';
import 'services/runway_cache.dart';
import 'state/app_state.dart';
import 'state/discover_state.dart';
import 'state/library_state.dart';
import 'state/player_state.dart';
import 'state/search_state.dart';
import 'state/source_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settingsRepository = await SettingsRepository.load();
  final libraryRepository = await LibraryRepository.load();
  final customSourceRepository = await CustomSourceRepository.load();

  final httpBridge = HttpBridge();

  final playerService = FlmPlayerService();
  await AudioService.init(
    builder: () => playerService.handler,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.flm.music.channel.audio',
      androidNotificationChannelName: 'flm playback',
      // Keep the foreground service — and the wake lock that comes with it — up
      // through *every* pause. audio_service leaves the foreground state and
      // releases the wake lock each time `playing` falls to false, which on
      // Android happens at track boundaries without a prepared standby, during
      // the silence watchdog's re-arm, and while a notification briefly steals
      // audio focus. Even a momentary demotion lets the OEM freezer kill the
      // process, and that is what users experience as background playback
      // cutting out.
      //
      // `androidNotificationOngoing` is deliberately left at its default: the
      // plugin asserts that the two options cannot be combined, and it has
      // nothing to do here — a notification from a service that stays in the
      // foreground state is already non-dismissible.
      //
      // Necessary, not sufficient. One logged session on a HyperOS phone still
      // lost five and a half minutes of watchdog ticks once the queue had *no*
      // audio to output, and the two retries that followed landed inside the
      // same second — the picture of a suspended process catching up, which also
      // explains why headset presses during that window produced nothing at all.
      // The ROM spares an app that is making sound, not a service that is only
      // trying to get some, so the queue has to stay playable instead of relying
      // on a backoff timer to wake it.
      androidStopForegroundOnPause: false,
    ),
  );

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await session.setActive(true);
  } catch (_) {}

  final appState = AppState(settingsRepository);
  // One-shot: the shipped batch-detection defaults became 8s per source and 8
  // sources at a time. A device that already stored the old numbers keeps them
  // forever unless this passes through once; anything tuned afterwards is kept.
  if (!appState.settings.probeTuningV2Applied) {
    appState.settings
      ..probeTimeoutSeconds = 8
      ..probeConcurrency = 8
      ..probeTuningV2Applied = true;
    unawaited(appState.repository.save());
  }
  final debugLog = DebugLog(enabled: appState.settings.debugEnabled);
  // Opens the log file and pulls back the tail of the previous run: the point of
  // the trace is a stall that happened while nobody was looking, so it has to
  // survive a crash and a relaunch.
  unawaited(debugLog.warmUp());
  httpBridge.debugLog = debugLog;
  final onlineEngine = OnlineEngine(httpBridge)..debugLog = debugLog;
  // Hidden cache of the next few tracks' whole files, so a track boundary is a
  // local file open instead of a bet that one remote link still answers.
  final runwayCache = RunwayCache(debugLog: debugLog);
  unawaited(runwayCache.warmUp());
  final sourceState = SourceState(
    repository: customSourceRepository,
    http: httpBridge,
    appState: appState,
    debugLog: debugLog,
    onlineEngine: onlineEngine,
  );
  final libraryState = LibraryState(
    repository: libraryRepository,
    localMusic: LocalMusicService(),
  );
  final playerController = PlayerController(
    service: playerService,
    sourceState: sourceState,
    appState: appState,
    libraryState: libraryState,
    onlineEngine: onlineEngine,
    runway: runwayCache,
    debugLog: debugLog,
  );
  final searchState = SearchState(engine: onlineEngine, appState: appState);
  final discoverState = DiscoverState(engine: onlineEngine, appState: appState);
  final downloadService = DownloadService(
    sourceState: sourceState,
    libraryState: libraryState,
  );
  libraryState.onSongLoved = (song) => unawaited(downloadService.downloadToLibrary(song));
  final backupService = BackupService(
    libraryRepository: libraryRepository,
    libraryState: libraryState,
    sourceRepository: customSourceRepository,
    sourceState: sourceState,
    settingsRepository: settingsRepository,
    appState: appState,
    playerService: playerService,
  );

  await playerService.setVolume(appState.settings.volume);
  await playerService.setSpeed(appState.settings.speed);
  final initialSong = appState.settings.lastSong ?? playerController.current;
  if (initialSong != null) {
    unawaited(playerService.setMediaItem(initialSong));
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<SourceState>.value(value: sourceState),
        ChangeNotifierProvider<LibraryState>.value(value: libraryState),
        ChangeNotifierProvider<PlayerController>.value(value: playerController),
        ChangeNotifierProvider<SearchState>.value(value: searchState),
        ChangeNotifierProvider<DiscoverState>.value(value: discoverState),
        Provider<OnlineEngine>.value(value: onlineEngine),
        Provider<RunwayCache>.value(value: runwayCache),
        Provider<FlmPlayerService>.value(value: playerService),
        Provider<BackupService>.value(value: backupService),
        ChangeNotifierProvider<DebugLog>.value(value: debugLog),
      ],
      child: const FlmApp(),
    ),
  );

  // 开机自动后台检查源: armed after the UI is up, so the queue keeps playing from
  // the sources already installed while a possibly minutes-long pass fetches,
  // measures and prunes beside it.
  sourceState.maybeScheduleAutoRefresh();
}
