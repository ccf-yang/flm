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
      };

  CustomSourceInfo copyWith({
    String? name,
    String? description,
    String? version,
    String? author,
    String? homepage,
    String? importUrl,
    bool? disabled,
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
    );
  }
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
