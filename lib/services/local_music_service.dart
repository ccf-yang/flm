import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/formatters.dart';
import '../models/song.dart';
import 'local_metadata_reader.dart';

class LocalMusicService {
  static const Set<String> _audioExtensions = <String>{
    'mp3', 'm4a', 'm4b', 'aac', 'flac', 'wav', 'alac', 'aiff',
    'ogg', 'opus', 'wma', 'ape', 'mva', 'mp2',
  };

  Future<List<Song>> pickAndImport() async {
    // FileType.audio maps to UTType filters on iOS that crash inside the native
    // picker on some file providers; pick with FileType.any and filter here.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false,
    );
    if (result == null) return const <Song>[];
    final files = result.files.where(_looksAudio).toList();
    if (files.isEmpty) return const <Song>[];
    return importPickedFiles(files);
  }

  bool _looksAudio(PlatformFile file) {
    final ext = p.extension(file.name).replaceFirst('.', '').toLowerCase();
    if (ext.isEmpty) return false;
    return _audioExtensions.contains(ext);
  }

  Future<List<Song>> importPickedFiles(List<PlatformFile> files) async {
    final documents = await getApplicationDocumentsDirectory();
    final musicDir = Directory(p.join(documents.path, 'Music'));
    final coverDir = Directory(p.join(documents.path, 'Covers'));
    await musicDir.create(recursive: true);
    await coverDir.create(recursive: true);

    final songs = <Song>[];
    for (final picked in files) {
      try {
        File? source;
        if (picked.path != null) {
          source = File(picked.path!);
        } else if (picked.bytes != null) {
          final temp = File(p.join(musicDir.path, '.import_${DateTime.now().microsecondsSinceEpoch}'));
          await temp.writeAsBytes(picked.bytes!, flush: true);
          source = temp;
        }
        if (source == null || !await source.exists()) continue;

        var fileName = p.basename(source.path);
        if (fileName.startsWith('.import_')) {
          fileName = picked.name;
        }
        var target = File(p.join(musicDir.path, fileName));
        if (await target.exists() && p.absolute(target.path) != p.absolute(source.path)) {
          final base = p.basenameWithoutExtension(fileName);
          final ext = p.extension(fileName);
          var index = 1;
          while (await target.exists()) {
            target = File(p.join(musicDir.path, '$base ($index)$ext'));
            index++;
          }
        }
        if (p.absolute(source.path) != p.absolute(target.path)) {
          await source.copy(target.path);
        }

        final sidecar = File(p.setExtension(source.path, '.lrc'));
        if (await sidecar.exists()) {
          final targetLrc = File(p.setExtension(target.path, '.lrc'));
          if (!await targetLrc.exists()) {
            await sidecar.copy(targetLrc.path);
          }
        }

        final metadata = await LocalMetadataReader.read(target);
        final id = 'local_${md5Hex(target.path)}';
        String? coverPath;
        final picture = metadata.picture;
        if (picture != null && picture.isNotEmpty) {
          final cover = File(p.join(coverDir.path, '$id.jpg'));
          await cover.writeAsBytes(picture, flush: true);
          coverPath = cover.path;
        }

        songs.add(
          Song(
            id: id,
            name: metadata.title.trim().isEmpty
                ? p.basenameWithoutExtension(target.path)
                : metadata.title.trim(),
            singer: metadata.artist.trim(),
            album: metadata.album.trim(),
            source: 'local',
            localPath: target.path,
            localCoverPath: coverPath,
            raw: <String, dynamic>{
              'meta': <String, dynamic>{
                'filePath': target.path,
                'songId': target.path,
                'ext': p.extension(target.path).replaceFirst('.', ''),
                'albumName': metadata.album,
                'picUrl': coverPath ?? '',
              },
            },
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return songs;
  }
}
