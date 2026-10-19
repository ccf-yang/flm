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
    this.debugEnabled = false,
  })  : searchHistory = searchHistory ?? <String>[],
        dislikedKeys = dislikedKeys ?? <String>[];

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
  /// Master switch for the request-recording debug page (off by default).
  bool debugEnabled;

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
      debugEnabled: json['debugEnabled'] == true,
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
        'debugEnabled': debugEnabled,
      };
}
