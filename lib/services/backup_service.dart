import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/custom_source_repository.dart';
import '../data/library_repository.dart';
import '../data/settings_repository.dart';
import '../models/app_settings.dart';
import '../state/app_state.dart';
import '../state/library_state.dart';
import '../state/source_state.dart';
import 'player_service.dart';

class BackupImportResult {
  const BackupImportResult({
    required this.playlists,
    required this.sources,
    required this.settings,
  });

  final int playlists;
  final int sources;
  final bool settings;

  bool get isEmpty => playlists == 0 && sources == 0 && !settings;
}

class BackupService {
  BackupService({
    required this.libraryRepository,
    required this.libraryState,
    required this.sourceRepository,
    required this.sourceState,
    required this.settingsRepository,
    required this.appState,
    required this.playerService,
  });

  final LibraryRepository libraryRepository;
  final LibraryState libraryState;
  final CustomSourceRepository sourceRepository;
  final SourceState sourceState;
  final SettingsRepository settingsRepository;
  final AppState appState;
  final FlmPlayerService playerService;

  /// Full backup: playlists + custom source scripts/URLs + settings.
  Future<String> buildJson() async {
    final sources = await sourceRepository.exportEntries();
    final data = <String, dynamic>{
      'type': 'flm_backup',
      'version': 2,
      'exportedAt': DateTime.now().toIso8601String(),
      'playlists': libraryRepository.playlists.map((playlist) => playlist.toJson()).toList(),
      'sources': sources,
      'settings': settingsRepository.settings.toJson(),
      'activeSourceId': settingsRepository.settings.activeSourceId,
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  Future<String> exportToFile() async {
    final documents = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final file = File(p.join(documents.path, 'flm_backup_$stamp.json'));
    await file.writeAsString(await buildJson(), flush: true);
    return file.path;
  }

  Future<BackupImportResult> importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return const BackupImportResult(playlists: 0, sources: 0, settings: false);
    }
    final file = result.files.first;
    final text = file.bytes != null
        ? utf8.decode(file.bytes!, allowMalformed: true)
        : file.path != null
            ? await File(file.path!).readAsString()
            : null;
    if (text == null || text.trim().isEmpty) {
      throw const FormatException('无法读取备份文件');
    }
    return restoreJson(text);
  }

  Future<BackupImportResult> restoreJson(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('不是有效的 flm 备份文件');
    }

    final type = decoded['type'];
    if (type == 'flm_library') {
      final imported = await libraryRepository.importPlaylists(decoded['playlists']);
      libraryState.notifyChanged();
      return BackupImportResult(
        playlists: imported.length,
        sources: 0,
        settings: false,
      );
    }

    if (type != 'flm_backup') {
      throw const FormatException('不是有效的 flm 备份文件');
    }

    var restoredSources = 0;
    var restoredPlaylists = 0;
    var restoredSettings = false;

    final rawSources = decoded['sources'];
    if (rawSources is List && rawSources.isNotEmpty) {
      restoredSources = await sourceRepository.restoreEntries(rawSources);
    }

    final rawPlaylists = decoded['playlists'];
    if (rawPlaylists is List) {
      final imported = await libraryRepository.importPlaylists(rawPlaylists);
      restoredPlaylists = imported.length;
    }
    libraryState.notifyChanged();

    final rawSettings = decoded['settings'];
    if (rawSettings is Map) {
      final restored = AppSettings.fromJson(
        Map<String, dynamic>.from(rawSettings),
      );
      final activeIdRaw = decoded['activeSourceId'] ?? restored.activeSourceId;
      restored.activeSourceId =
          activeIdRaw is String && activeIdRaw.trim().isNotEmpty
              ? activeIdRaw.trim()
              : null;
      await appState.applySettings(restored);
      await playerService.setVolume(restored.volume);
      await playerService.setSpeed(restored.speed);
      restoredSettings = true;
    } else {
      final activeIdRaw = decoded['activeSourceId'];
      if (activeIdRaw is String && activeIdRaw.trim().isNotEmpty) {
        appState.settings.activeSourceId = activeIdRaw.trim();
        await appState.repository.save();
      }
    }

    // Restore the active source last, after both settings and scripts exist.
    final activeId = appState.settings.activeSourceId;
    final activeSource = sourceRepository.byId(activeId);
    if (activeSource != null) {
      await sourceState.setActive(activeSource);
    } else {
      await sourceState.setActive(null);
    }

    return BackupImportResult(
      playlists: restoredPlaylists,
      sources: restoredSources,
      settings: restoredSettings,
    );
  }
}
