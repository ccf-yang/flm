import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../data/custom_source_repository.dart';
import '../models/custom_source.dart';
import '../models/song.dart';
import '../services/source_engine.dart';
import 'app_state.dart';

class SourceState extends ChangeNotifier {
  SourceState({
    required this.repository,
    required this.engine,
    required this.appState,
  });

  final CustomSourceRepository repository;
  final SourceEngine engine;
  final AppState appState;

  bool loading = false;
  bool importing = false;
  String? error;
  SourceCapabilities capabilities = SourceCapabilities.empty();

  /// Cache of which music platforms each custom source can resolve, keyed by
  /// source id. Used to prefer a source that likely supports a song during the
  /// transparent cross-source fallback in [resolveMusicUrlAutoSwitch].
  final Map<String, Set<String>> _supported = <String, Set<String>>{};

  List<CustomSourceInfo> get sources => repository.sources;

  CustomSourceInfo? get active {
    final id = appState.settings.activeSourceId;
    if (id == null) return null;
    return repository.byId(id);
  }

  bool get hasActiveSource => active != null && !capabilities.isEmpty;

  Future<void> init() async {
    final source = active;
    if (source == null) return;
    final script = await repository.scriptFor(source.id);
    if (script == null || script.trim().isEmpty) {
      error = '自定义源脚本不存在';
      notifyListeners();
      return;
    }
    await _activate(source, script);
  }

  Future<void> reload() async {
    final source = active;
    if (source == null) {
      engine.clear();
      capabilities = SourceCapabilities.empty();
      notifyListeners();
      return;
    }
    final script = await repository.scriptFor(source.id);
    if (script == null) return;
    await _activate(source, script);
  }

  Future<void> _activate(CustomSourceInfo source, String script) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      capabilities = await engine.activate(source, script);
      final names = <String>{};
      for (final name in capabilities.sources.keys) {
        if (capabilities.supports(name, 'musicUrl')) names.add(name);
      }
      _supported[source.id] = names;
    } catch (e) {
      capabilities = SourceCapabilities.empty();
      _supported.remove(source.id);
      error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setActive(CustomSourceInfo? source) async {
    appState.settings.activeSourceId = source?.id;
    await appState.repository.save();
    if (source == null) {
      engine.clear();
      capabilities = SourceCapabilities.empty();
      error = null;
      notifyListeners();
      return;
    }
    await reload();
  }

  Future<CustomSourceInfo?> importSource() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final script = file.bytes != null
        ? utf8.decode(file.bytes!, allowMalformed: true)
        : file.path != null
            ? await File(file.path!).readAsString()
            : null;
    if (script == null || script.trim().isEmpty) {
      throw const FormatException('无法读取脚本内容');
    }
    final info = await repository.importScript(script, fileName: file.name);
    notifyListeners();
    return info;
  }

  Future<CustomSourceInfo?> importSourceFromUrl(String rawUrl) async {
    final uri = _parseUrl(rawUrl);
    if (sources.length >= 20) {
      throw const FormatException('最多只能同时存在 20 个自定义源');
    }

    importing = true;
    notifyListeners();
    try {
      final script = await _downloadScript(uri);
      final fileName = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'remote_source.js';
      final info = await repository.importScript(
        script,
        fileName: fileName.isEmpty ? 'remote_source.js' : fileName,
        importUrl: uri.toString(),
      );
      notifyListeners();
      return info;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  /// Re-download an imported source from its saved URL, keeping the same id.
  Future<CustomSourceInfo> updateSourceFromUrl(CustomSourceInfo source) async {
    final rawUrl = source.importUrl;
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      throw const FormatException('该自定义源没有保存在线 URL');
    }
    final uri = _parseUrl(rawUrl);
    importing = true;
    notifyListeners();
    try {
      final script = await _downloadScript(uri);
      final updated = await repository.updateScript(
        source.id,
        script,
        importUrl: uri.toString(),
      );
      notifyListeners();
      if (active?.id == updated.id) {
        await reload();
      }
      return updated;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  Uri _parseUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('请输入有效的 http / https 链接');
    }
    return uri;
  }

  Future<String> _downloadScript(Uri uri) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        sendTimeout: const Duration(seconds: 15),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
        followRedirects: true,
        maxRedirects: 5,
        headers: const <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
          'Accept': 'application/javascript, text/javascript, text/plain, */*',
        },
      ),
    );
    final response = await dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    final script = response.data;
    if (script == null || script.trim().isEmpty) {
      throw const FormatException('下载内容为空');
    }
    if (script.length > 1024 * 1024) {
      throw const FormatException('脚本超过 1 MiB，已拒绝导入');
    }
    return script;
  }

  Future<void> deleteSource(String id) async {
    await repository.delete(id);
    _supported.remove(id);
    if (appState.settings.activeSourceId == id) {
      await setActive(null);
    } else {
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> resolveMusicUrl(Song song, {String? quality}) async {
    if (song.isLocal) {
      return <String, dynamic>{'url': song.localPath, 'type': 'local'};
    }
    final source = active;
    if (source == null) {
      throw StateError('尚未启用自定义源。请先到「设置 → 自定义源」导入并启用音源脚本。');
    }
    if (capabilities.isEmpty) {
      throw StateError(error ?? '自定义源尚未初始化完成');
    }
    if (!capabilities.supports(song.source, 'musicUrl')) {
      throw StateError('当前自定义源不支持 ${song.source.toUpperCase()} 的音源');
    }
    final supported = capabilities.qualitysFor(song.source);
    var targetQuality = quality ?? appState.settings.quality;
    if (supported.isNotEmpty && !supported.contains(targetQuality)) {
      const order = <String>['128k', '320k', 'flac', 'flac24bit'];
      final requestedIndex = order.indexOf(targetQuality);
      String? fallback;
      for (final item in supported) {
        final index = order.indexOf(item);
        if (index >= 0 && requestedIndex >= 0 && index <= requestedIndex) {
          fallback = item;
        }
      }
      targetQuality = fallback ?? supported.first;
    }
    const order = <String>['flac24bit', 'flac', '320k', '128k'];
    final targetIndex = order.indexOf(targetQuality);
    final candidates = supported
        .where((item) => order.contains(item) && order.indexOf(item) >= targetIndex)
        .toList()
      ..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    final tryQualitys = supported.isEmpty
        ? <String>[targetQuality]
        : candidates.toList();
    if (tryQualitys.isEmpty) tryQualitys.add(targetQuality);

    Object? lastError;
    for (final currentQuality in tryQualitys) {
      try {
        final result = await engine.requestMusicUrl(
          source: song.source,
          quality: currentQuality,
          song: song,
        );
        final data = result['data'];
        if (data is! Map) throw StateError('自定义源返回格式错误');
        final url = '${data['url'] ?? ''}';
        if (url.isEmpty) throw StateError('自定义源没有返回播放链接');
        return <String, dynamic>{
          'url': url,
          'type': '${data['type'] ?? currentQuality}',
        };
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('自定义源没有返回播放链接');
  }

  /// Resolve a playable URL, transparently falling back across the configured
  /// custom sources. Starts from the currently active source, then tries the
  /// others (preferring any previously known to support this song's platform).
  /// The first source that returns a URL stays active, so subsequent songs keep
  /// using it without the user noticing a "source switch". If nothing works the
  /// original active source is restored before throwing.
  Future<Map<String, dynamic>> resolveMusicUrlAutoSwitch(
    Song song, {
    String? quality,
  }) async {
    if (song.isLocal) {
      return <String, dynamic>{'url': song.localPath, 'type': 'local'};
    }

    final original = active;
    final candidates = <CustomSourceInfo>[];
    if (original != null) candidates.add(original);
    final others = sources
        .where((source) => source.id != original?.id)
        .toList()
      ..sort((a, b) {
        final aSupports = _supported[a.id]?.contains(song.source) ?? false;
        final bSupports = _supported[b.id]?.contains(song.source) ?? false;
        if (aSupports != bSupports) return aSupports ? -1 : 1;
        return 0;
      });
    candidates.addAll(others);

    if (candidates.isEmpty) {
      // No source configured — let resolveMusicUrl raise its own guidance.
      return resolveMusicUrl(song, quality: quality);
    }

    Object? lastError;
    for (final candidate in candidates) {
      if (candidate.id != active?.id) {
        await setActive(candidate);
      }
      if (!capabilities.supports(song.source, 'musicUrl')) {
        lastError ??= StateError(
          '没有可用的自定义源支持 ${song.source.toUpperCase()} 的音源',
        );
        continue;
      }
      try {
        return await resolveMusicUrl(song, quality: quality);
      } catch (error) {
        lastError = error;
      }
    }

    if (original != null && active?.id != original.id) {
      await setActive(original);
    }
    throw lastError ?? StateError('没有可用的自定义源返回播放链接');
  }

  @override
  void dispose() {
    engine.clear();
    super.dispose();
  }
}
