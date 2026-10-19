import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/formatters.dart';
import '../models/song.dart';
import '../state/library_state.dart';
import '../state/source_state.dart';

/// Downloads a song that the user favorited into the local music library, so
/// loved tracks are playable offline and show up under 本地音乐.
class DownloadService {
  DownloadService({
    required this.sourceState,
    required this.libraryState,
  });

  final SourceState sourceState;
  final LibraryState libraryState;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 5),
      responseType: ResponseType.stream,
      followRedirects: true,
      maxRedirects: 10,
      headers: const <String, String>{
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
    ),
  );

  final Set<String> _inFlight = <String>{};

  bool _keyExists(Song song) => libraryState.localPlaylist.songs.any(
        (item) =>
            item.name.trim().toLowerCase() == song.name.trim().toLowerCase() &&
            item.singer.trim().toLowerCase() == song.singer.trim().toLowerCase(),
      );

  Future<void> downloadToLibrary(Song song) async {
    if (song.isLocal || song.id.isEmpty || song.source.isEmpty) return;
    final key = '${song.source}:${song.id}';
    if (!_inFlight.add(key)) return;
    try {
      if (_keyExists(song)) return;

      final resolved = await sourceState.resolveMusicUrlAutoSwitch(song);
      final url = '${resolved['url'] ?? ''}';
      if (url.isEmpty || url.startsWith('file://')) return;

      final documents = await getApplicationDocumentsDirectory();
      final musicDir = Directory(p.join(documents.path, 'Music'));
      final coverDir = Directory(p.join(documents.path, 'Covers'));
      await musicDir.create(recursive: true);
      await coverDir.create(recursive: true);

      final base = sanitizeFileName(
        song.singer.trim().isEmpty ? song.displayTitle : '${song.displayTitle} - ${song.singer}',
      );
      var ext = _extensionFor('${resolved['type'] ?? ''}', url);
      var target = File(p.join(musicDir.path, '$base.$ext'));
      var index = 1;
      while (await target.exists()) {
        target = File(p.join(musicDir.path, '$base ($index).$ext'));
        index++;
      }

      final temp = File('${target.path}.download');
      try {
        await _writeTo(url, temp);
        final size = await temp.length();
        if (size < 1024) {
          await temp.delete();
          return;
        }
        await temp.rename(target.path);
      } catch (_) {
        if (await temp.exists()) await temp.delete();
        return;
      }

      final id = 'local_${md5Hex(target.path)}';
      String? coverPath;
      final picUrl = song.picUrl;
      if (picUrl.startsWith('http')) {
        try {
          final coverTemp = File(p.join(coverDir.path, '.dl_$id.jpg'));
          await _writeTo(picUrl, coverTemp);
          if (await coverTemp.length() > 512) {
            final cover = File(p.join(coverDir.path, '$id.jpg'));
            await coverTemp.rename(cover.path);
            coverPath = cover.path;
          } else {
            await coverTemp.delete();
          }
        } catch (_) {}
      }

      if (!await target.exists()) return;
      libraryState.addSong(
        libraryState.localPlaylist.id,
        Song(
          id: id,
          name: song.name,
          singer: song.singer,
          album: song.album,
          interval: song.interval,
          source: 'local',
          picUrl: song.picUrl,
          localPath: target.path,
          localCoverPath: coverPath,
          raw: <String, dynamic>{
            'meta': <String, dynamic>{
              'filePath': target.path,
              'songId': target.path,
              'ext': ext,
              'albumName': song.album,
              'picUrl': coverPath ?? song.picUrl,
            },
          },
        ),
      );
    } catch (_) {
      // Best effort: a failed favorite-download must never surface as an error.
    } finally {
      _inFlight.remove(key);
    }
  }

  String _extensionFor(String type, String url) {
    final t = type.trim().toLowerCase();
    const known = <String>{
      'mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'ape', 'ts', 'mkv',
    };
    if (known.contains(t)) return t;
    try {
      final path = Uri.parse(url).path;
      final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
      if (ext.isNotEmpty && ext.length <= 5 && known.contains(ext)) return ext;
    } catch (_) {}
    return 'mp3';
  }

  Future<void> _writeTo(String url, File file) async {
    final response = await _dio.get<ResponseBody>(url);
    final stream = response.data?.stream;
    if (stream == null) throw StateError('empty response');
    final sink = file.openWrite();
    try {
      await stream.forEach(sink.add);
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}
