import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/library_repository.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/local_music_service.dart';

class LibraryState extends ChangeNotifier {
  LibraryState({
    required this.repository,
    required this.localMusic,
  });

  final LibraryRepository repository;
  final LocalMusicService localMusic;

  List<Playlist> get playlists => repository.playlists;
  Playlist get defaultPlaylist => repository.defaultPlaylist;
  Playlist get lovePlaylist => repository.lovePlaylist;
  Playlist get localPlaylist => repository.localPlaylist;
  List<Playlist> get userPlaylists => repository.userPlaylists;

  Playlist? byId(String id) => repository.byId(id);

  Playlist createPlaylist(String name) {
    final playlist = repository.createPlaylist(name);
    notifyListeners();
    return playlist;
  }

  void renamePlaylist(String id, String name) {
    repository.renamePlaylist(id, name);
    notifyListeners();
  }

  void deletePlaylist(String id) {
    repository.deletePlaylist(id);
    notifyListeners();
  }

  void addSong(String playlistId, Song song, {bool toTop = false}) {
    repository.addSong(playlistId, song, toTop: toTop);
    notifyListeners();
  }

  void addSongs(String playlistId, Iterable<Song> songs, {bool toTop = false}) {
    repository.addSongs(playlistId, songs, toTop: toTop);
    notifyListeners();
  }

  int ensureInDefault(Song song) {
    final playlist = defaultPlaylist;
    var index = playlist.indexOf(song);
    if (index < 0) {
      playlist.add(song, toTop: true);
      index = 0;
      repository.save();
    }
    notifyListeners();
    return index;
  }

  void removeSongs(String playlistId, Set<String> ids) {
    repository.removeSongs(playlistId, ids);
    notifyListeners();
  }

  bool toggleLove(Song song) {
    final result = repository.toggleLove(song);
    notifyListeners();
    return result;
  }

  bool isLoved(Song song) => repository.isLoved(song);

  void updateSongInterval(Song song, String interval) {
    if (interval.trim().isEmpty) return;
    var changed = false;
    for (final playlist in repository.playlists) {
      final index = playlist.songs.indexWhere(
        (item) => item.id == song.id && item.source == song.source,
      );
      if (index < 0) continue;
      if (playlist.songs[index].interval == interval) continue;
      playlist.songs[index] = playlist.songs[index].copyWith(interval: interval);
      changed = true;
    }
    if (!changed) return;
    repository.save();
    notifyListeners();
  }

  void reorderSong(String playlistId, int oldIndex, int newIndex) {
    final playlist = repository.byId(playlistId);
    if (playlist == null) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= playlist.songs.length) return;
    if (newIndex < 0 || newIndex >= playlist.songs.length) return;
    final song = playlist.songs.removeAt(oldIndex);
    playlist.songs.insert(newIndex, song);
    repository.save();
    notifyListeners();
  }

  void sortPlaylist(String playlistId, String field, bool ascending) {
    final playlist = repository.byId(playlistId);
    if (playlist == null) return;
    int compare(Song a, Song b) {
      switch (field) {
        case 'singer':
          return a.singer.toLowerCase().compareTo(b.singer.toLowerCase());
        case 'album':
          return a.album.toLowerCase().compareTo(b.album.toLowerCase());
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }

    playlist.songs.sort((a, b) => ascending ? compare(a, b) : compare(b, a));
    repository.save();
    notifyListeners();
  }

  List<Song> searchInPlaylist(String playlistId, String keyword) {
    final playlist = repository.byId(playlistId);
    if (playlist == null) return const <Song>[];
    final text = keyword.trim().toLowerCase();
    if (text.isEmpty) return playlist.songs;
    return playlist.songs.where((song) {
      return song.name.toLowerCase().contains(text) ||
          song.singer.toLowerCase().contains(text) ||
          song.album.toLowerCase().contains(text);
    }).toList();
  }

  Future<int> importLocalMusic() async {
    final songs = await localMusic.pickAndImport();
    if (songs.isEmpty) return 0;
    repository.addSongs(localPlaylist.id, songs, toTop: false);
    notifyListeners();
    return songs.length;
  }

  Future<String> exportBackup() async {
    final documents = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final file = File(p.join(documents.path, 'flm_backup_$stamp.json'));
    await file.writeAsString(repository.exportJson(), flush: true);
    return file.path;
  }

  Future<int> importBackup() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return 0;
    final file = result.files.first;
    final text = file.bytes != null
        ? utf8.decode(file.bytes!)
        : file.path != null
            ? await File(file.path!).readAsString()
            : null;
    if (text == null) throw const FormatException('无法读取备份文件');
    final imported = await repository.importJson(text);
    notifyListeners();
    return imported.length;
  }
}
