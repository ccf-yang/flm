import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/playlist.dart';
import '../models/song.dart';

class LibraryRepository {
  LibraryRepository._(this._file, this.playlists);

  final File _file;
  final List<Playlist> playlists;
  Future<void> _saveChain = Future<void>.value();

  static Future<LibraryRepository> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'library.json'));
    final playlists = <Playlist>[];
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          playlists.addAll(
            decoded
                .whereType<Map>()
                .map((item) => Playlist.fromJson(Map<String, dynamic>.from(item))),
          );
        }
      } catch (_) {
        playlists.clear();
      }
    }

    void ensure(Playlist playlist) {
      if (!playlists.any((item) => item.id == playlist.id)) {
        playlists.insert(0, playlist);
      }
    }

    ensure(Playlist.localList());
    ensure(Playlist.loveList());
    ensure(Playlist.defaultList());

    final repo = LibraryRepository._(file, playlists);
    await repo.save();
    return repo;
  }

  Playlist get defaultPlaylist => playlists.firstWhere(
        (item) => item.id == 'default',
        orElse: () {
          final list = Playlist.defaultList();
          playlists.add(list);
          return list;
        },
      );

  Playlist get lovePlaylist => playlists.firstWhere(
        (item) => item.id == 'love',
        orElse: () {
          final list = Playlist.loveList();
          playlists.add(list);
          return list;
        },
      );

  Playlist get localPlaylist => playlists.firstWhere(
        (item) => item.id == 'local',
        orElse: () {
          final list = Playlist.localList();
          playlists.add(list);
          return list;
        },
      );

  List<Playlist> get userPlaylists =>
      playlists.where((item) => !item.isBuiltIn).toList(growable: false);

  Playlist? byId(String id) {
    for (final playlist in playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  Playlist createPlaylist(String name) {
    final id = 'userlist_${DateTime.now().millisecondsSinceEpoch}';
    final playlist = Playlist(id: id, name: name.trim().isEmpty ? '新列表' : name.trim());
    playlists.add(playlist);
    save();
    return playlist;
  }

  void renamePlaylist(String id, String name) {
    final playlist = byId(id);
    if (playlist == null || playlist.isBuiltIn) return;
    playlist.name = name.trim().isEmpty ? playlist.name : name.trim();
    save();
  }

  void deletePlaylist(String id) {
    final playlist = byId(id);
    if (playlist == null || playlist.isBuiltIn) return;
    playlists.remove(playlist);
    save();
  }

  void addSong(String playlistId, Song song, {bool toTop = false}) {
    byId(playlistId)?.add(song, toTop: toTop);
    save();
  }

  void addSongs(String playlistId, Iterable<Song> songs, {bool toTop = false}) {
    byId(playlistId)?.addAll(songs, toTop: toTop);
    save();
  }

  void removeSongs(String playlistId, Set<String> ids) {
    byId(playlistId)?.removeIds(ids);
    save();
  }

  bool toggleLove(Song song) {
    final love = lovePlaylist;
    if (love.contains(song)) {
      love.removeIds(<String>{song.id});
      save();
      return false;
    }
    love.add(song);
    save();
    return true;
  }

  bool isLoved(Song song) => lovePlaylist.contains(song);

  /// Serialize writes (favorites, downloads and bulk imports all save without
  /// awaiting, and a shared `.tmp` file would race).
  Future<void> save() {
    final task = _saveChain.then((_) => _writeSnapshot());
    _saveChain = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _writeSnapshot() async {
    final data = playlists.map((playlist) => playlist.toJson()).toList();
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(_file.path);
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(
        <String, dynamic>{
          'type': 'flm_library',
          'version': 1,
          'exportedAt': DateTime.now().toIso8601String(),
          'playlists': playlists.map((playlist) => playlist.toJson()).toList(),
        },
      );

  Future<List<Playlist>> importJson(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['type'] != 'flm_library') {
      throw const FormatException('不是有效的 flm 备份文件');
    }
    return importPlaylists(decoded['playlists']);
  }

  Future<List<Playlist>> importPlaylists(dynamic raw) async {
    if (raw is! List) throw const FormatException('备份文件缺少列表数据');

    final incoming = raw
        .whereType<Map>()
        .map((item) => Playlist.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    for (final playlist in incoming) {
      final existing = byId(playlist.id);
      if (existing != null) {
        if (playlist.name.isNotEmpty && !existing.isBuiltIn) {
          existing.name = playlist.name;
        }
        existing.songs
          ..clear()
          ..addAll(playlist.songs);
      } else if (!playlist.isBuiltIn) {
        playlists.add(playlist);
      }
    }

    await save();
    return incoming;
  }
}
