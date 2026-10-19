import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

class SettingsRepository {
  SettingsRepository._(this._file, this.settings);

  final File _file;
  AppSettings settings;
  Future<void> _saveChain = Future<void>.value();

  static Future<SettingsRepository> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'settings.json'));
    AppSettings settings;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        settings = decoded is Map<String, dynamic>
            ? AppSettings.fromJson(decoded)
            : AppSettings();
      } catch (_) {
        settings = AppSettings();
      }
    } else {
      settings = AppSettings();
    }
    return SettingsRepository._(file, settings);
  }

  /// Serialize writes. Progress, drag position and settings changes can all
  /// ask for a save at once; two writers sharing the same `.tmp` path would
  /// otherwise race and one rename would fail.
  Future<void> save() {
    final task = _saveChain.then((_) => _writeSnapshot());
    _saveChain = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _writeSnapshot() async {
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await temp.rename(_file.path);
  }

  Future<void> update(void Function(AppSettings settings) mutator) async {
    mutator(settings);
    await save();
  }

  void addSearchHistory(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) return;
    settings.searchHistory.remove(text);
    settings.searchHistory.insert(0, text);
    if (settings.searchHistory.length > 30) {
      settings.searchHistory.removeRange(30, settings.searchHistory.length);
    }
    save();
  }

  void removeSearchHistory(String keyword) {
    settings.searchHistory.remove(keyword);
    save();
  }

  void clearSearchHistory() {
    settings.searchHistory.clear();
    save();
  }

  void dislike(String key) {
    if (!settings.dislikedKeys.contains(key)) {
      settings.dislikedKeys.add(key);
      save();
    }
  }

  void clearDislikes() {
    settings.dislikedKeys.clear();
    save();
  }

  void rememberPlayback(String? songJson, int positionMs) {
    settings.lastSongJson = songJson == null ? null : jsonDecode(songJson) as Map<String, dynamic>;
    settings.lastPositionMs = positionMs;
    save();
  }
}
