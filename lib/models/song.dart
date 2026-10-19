class Song {
  const Song({
    required this.id,
    required this.name,
    this.singer = '',
    this.album = '',
    this.source = 'local',
    this.interval = '',
    this.picUrl = '',
    this.localPath,
    this.localCoverPath,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String singer;
  final String album;
  final String source;
  final String interval;
  final String picUrl;
  final String? localPath;
  final String? localCoverPath;
  final Map<String, dynamic> raw;

  bool get isLocal => source == 'local' && localPath != null;

  String get subtitle {
    final parts = <String>[];
    if (singer.trim().isNotEmpty) parts.add(singer.trim());
    if (album.trim().isNotEmpty) parts.add(album.trim());
    return parts.join(' · ');
  }

  String get displayTitle => name.trim().isEmpty ? '未知歌曲' : name.trim();

  String get displaySinger => singer.trim().isEmpty ? '未知艺术家' : singer.trim();

  Map<String, dynamic> get meta {
    final value = raw['meta'];
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  factory Song.fromOnline(Map<String, dynamic> json) {
    final meta = json['meta'] is Map
        ? Map<String, dynamic>.from(json['meta'] as Map)
        : <String, dynamic>{};
    return Song(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      singer: '${json['singer'] ?? ''}',
      album: '${meta['albumName'] ?? ''}',
      source: '${json['source'] ?? ''}',
      interval: '${json['interval'] ?? ''}',
      picUrl: '${meta['picUrl'] ?? ''}',
      raw: Map<String, dynamic>.from(json),
    );
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      singer: '${json['singer'] ?? ''}',
      album: '${json['album'] ?? ''}',
      source: '${json['source'] ?? 'local'}',
      interval: '${json['interval'] ?? ''}',
      picUrl: '${json['picUrl'] ?? ''}',
      localPath: json['localPath'] as String?,
      localCoverPath: json['localCoverPath'] as String?,
      raw: json['raw'] is Map
          ? Map<String, dynamic>.from(json['raw'] as Map)
          : <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'singer': singer,
        'album': album,
        'source': source,
        'interval': interval,
        'picUrl': picUrl,
        if (localPath != null) 'localPath': localPath,
        if (localCoverPath != null) 'localCoverPath': localCoverPath,
        'raw': raw,
      };

  Song copyWith({
    String? name,
    String? singer,
    String? album,
    String? interval,
    String? picUrl,
    String? localCoverPath,
  }) {
    return Song(
      id: id,
      name: name ?? this.name,
      singer: singer ?? this.singer,
      album: album ?? this.album,
      source: source,
      interval: interval ?? this.interval,
      picUrl: picUrl ?? this.picUrl,
      localPath: localPath,
      localCoverPath: localCoverPath ?? this.localCoverPath,
      raw: raw,
    );
  }

  /// The legacy music-info shape expected by LX user API scripts.
  Map<String, dynamic> toLegacyInfo() {
    final data = meta;
    final legacy = <String, dynamic>{
      'name': name,
      'singer': singer,
      'source': source,
      'songmid': '${data['songId'] ?? id}',
      'interval': interval,
      'albumName': album,
      'img': picUrl,
      'typeUrl': <String, dynamic>{},
    };

    if (source == 'local') {
      legacy['filePath'] = localPath ?? '';
      legacy['ext'] = '${data['ext'] ?? ''}';
      legacy['albumId'] = '';
      legacy['types'] = <dynamic>[];
      legacy['_types'] = <String, dynamic>{};
      return legacy;
    }

    legacy['albumId'] = data['albumId'];
    legacy['types'] = data['qualitys'] ?? <dynamic>[];
    legacy['_types'] = data['_qualitys'] ?? <String, dynamic>{};

    switch (source) {
      case 'kg':
        legacy['hash'] = data['hash'];
        break;
      case 'tx':
        legacy['strMediaMid'] = data['strMediaMid'];
        legacy['albumMid'] = data['albumMid'];
        legacy['songId'] = data['id'];
        break;
      case 'mg':
        legacy['copyrightId'] = data['copyrightId'];
        legacy['lrcUrl'] = data['lrcUrl'];
        legacy['mrcUrl'] = data['mrcUrl'];
        legacy['trcUrl'] = data['trcUrl'];
        break;
      default:
        break;
    }
    return legacy;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && other.source == source && other.id == id;

  @override
  int get hashCode => Object.hash(source, id);
}
