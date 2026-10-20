import 'song.dart';

enum PlayMode { listLoop, random, sequence, singleLoop }

extension PlayModeText on PlayMode {
  String get label {
    switch (this) {
      case PlayMode.listLoop:
        return '列表循环';
      case PlayMode.random:
        return '随机播放';
      case PlayMode.sequence:
        return '顺序播放';
      case PlayMode.singleLoop:
        return '单曲循环';
    }
  }
}

class AppSettings {
  /// Every platform the filter rows can offer, in display order. `all` is the
  /// aggregate search, the rest are per-platform sources.
  static const List<String> kPlatformIds = <String>[
    'all',
    'kw',
    'kg',
    'tx',
    'wy',
    'mg',
  ];

  /// Presets for the floating pendant's accent colour, id to ARGB value.
  static const Map<String, int> kMiniPlayerColors = <String, int>{
    'mint': 0xFF9AF4D2,
    'coral': 0xFFFF8F7A,
    'gold': 0xFFF2D08C,
    'sky': 0xFF7EC8FF,
    'violet': 0xFFC7A6FF,
    'snow': 0xFFF3F6F4,
  };

  /// The pendant's accent colour value; falls back to mint for unknown ids.
  static int miniPlayerColorValue(String id) =>
      kMiniPlayerColors[id] ?? kMiniPlayerColors['mint']!;

  AppSettings({
    this.themeMode = 'system',
    this.quality = '320k',
    this.playMode = PlayMode.listLoop,
    this.volume = 1.0,
    this.speed = 1.0,
    this.saveProgress = true,
    this.autoPlayOnStart = false,
    this.showTranslation = true,
    this.activeSourceId,
    List<String>? searchHistory,
    List<String>? dislikedKeys,
    this.lastSongJson,
    this.lastPositionMs = 0,
    this.lastQueueJson,
    this.lastQueueIndex = 0,
    this.searchSource = 'all',
    this.songlistSource = 'kw',
    this.leaderboardSource = 'kw',
    this.miniPlayerX = -1,
    this.miniPlayerY = -1,
    this.miniPlayerOpacity = 0.95,
    this.miniPlayerShape = 'circle',
    this.miniPlayerColor = 'mint',
    this.miniPlayerUseImageColor = true,
    this.debugEnabled = false,
    this.showPlatformFilter = true,
    List<String>? visibleSources,
  })  : searchHistory = searchHistory ?? <String>[],
        dislikedKeys = dislikedKeys ?? <String>[],
        visibleSources = visibleSources ?? List<String>.from(kPlatformIds);

  String themeMode;
  String quality;
  PlayMode playMode;
  double volume;
  double speed;
  bool saveProgress;
  bool autoPlayOnStart;
  bool showTranslation;
  String? activeSourceId;
  List<String> searchHistory;
  List<String> dislikedKeys;
  Map<String, dynamic>? lastSongJson;
  int lastPositionMs;
  List<Map<String, dynamic>>? lastQueueJson;
  int lastQueueIndex;
  String searchSource;
  String songlistSource;
  String leaderboardSource;
  /// Draggable mini-player position, stored as a fraction (0..1) of the
  /// usable area. Negative means "not set yet" (use the default corner).
  double miniPlayerX;
  double miniPlayerY;
  /// Floating pendant style: overall opacity (0.3..1), silhouette shape, and
  /// accent colour id (see [kMiniPlayerColors]).
  double miniPlayerOpacity;
  String miniPlayerShape;
  String miniPlayerColor;
  /// When true the pendant takes its accent from the current cover's dominant
  /// colour; when false it always uses [miniPlayerColor].
  bool miniPlayerUseImageColor;
  /// Master switch for the request-recording debug page (off by default).
  bool debugEnabled;
  /// Whether 搜索 / 歌单 / 榜单 show the platform filter row at all.
  bool showPlatformFilter;
  /// Platforms the user keeps as categories; order follows [kPlatformIds].
  List<String> visibleSources;

  /// The platform ids that take part in categorisation, always at least one.
  List<String> get platformIds {
    final kept = visibleSources.where(kPlatformIds.contains).toList();
    return kept.isEmpty ? List<String>.from(kPlatformIds) : kept;
  }

  /// Ids the filter rows may render; empty means the rows are hidden.
  List<String> visiblePlatformIds({bool allowAggregate = true}) {
    if (!showPlatformFilter) return const <String>[];
    return platformIds.where((id) => allowAggregate || id != 'all').toList();
  }

  /// First platform that is not the aggregate entry.
  String get _firstRealPlatform {
    for (final id in platformIds) {
      if (id != 'all') return id;
    }
    return 'kw';
  }

  /// What the search tab actually queries. Without the filter row the user
  /// asked for no platform categorisation, so search aggregates every source.
  String searchSourceId() {
    if (!showPlatformFilter) return platformIds.contains('all') ? 'all' : _firstRealPlatform;
    return platformIds.contains(searchSource) ? searchSource : _firstRealPlatform;
  }

  /// Songlists and leaderboards only exist per platform, so `all` is never a
  /// valid answer and the first kept platform takes over when needed.
  String songlistSourceId() => _realPlatform(songlistSource);
  String leaderboardSourceId() => _realPlatform(leaderboardSource);

  String _realPlatform(String stored) {
    final usable = stored.isNotEmpty && stored != 'all';
    if (showPlatformFilter) {
      return usable && platformIds.contains(stored) ? stored : _firstRealPlatform;
    }
    return usable && kPlatformIds.contains(stored) ? stored : _firstRealPlatform;
  }

  Song? get lastSong {
    final json = lastSongJson;
    if (json == null || json.isEmpty) return null;
    try {
      return Song.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  List<Song> get lastQueue {
    final rows = lastQueueJson;
    if (rows == null || rows.isEmpty) return const <Song>[];
    final songs = <Song>[];
    for (final row in rows) {
      try {
        final song = Song.fromJson(row);
        if (song.id.isNotEmpty) songs.add(song);
      } catch (_) {
        continue;
      }
    }
    return songs;
  }

  static String dislikeKeyFor(Song song) =>
      '${song.name.trim().toLowerCase()}@${song.singer.trim().toLowerCase()}';

  bool isDisliked(Song song) => dislikedKeys.contains(dislikeKeyFor(song));

  void dislike(Song song) {
    final key = dislikeKeyFor(song);
    if (!dislikedKeys.contains(key)) dislikedKeys.add(key);
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      themeMode: '${json['themeMode'] ?? 'system'}',
      quality: '${json['quality'] ?? '320k'}',
      playMode: PlayMode.values.firstWhere(
        (mode) => mode.name == json['playMode'],
        orElse: () => PlayMode.listLoop,
      ),
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
      saveProgress: json['saveProgress'] != false,
      autoPlayOnStart: json['autoPlayOnStart'] == true,
      showTranslation: json['showTranslation'] != false,
      activeSourceId: json['activeSourceId'] as String?,
      searchHistory: (json['searchHistory'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => '$item')
          .toList(),
      dislikedKeys: (json['dislikedKeys'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => '$item')
          .toList(),
      lastSongJson: json['lastSongJson'] is Map
          ? Map<String, dynamic>.from(json['lastSongJson'] as Map)
          : null,
      lastPositionMs: (json['lastPositionMs'] as num?)?.toInt() ?? 0,
      lastQueueJson: (json['lastQueueJson'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
      lastQueueIndex: (json['lastQueueIndex'] as num?)?.toInt() ?? 0,
      searchSource: '${json['searchSource'] ?? 'all'}',
      songlistSource: '${json['songlistSource'] ?? 'kw'}',
      leaderboardSource: '${json['leaderboardSource'] ?? 'kw'}',
      miniPlayerX: (json['miniPlayerX'] as num?)?.toDouble() ?? -1,
      miniPlayerY: (json['miniPlayerY'] as num?)?.toDouble() ?? -1,
      miniPlayerOpacity:
          (json['miniPlayerOpacity'] as num?)?.toDouble() ?? 0.95,
      miniPlayerShape: '${json['miniPlayerShape'] ?? 'circle'}',
      miniPlayerColor: '${json['miniPlayerColor'] ?? 'mint'}',
      miniPlayerUseImageColor: json['miniPlayerUseImageColor'] != false,
      debugEnabled: json['debugEnabled'] == true,
      showPlatformFilter: json['showPlatformFilter'] != false,
      visibleSources: (json['visibleSources'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => '$item')
          .where(kPlatformIds.contains)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'themeMode': themeMode,
        'quality': quality,
        'playMode': playMode.name,
        'volume': volume,
        'speed': speed,
        'saveProgress': saveProgress,
        'autoPlayOnStart': autoPlayOnStart,
        'showTranslation': showTranslation,
        'activeSourceId': activeSourceId,
        'searchHistory': searchHistory,
        'dislikedKeys': dislikedKeys,
        'lastSongJson': lastSongJson,
        'lastPositionMs': lastPositionMs,
        'lastQueueJson': lastQueueJson,
        'lastQueueIndex': lastQueueIndex,
        'searchSource': searchSource,
        'songlistSource': songlistSource,
        'leaderboardSource': leaderboardSource,
        'miniPlayerX': miniPlayerX,
        'miniPlayerY': miniPlayerY,
        'miniPlayerOpacity': miniPlayerOpacity,
        'miniPlayerShape': miniPlayerShape,
        'miniPlayerColor': miniPlayerColor,
        'miniPlayerUseImageColor': miniPlayerUseImageColor,
        'debugEnabled': debugEnabled,
        'showPlatformFilter': showPlatformFilter,
        'visibleSources': visibleSources,
      };
}
