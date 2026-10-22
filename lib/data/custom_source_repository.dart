import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/custom_source.dart';

class CustomSourceRepository {
  CustomSourceRepository._(this._dir, this._indexFile, this.sources);

  /// Batch probing (自动导入源 / web探测导入源) can legitimately land a couple of
  /// dozen working scripts at once, so the hand-import era's cap of 20 is gone.
  static const int maxSources = 100;

  final Directory _dir;
  final File _indexFile;
  final List<CustomSourceInfo> sources;

  /// Batch detection disables sources from several workers at once, so writes
  /// must not share the same `.tmp` path concurrently.
  Future<void> _saveChain = Future<void>.value();

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

  Future<void> _saveIndex() {
    final task = _saveChain.then((_) => _writeIndex());
    _saveChain = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _writeIndex() async {
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

  List<CustomSourceInfo> byGroup(String group) =>
      sources.where((source) => source.group == group).toList(growable: false);

  Future<String?> scriptFor(String id) async {
    final file = File(p.join(_dir.path, '$id.js'));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<CustomSourceInfo> importScript(
    String script, {
    String? fileName,
    String? importUrl,
    String group = sourceGroupManual,
  }) async {
    if (sources.length >= maxSources) {
      throw const FormatException('最多只能同时存在 $maxSources 个自定义源');
    }
    final parsed = _parseScript(script, fileName: fileName);
    final now = DateTime.now().millisecondsSinceEpoch;
    final info = CustomSourceInfo(
      id: _newId(now),
      name: parsed.name,
      description: parsed.description,
      version: parsed.version,
      author: parsed.author,
      homepage: parsed.homepage,
      importUrl: _cleanUrl(importUrl),
      createdAt: now,
      group: group,
    );
    await _writeScript(info.id, parsed.script);
    sources.add(info);
    await _saveIndex();
    return info;
  }

  /// A batch import writes several entries inside the same millisecond, so the
  /// timestamp id gets a counter only when it would otherwise collide.
  String _newId(int now) {
    var id = 'user_api_$now';
    var suffix = 0;
    while (byId(id) != null) {
      id = 'user_api_${now}_${++suffix}';
    }
    return id;
  }

  /// Replace one batch group wholesale: every script of that group is removed
  /// (file included) and the freshly probed seeds take its place. Hand-imported
  /// sources never participate.
  Future<List<CustomSourceInfo>> replaceGroup(
    String group,
    List<SourceSeed> seeds,
  ) async {
    await clearGroup(group);
    final added = <CustomSourceInfo>[];
    for (final seed in seeds) {
      if (sources.length >= maxSources) break;
      try {
        added.add(await importScript(
          seed.script,
          fileName: seed.label.isEmpty ? null : seed.label,
          importUrl: seed.importUrl,
          group: group,
        ));
      } catch (_) {
        // A seed that stopped parsing since the probe is skipped, not fatal.
      }
    }
    return added;
  }

  Future<int> clearGroup(String group) async {
    final ids = sources.where((source) => source.group == group).map((source) => source.id).toList();
    if (ids.isEmpty) return 0;
    for (final id in ids) {
      final file = File(p.join(_dir.path, '$id.js'));
      if (await file.exists()) await file.delete();
    }
    sources.removeWhere((source) => ids.contains(source.id));
    await _saveIndex();
    return ids.length;
  }

  /// Re-download/refresh an existing source without creating a duplicate.
  Future<CustomSourceInfo> updateScript(
    String id,
    String script, {
    String? importUrl,
  }) async {
    final index = sources.indexWhere((source) => source.id == id);
    if (index < 0) throw const FormatException('自定义源不存在');
    final parsed = _parseScript(script);
    final previous = sources[index];
    final info = CustomSourceInfo(
      id: previous.id,
      name: parsed.name,
      description: parsed.description,
      version: parsed.version,
      author: parsed.author,
      homepage: parsed.homepage,
      importUrl: _cleanUrl(importUrl) ?? previous.importUrl,
      createdAt: previous.createdAt,
      disabled: previous.disabled,
      group: previous.group,
    );
    await _writeScript(info.id, parsed.script);
    sources[index] = info;
    await _saveIndex();
    return info;
  }

  /// Persist the disabled switch of one source.
  Future<void> setDisabled(String id, bool disabled) async {
    final index = sources.indexWhere((source) => source.id == id);
    if (index < 0) return;
    sources[index] = sources[index].copyWith(disabled: disabled);
    await _saveIndex();
  }

  Future<void> delete(String id) async {
    sources.removeWhere((source) => source.id == id);
    final file = File(p.join(_dir.path, '$id.js'));
    if (await file.exists()) await file.delete();
    await _saveIndex();
  }

  /// Used by the full backup: metadata + script, so a restore works offline.
  Future<List<Map<String, dynamic>>> exportEntries() async {
    final entries = <Map<String, dynamic>>[];
    for (final source in sources) {
      final map = source.toJson();
      map['script'] = await scriptFor(source.id) ?? '';
      entries.add(map);
    }
    return entries;
  }

  Future<int> restoreEntries(List<dynamic> rawEntries) async {
    var restored = 0;
    for (final raw in rawEntries) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final id = '${map['id'] ?? ''}'.trim();
      final script = '${map['script'] ?? ''}';
      if (id.isEmpty || script.trim().isEmpty) continue;

      try {
        final parsed = _parseScript(script, fileName: '${map['name'] ?? 'source'}.js');
        final importUrlRaw = map['importUrl'];
        final importUrl = importUrlRaw is String && importUrlRaw.trim().isNotEmpty
            ? importUrlRaw.trim()
            : null;
        final nameRaw = map['name'];
        final restoredName = nameRaw is String && nameRaw.trim().isNotEmpty
            ? nameRaw.trim()
            : parsed.name;
        final info = CustomSourceInfo(
          id: id,
          name: restoredName,
          description: '${map['description'] ?? parsed.description}',
          version: '${map['version'] ?? parsed.version}',
          author: '${map['author'] ?? parsed.author}',
          homepage: '${map['homepage'] ?? parsed.homepage}',
          importUrl: importUrl,
          createdAt: (map['createdAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          disabled: map['disabled'] == true,
          group: '${map['group'] ?? sourceGroupManual}',
        );

        await _writeScript(id, parsed.script);
        final index = sources.indexWhere((source) => source.id == id);
        if (index >= 0) {
          sources[index] = info;
        } else {
          if (sources.length >= maxSources) continue;
          sources.add(info);
        }
        restored++;
      } catch (_) {
        // Skip invalid scripts instead of failing the whole backup.
      }
    }
    if (restored > 0) await _saveIndex();
    return restored;
  }

  Future<void> _writeScript(String id, String script) async {
    final file = File(p.join(_dir.path, '$id.js'));
    await file.writeAsString(script, flush: true);
  }

  String? _cleanUrl(String? value) {
    final url = value?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  _ParsedSource _parseScript(String script, {String? fileName}) {
    final normalized = script.replaceFirst('\uFEFF', '');
    final header = RegExp(r'^/\*[\s\S]*?\*/').firstMatch(normalized)?.group(0) ?? '';
    if (header.isEmpty) {
      throw const FormatException('无效的自定义源文件：开头缺少 /* ... */ 信息块');
    }
    String read(String key) {
      final match = RegExp('@$key\\s+(.+)').firstMatch(header);
      return match?.group(1)?.trim() ?? '';
    }

    final fallbackName = fileName?.replaceAll(RegExp(r'\.js$'), '').trim();
    return _ParsedSource(
      script: normalized,
      name: read('name').isNotEmpty
          ? read('name')
          : (fallbackName?.isNotEmpty ?? false
              ? fallbackName!
              : '自定义源 ${DateTime.now().millisecondsSinceEpoch}'),
      description: read('description'),
      version: read('version'),
      author: read('author'),
      homepage: read('homepage'),
    );
  }
}

class _ParsedSource {
  const _ParsedSource({
    required this.script,
    required this.name,
    required this.description,
    required this.version,
    required this.author,
    required this.homepage,
  });

  final String script;
  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;
}
