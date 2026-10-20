class CustomSourceInfo {
  const CustomSourceInfo({
    required this.id,
    required this.name,
    this.description = '',
    this.version = '',
    this.author = '',
    this.homepage = '',
    this.importUrl,
    this.createdAt = 0,
    this.disabled = false,
    this.group = sourceGroupManual,
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;
  final String? importUrl;
  final int createdAt;

  /// A probed-as-dead source can be switched off without deleting it: it stays
  /// importable/refreshable but is left out of playback and the cross-source
  /// pool, so a broken script no longer slows every song down.
  final bool disabled;

  /// Which section of the 自定义源 page owns this entry: a hand-imported script,
  /// the batch result of the in-app source search, or the batch result imported
  /// from the lx-hub web list. Only grouped entries are ever replaced wholesale.
  final String group;

  factory CustomSourceInfo.fromJson(Map<String, dynamic> json) {
    final importUrlRaw = json['importUrl'];
    final importUrl = importUrlRaw is String && importUrlRaw.trim().isNotEmpty
        ? importUrlRaw.trim()
        : null;
    return CustomSourceInfo(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名源'}',
      description: '${json['description'] ?? ''}',
      version: '${json['version'] ?? ''}',
      author: '${json['author'] ?? ''}',
      homepage: '${json['homepage'] ?? ''}',
      importUrl: importUrl,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      disabled: json['disabled'] == true,
      group: '${json['group'] ?? sourceGroupManual}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'version': version,
        'author': author,
        'homepage': homepage,
        if (importUrl != null && importUrl!.isNotEmpty) 'importUrl': importUrl,
        'createdAt': createdAt,
        if (disabled) 'disabled': true,
        if (group != sourceGroupManual) 'group': group,
      };

  CustomSourceInfo copyWith({
    String? name,
    String? description,
    String? version,
    String? author,
    String? homepage,
    String? importUrl,
    bool? disabled,
    String? group,
  }) {
    return CustomSourceInfo(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      version: version ?? this.version,
      author: author ?? this.author,
      homepage: homepage ?? this.homepage,
      importUrl: importUrl ?? this.importUrl,
      createdAt: createdAt,
      disabled: disabled ?? this.disabled,
      group: group ?? this.group,
    );
  }
}

/// Script imported by hand (本地/在线 URL) — never touched by a batch operation.
const String sourceGroupManual = '';

/// Result of the in-app source search (lx-hub 的搜索+沙箱实测方式).
const String sourceGroupAuto = 'auto';

/// Result of the lx-hub web list (每日实测的可用源).
const String sourceGroupWeb = 'web';

String sourceGroupName(String group) {
  switch (group) {
    case sourceGroupAuto:
      return '自动导入源';
    case sourceGroupWeb:
      return 'web探测导入源';
    default:
      return '自定义源';
  }
}

/// One script handed to a batch import: text plus the address it came from, so
/// 刷新 can re-download it later without remembering the hub index.
class SourceSeed {
  const SourceSeed({
    required this.script,
    this.importUrl,
    this.label = '',
    this.platforms = const <String>[],
  });

  final String script;
  final String? importUrl;
  final String label;
  final List<String> platforms;
}

class SourceCapabilities {
  SourceCapabilities(this.sources);

  final Map<String, Map<String, dynamic>> sources;

  factory SourceCapabilities.empty() => SourceCapabilities(<String, Map<String, dynamic>>{});

  factory SourceCapabilities.fromJson(Map<String, dynamic>? json) {
    if (json == null) return SourceCapabilities.empty();
    final result = <String, Map<String, dynamic>>{};
    json.forEach((key, value) {
      if (value is Map) {
        result[key] = Map<String, dynamic>.from(value);
      }
    });
    return SourceCapabilities(result);
  }

  bool supports(String source, String action) {
    final info = sources[source];
    if (info == null) return false;
    final actions = info['actions'];
    return actions is List && actions.contains(action);
  }

  List<String> qualitysFor(String source) {
    final info = sources[source];
    if (info == null) return const <String>[];
    final qualitys = info['qualitys'];
    if (qualitys is List) return qualitys.map((item) => '$item').toList();
    return const <String>[];
  }

  bool get isEmpty => sources.isEmpty;
}
