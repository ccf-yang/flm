import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/custom_source.dart';

class CustomSourceRepository {
  CustomSourceRepository._(this._dir, this._indexFile, this.sources);

  final Directory _dir;
  final File _indexFile;
  final List<CustomSourceInfo> sources;

  static Future<CustomSourceRepository> load() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'sources'));
    await dir.create(recursive: true);
    final indexFile = File(p.join(dir.path, 'sources.json'));
    final sources = <CustomSourceInfo>[];
    if (await indexFile.exists()) {
      try {
        final decoded = jsonDecode(await indexFile.readAsString());
        if (decoded is List) {
          sources.addAll(
            decoded
                .whereType<Map>()
                .map((item) => CustomSourceInfo.fromJson(Map<String, dynamic>.from(item))),
          );
        }
      } catch (_) {
        sources.clear();
      }
    }
    return CustomSourceRepository._(dir, indexFile, sources);
  }

  Future<void> _saveIndex() async {
    final temp = File('${_indexFile.path}.tmp');
    await temp.writeAsString(
      jsonEncode(sources.map((source) => source.toJson()).toList()),
      flush: true,
    );
    await temp.rename(_indexFile.path);
  }

  CustomSourceInfo? byId(String? id) {
    if (id == null) return null;
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Future<String?> scriptFor(String id) async {
    final file = File(p.join(_dir.path, '$id.js'));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<CustomSourceInfo> importScript(String script, {String? fileName}) async {
    if (sources.length >= 20) {
      throw const FormatException('最多只能同时存在 20 个自定义源');
    }
    final normalized = script.replaceFirst('\uFEFF', '');
    final header = RegExp(r'^/\*[\s\S]*?\*/').firstMatch(normalized)?.group(0) ?? '';
    if (header.isEmpty) {
      throw const FormatException('无效的自定义源文件：开头缺少 /* ... */ 信息块');
    }
    String read(String key) {
      final match = RegExp('@$key\\s+(.+)').firstMatch(header);
      return match?.group(1)?.trim() ?? '';
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final name = read('name').isNotEmpty
        ? read('name')
        : (fileName?.replaceAll(RegExp(r'\.js$'), '') ?? '自定义源 $now');
    final cleanScript = normalized;
    final info = CustomSourceInfo(
      id: 'user_api_$now',
      name: name,
      description: read('description'),
      version: read('version'),
      author: read('author'),
      homepage: read('homepage'),
      createdAt: now,
    );
    final file = File(p.join(_dir.path, '${info.id}.js'));
    await file.writeAsString(cleanScript, flush: true);
    sources.add(info);
    await _saveIndex();
    return info;
  }

  Future<void> delete(String id) async {
    sources.removeWhere((source) => source.id == id);
    final file = File(p.join(_dir.path, '$id.js'));
    if (await file.exists()) await file.delete();
    await _saveIndex();
  }
}
