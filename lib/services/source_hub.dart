import 'dart:convert';

import 'package:dio/dio.dart';

/// Read-only client for the lx-hub index (https://zlyon.github.io/lx-hub/).
///
/// The site publishes one static file, `data.json`, that its own scanner writes
/// every day: each entry is a userApi script that the hub has already resolved
/// against a real song, together with the per-platform verdict. The scanner's
/// `/api/*` endpoints need its admin server, so only the static export is used
/// here — plus the per-entry copies the Pages build publishes under `s/`, which
/// are the only GitHub-hosted URLs this network can always reach (raw.githubusercontent
/// and the API are frequently blocked or rate limited).
const String hubSiteUrl = 'https://zlyon.github.io/lx-hub/';
const String hubIndexUrl = '${hubSiteUrl}data.json';
const String hubBuiltinReposUrl =
    'https://raw.githubusercontent.com/zlyon/lx-hub/main/builtin-repos.json';

/// Where the hub keeps an identical copy of every published script.
String hubCopyUrl(String id) => '${hubSiteUrl}s/$id.js';

const Map<String, String> hubPlatformNames = <String, String>{
  'wy': '网易云',
  'tx': 'QQ',
  'kw': '酷我',
  'kg': '酷狗',
  'mg': '咪咕',
  'am': '虾米',
  'bd': '百度',
  'py': '盘狗',
};

String hubPlatformLabel(String code) => hubPlatformNames[code] ?? code.toUpperCase();

/// One published script and the hub's own verdict about it.
class HubSourceEntry {
  const HubSourceEntry({
    required this.id,
    required this.name,
    required this.author,
    required this.version,
    required this.status,
    required this.platformStatus,
    required this.rawUrl,
    required this.mirrors,
    this.origin = '',
    this.size = 0,
  });

  final String id;
  final String name;
  final String author;
  final String version;

  /// `ok` / `failed` … — the hub's overall verdict.
  final String status;

  /// Per platform: `usable` / `failed` plus the message it explained itself with.
  final Map<String, HubPlatformVerdict> platformStatus;

  /// The canonical raw address the hub crawled the script from.
  final String rawUrl;

  /// Other repos hosting the same script.
  final List<String> mirrors;
  final String origin;
  final int size;

  List<String> get usablePlatforms => platformStatus.entries
      .where((entry) => entry.value.usable)
      .map((entry) => entry.key)
      .toList(growable: false);

  bool get hasUsablePlatform => usablePlatforms.isNotEmpty;

  /// Download order: the hub's own copy first (Pages is the reliable host on
  /// this network), then the crawled address, then every mirror.
  List<String> get downloadCandidates {
    final urls = <String>[hubCopyUrl(id)];
    if (rawUrl.isNotEmpty) urls.add(rawUrl);
    for (final mirror in mirrors) {
      if (!urls.contains(mirror)) urls.add(mirror);
    }
    return urls;
  }

  /// Short human description used in the import dialog: `网易云、QQ 可用`.
  String get platformSummary {
    final usable = usablePlatforms;
    if (usable.isEmpty) return '无可用平台';
    return '${usable.map(hubPlatformLabel).join('、')} 可用';
  }

  factory HubSourceEntry.fromJson(Map<String, dynamic> json) {
    final platforms = <String, HubPlatformVerdict>{};
    final rawPlatforms = json['platStatus'];
    if (rawPlatforms is Map) {
      rawPlatforms.forEach((key, value) {
        if (value is Map) {
          platforms['$key'] = HubPlatformVerdict.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    final mirrors = <String>[
      if (json['mirrors'] is List)
        ...(json['mirrors'] as List).whereType<String>(),
    ];
    return HubSourceEntry(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}'.trim(),
      author: '${json['author'] ?? ''}'.trim(),
      version: '${json['version'] ?? ''}'.trim(),
      status: '${json['status'] ?? ''}',
      platformStatus: platforms,
      rawUrl: '${json['url'] ?? ''}'.trim(),
      mirrors: mirrors,
      origin: '${json['originRepo'] ?? json['origin'] ?? ''}'.trim(),
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class HubPlatformVerdict {
  const HubPlatformVerdict({required this.status, this.message = ''});

  final String status;
  final String message;

  bool get usable => status == 'usable';

  factory HubPlatformVerdict.fromJson(Map<String, dynamic> json) =>
      HubPlatformVerdict(
        status: '${json['status'] ?? ''}',
        message: '${json['message'] ?? ''}'.trim(),
      );
}

/// The published index, trimmed down to what the import flows need.
class HubIndex {
  const HubIndex({
    required this.entries,
    required this.generatedAt,
    required this.usableCount,
    required this.scannedRepos,
  });

  final List<HubSourceEntry> entries;

  /// When the hub ran its own scan — shown so a stale list is visible.
  final DateTime? generatedAt;
  final int usableCount;
  final int scannedRepos;

  factory HubIndex.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    return HubIndex(
      entries: items is List
          ? items
              .whereType<Map>()
              .map((item) =>
                  HubSourceEntry.fromJson(Map<String, dynamic>.from(item)))
              .where((entry) => entry.id.isNotEmpty)
              .toList(growable: false)
          : const <HubSourceEntry>[],
      generatedAt: DateTime.tryParse('${json['generatedAt'] ?? ''}'),
      usableCount: (json['usableCount'] as num?)?.toInt() ?? 0,
      scannedRepos: (json['scannedRepos'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Fetches the hub index and the scripts it points at.
class SourceHub {
  SourceHub({Dio? dio, Duration timeout = const Duration(seconds: 20)})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: timeout,
              receiveTimeout: timeout,
              sendTimeout: timeout,
              validateStatus: (status) => status != null && status >= 200 && status < 300,
              followRedirects: true,
              maxRedirects: 5,
              headers: const <String, String>{
                'User-Agent':
                    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 '
                    'Mobile/15E148 Safari/604.1',
                'Accept': '*/*',
              },
            ));

  static const int maxScriptBytes = 1024 * 1024;

  final Dio _dio;

  Future<HubIndex> fetchIndex() async {
    final response = await _dio.get<String>(
      hubIndexUrl,
      options: Options(responseType: ResponseType.plain),
    );
    final raw = response.data ?? '';
    if (raw.trim().isEmpty) throw const FormatException('源索引内容为空');
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('源索引格式不正确');
    return HubIndex.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Curated repo list the hub scans. Only used to report where the pool comes
  /// from — the script addresses themselves come from [fetchIndex].
  Future<List<String>> fetchBuiltinRepos() async {
    try {
      final response = await _dio.get<String>(
        hubBuiltinReposUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final decoded = jsonDecode(response.data ?? '{}');
      if (decoded is! Map) return const <String>[];
      final repos = decoded['repos'];
      if (repos is! List) return const <String>[];
      return repos
          .whereType<Map>()
          .map((item) => '${item['repo'] ?? ''}'.trim())
          .where((repo) => repo.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  /// Try each candidate address until one returns a plausible userApi script.
  /// Returns the script text together with the address that served it, so the
  /// entry keeps a refresh URL that actually works from this network.
  Future<HubDownload> downloadFirst(List<String> urls) async {
    final failures = <String>[];
    for (final url in urls) {
      try {
        final script = await _getString(url);
        return HubDownload(script: script, url: url);
      } catch (error) {
        failures.add('$url → $error');
        if (failures.length >= 4) break;
      }
    }
    throw FormatException(
      '脚本下载失败：${failures.isEmpty ? '没有可用的脚本地址' : failures.first}',
    );
  }

  Future<String> _getString(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final body = response.data ?? '';
    if (body.trim().isEmpty) throw const FormatException('内容为空');
    if (body.length > maxScriptBytes) {
      throw const FormatException('脚本超过 1 MiB');
    }
    // A captive portal or a 404 page served with 200 would otherwise be stored
    // as a "source" and only fail later during playback.
    if (!RegExp(r'/\*[\s\S]{0,4000}?\*/').hasMatch(body.substring(
      0, body.length > 4000 ? 4000 : body.length,
    ))) {
      throw const FormatException('返回的不是脚本（缺少信息块）');
    }
    return body;
  }
}

class HubDownload {
  const HubDownload({required this.script, required this.url});

  final String script;
  final String url;
}
