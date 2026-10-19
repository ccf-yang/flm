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
  final onlineEngine = OnlineEngine(httpBridge);

  final playerService = FlmPlayerService();
  await AudioService.init(
    builder: () => playerService.handler,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.flm.music.channel.audio',
      androidNotificationChannelName: 'flm playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await session.setActive(true);
  } catch (_) {}

  final appState = AppState(settingsRepository);
  final debugLog = DebugLog(enabled: appState.settings.debugEnabled);
  httpBridge.debugLog = debugLog;
  final sourceState = SourceState(
    repository: customSourceRepository,
    http: httpBridge,
    appState: appState,
    debugLog: debugLog,
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
        Provider<FlmPlayerService>.value(value: playerService),
        Provider<BackupService>.value(value: backupService),
        ChangeNotifierProvider<DebugLog>.value(value: debugLog),
      ],
      child: const FlmApp(),
    ),
  );
}
