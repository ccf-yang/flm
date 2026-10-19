import 'package:flutter/material.dart';

import '../data/settings_repository.dart';
import '../models/app_settings.dart';
import '../models/song.dart';

class AppState extends ChangeNotifier {
  AppState(this.repository);

  final SettingsRepository repository;

  AppSettings get settings => repository.settings;

  ThemeMode get themeMode {
    switch (settings.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(String mode) async {
    settings.themeMode = mode;
    notifyListeners();
    await repository.save();
  }

  Future<void> update(void Function(AppSettings settings) mutator) async {
    mutator(settings);
    notifyListeners();
    await repository.save();
  }

  void addSearchHistory(String keyword) {
    repository.addSearchHistory(keyword);
    notifyListeners();
  }

  void removeSearchHistory(String keyword) {
    repository.removeSearchHistory(keyword);
    notifyListeners();
  }

  void clearSearchHistory() {
    repository.clearSearchHistory();
    notifyListeners();
  }

  void dislike(Song song) {
    repository.dislike(AppSettings.dislikeKeyFor(song));
    notifyListeners();
  }

  void clearDislikes() {
    repository.clearDislikes();
    notifyListeners();
  }

  bool isDisliked(Song song) => settings.isDisliked(song);
}
