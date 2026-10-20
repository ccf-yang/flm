import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/parsing.dart';
import '../models/song.dart';
import '../services/online_engine.dart';
import 'app_state.dart';

class DiscoverState extends ChangeNotifier {
  DiscoverState({
    required this.engine,
    required this.appState,
  })  : songlistSource = appState.settings.songlistSourceId(),
        leaderboardSource = appState.settings.leaderboardSourceId() {
    // 设置 → 音乐平台 decides which platforms stay as categories; reload the
    // affected lists when that changes under us.
    appState.addListener(_onSettingsChanged);
  }

  final OnlineEngine engine;
  final AppState appState;

  String songlistSource;
  String sortId = '';
  String tagId = '';
  String tagName = '';
  List<Map<String, dynamic>> sortOptions = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> tagOptions = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> songlists = <Map<String, dynamic>>[];
  int songlistPage = 0;
  bool songlistLoading = false;
  bool songlistLoadingMore = false;
  bool songlistHasMore = false;
  String? songlistError;

  String leaderboardSource;
  List<Map<String, dynamic>> boards = <Map<String, dynamic>>[];
  bool boardsLoading = false;
  String? boardsError;

  int _songlistToken = 0;
  bool _inited = false;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    await _loadSortsAndTags();
    await loadSonglists();
    await loadBoards();
  }

  void _onSettingsChanged() {
    if (!_inited) return;
    var changed = false;
    final list = appState.settings.songlistSourceId();
    if (list != songlistSource) {
      songlistSource = list;
      sortId = '';
      tagId = '';
      tagName = '';
      songlists = <Map<String, dynamic>>[];
      changed = true;
      unawaited(_loadSortsAndTags().then((_) => loadSonglists()));
    }
    final board = appState.settings.leaderboardSourceId();
    if (board != leaderboardSource) {
      leaderboardSource = board;
      changed = true;
      unawaited(loadBoards());
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    appState.removeListener(_onSettingsChanged);
    super.dispose();
  }

  Future<void> _loadSortsAndTags() async {
    try {
      final sortsValue = await engine.call('songlistSorts', <String, dynamic>{'source': songlistSource});
      final sortsMap = mapFromJson(sortsValue);
      sortOptions = mapsFromJson(sortsMap['list']);
      if (sortOptions.isNotEmpty && !sortOptions.any((item) => '${item['id']}' == sortId)) {
        sortId = '${sortOptions.first['id']}';
      }
      final tagsValue = await engine.call('songlistTags', <String, dynamic>{'source': songlistSource});
      final tagsMap = mapFromJson(tagsValue);
      final options = <Map<String, dynamic>>[
        <String, dynamic>{'id': '', 'name': '全部'},
      ];
      for (final item in mapsFromJson(tagsMap['hotTag'])) {
        options.add(<String, dynamic>{
          'id': '${item['id']}',
          'name': '${item['name']}',
          'group': '热门',
        });
      }
      final groups = mapsFromJson(tagsMap['tags']);
      for (final group in groups) {
        final groupName = '${group['name'] ?? ''}';
        for (final item in mapsFromJson(group['list'])) {
          options.add(<String, dynamic>{
            'id': '${item['id']}',
            'name': '${item['name']}',
            'group': groupName,
          });
        }
      }
      final seen = <String>{};
      tagOptions = options.where((item) => seen.add('${item['id']}')).toList();
      notifyListeners();
    } catch (_) {
      sortOptions = <Map<String, dynamic>>[];
      tagOptions = <Map<String, dynamic>>[
        <String, dynamic>{'id': '', 'name': '全部'},
      ];
      notifyListeners();
    }
  }

  Future<void> setSonglistSource(String source) async {
    if (songlistSource == source) return;
    songlistSource = source;
    appState.settings.songlistSource = source;
    await appState.repository.save();
    sortId = '';
    tagId = '';
    tagName = '';
    songlists = <Map<String, dynamic>>[];
    songlistPage = 0;
    songlistHasMore = false;
    notifyListeners();
    await _loadSortsAndTags();
    await loadSonglists();
  }

  Future<void> setSort(String id) async {
    if (sortId == id) return;
    sortId = id;
    await loadSonglists();
  }

  Future<void> setTag(String id, String name) async {
    if (tagId == id) return;
    tagId = id;
    tagName = name;
    await loadSonglists();
  }

  Future<void> loadSonglists() async {
    if (sortId.isEmpty && sortOptions.isNotEmpty) sortId = '${sortOptions.first['id']}';
    final token = ++_songlistToken;
    songlistLoading = true;
    songlistError = null;
    songlistPage = 1;
    songlistHasMore = false;
    songlists = <Map<String, dynamic>>[];
    notifyListeners();
    try {
      final value = await engine.call(
        'songlistList',
        <String, dynamic>{
          'source': songlistSource,
          'sortId': sortId,
          'tagId': tagId,
          'page': 1,
        },
      );
      if (token != _songlistToken) return;
      final map = mapFromJson(value);
      songlists = mapsFromJson(map['list']);
      final total = (map['total'] as num?)?.toInt() ?? 0;
      final limit = (map['limit'] as num?)?.toInt() ?? 36;
      songlistHasMore = songlists.isNotEmpty && (total == 0 ? songlists.length >= limit : total > limit);
    } catch (e) {
      if (token != _songlistToken) return;
      songlistError = cleanError(e);
    } finally {
      if (token == _songlistToken) {
        songlistLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreSonglists() async {
    if (songlistLoading || songlistLoadingMore || !songlistHasMore) return;
    songlistLoadingMore = true;
    notifyListeners();
    final nextPage = songlistPage + 1;
    try {
      final value = await engine.call(
        'songlistList',
        <String, dynamic>{
          'source': songlistSource,
          'sortId': sortId,
          'tagId': tagId,
          'page': nextPage,
        },
      );
      final map = mapFromJson(value);
      final incoming = mapsFromJson(map['list']);
      final existing = songlists.map((item) => '${item['source']}:${item['id']}').toSet();
      songlists.addAll(incoming.where((item) => existing.add('${item['source']}:${item['id']}')));
      final total = (map['total'] as num?)?.toInt() ?? 0;
      final limit = (map['limit'] as num?)?.toInt() ?? 36;
      songlistPage = nextPage;
      songlistHasMore = incoming.isNotEmpty && (total == 0 ? incoming.length >= limit : total > nextPage * limit);
    } catch (e) {
      songlistError = cleanError(e);
    } finally {
      songlistLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> loadBoards() async {
    boardsLoading = true;
    boardsError = null;
    notifyListeners();
    try {
      final value = await engine.call('leaderboards', <String, dynamic>{'source': leaderboardSource});
      final map = mapFromJson(value);
      boards = mapsFromJson(map['list']);
    } catch (e) {
      boardsError = cleanError(e);
      boards = <Map<String, dynamic>>[];
    } finally {
      boardsLoading = false;
      notifyListeners();
    }
  }

  Future<void> setLeaderboardSource(String source) async {
    if (leaderboardSource == source) return;
    leaderboardSource = source;
    appState.settings.leaderboardSource = source;
    await appState.repository.save();
    await loadBoards();
  }
}

class SonglistDetailState extends ChangeNotifier {
  SonglistDetailState({
    required this.engine,
    required this.source,
    required this.id,
    required this.title,
    this.coverUrl = '',
    this.description = '',
    this.playCount = '',
  });

  final OnlineEngine engine;
  final String source;
  final String id;
  String title;
  String coverUrl;
  String description;
  String playCount;

  List<Song> songs = <Song>[];
  Map<String, dynamic> info = <String, dynamic>{};
  int page = 0;
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = false;
  String? error;

  Future<void> load() async {
    loading = true;
    error = null;
    page = 1;
    songs = <Song>[];
    hasMore = false;
    notifyListeners();
    try {
      final value = await engine.call(
        'songlistDetail',
        <String, dynamic>{'source': source, 'id': id, 'page': 1},
      );
      final map = mapFromJson(value);
      songs = songsFromJson(map['list']);
      info = mapFromJson(map['info']);
      title = title.isEmpty ? '${info['name'] ?? '歌单'}' : title;
      coverUrl = coverUrl.isEmpty ? '${info['img'] ?? ''}' : coverUrl;
      description = description.isEmpty ? '${info['desc'] ?? ''}' : description;
      playCount = playCount.isEmpty ? '${info['play_count'] ?? ''}' : playCount;
      final total = (map['total'] as num?)?.toInt() ?? 0;
      final limit = (map['limit'] as num?)?.toInt() ?? songs.length;
      hasMore = songs.isNotEmpty && (total == 0 ? songs.length >= limit : total > songs.length);
    } catch (e) {
      error = cleanError(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore) return;
    loadingMore = true;
    notifyListeners();
    final nextPage = page + 1;
    try {
      final value = await engine.call(
        'songlistDetail',
        <String, dynamic>{'source': source, 'id': id, 'page': nextPage},
      );
      final map = mapFromJson(value);
      final incoming = songsFromJson(map['list']);
      final existing = songs.map((song) => '${song.source}:${song.id}').toSet();
      songs.addAll(incoming.where((song) => existing.add('${song.source}:${song.id}')));
      page = nextPage;
      final total = (map['total'] as num?)?.toInt() ?? 0;
      hasMore = incoming.isNotEmpty && (total == 0 ? incoming.length >= 30 : total > songs.length);
    } catch (e) {
      error = cleanError(e);
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }
}

class LeaderboardDetailState extends ChangeNotifier {
  LeaderboardDetailState({
    required this.engine,
    required this.source,
    required this.id,
    required this.title,
    this.coverUrl = '',
  });

  final OnlineEngine engine;
  final String source;
  final String id;
  String title;
  String coverUrl;

  List<Song> songs = <Song>[];
  int page = 0;
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = false;
  String? error;

  Future<void> load() async {
    loading = true;
    error = null;
    page = 1;
    songs = <Song>[];
    hasMore = false;
    notifyListeners();
    try {
      final value = await engine.call(
        'leaderboardDetail',
        <String, dynamic>{'source': source, 'id': id, 'page': 1},
      );
      final map = mapFromJson(value);
      songs = songsFromJson(map['list']);
      final total = (map['total'] as num?)?.toInt() ?? 0;
      final limit = (map['limit'] as num?)?.toInt() ?? songs.length;
      hasMore = songs.isNotEmpty && (total == 0 ? songs.length >= limit : total > songs.length);
    } catch (e) {
      error = cleanError(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore) return;
    loadingMore = true;
    notifyListeners();
    final nextPage = page + 1;
    try {
      final value = await engine.call(
        'leaderboardDetail',
        <String, dynamic>{'source': source, 'id': id, 'page': nextPage},
      );
      final map = mapFromJson(value);
      final incoming = songsFromJson(map['list']);
      final existing = songs.map((song) => '${song.source}:${song.id}').toSet();
      songs.addAll(incoming.where((song) => existing.add('${song.source}:${song.id}')));
      page = nextPage;
      final total = (map['total'] as num?)?.toInt() ?? 0;
      hasMore = incoming.isNotEmpty && (total == 0 ? incoming.length >= 30 : total > songs.length);
    } catch (e) {
      error = cleanError(e);
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }
}
