import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/song.dart';
import '../services/online_engine.dart';
import 'app_state.dart';

enum SearchType { music, songlist }

extension SearchTypeText on SearchType {
  String get label => this == SearchType.music ? '歌曲' : '歌单';
}

class SearchState extends ChangeNotifier {
  SearchState({
    required this.engine,
    required this.appState,
  }) : source = appState.settings.searchSource;

  final OnlineEngine engine;
  final AppState appState;

  SearchType type = SearchType.music;
  String source;
  String query = '';
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = false;
  int page = 0;
  String? error;
  List<Song> musicResults = <Song>[];
  List<Map<String, dynamic>> songlistResults = <Map<String, dynamic>>[];
  List<String> tips = <String>[];

  Timer? _tipTimer;
  int _searchToken = 0;

  void setType(SearchType next) {
    if (type == next) return;
    type = next;
    clear();
    notifyListeners();
  }

  Future<void> setSource(String next) async {
    if (source == next) return;
    source = next;
    appState.settings.searchSource = next;
    await appState.repository.save();
    clear();
    notifyListeners();
    if (query.trim().isNotEmpty) {
      await search(query);
    }
  }

  void clear() {
    query = '';
    musicResults = <Song>[];
    songlistResults = <Map<String, dynamic>>[];
    tips = <String>[];
    page = 0;
    hasMore = false;
    error = null;
    notifyListeners();
  }

  Future<void> search(String text) async {
    final keyword = text.trim();
    if (keyword.isEmpty) {
      clear();
      return;
    }
    query = keyword;
    appState.addSearchHistory(keyword);
    final token = ++_searchToken;
    loading = true;
    error = null;
    page = 1;
    hasMore = false;
    musicResults = <Song>[];
    songlistResults = <Map<String, dynamic>>[];
    notifyListeners();

    try {
      if (type == SearchType.music) {
        final result = await engine.call(
          'searchMusic',
          <String, dynamic>{
            'source': source,
            'keyword': keyword,
            'page': 1,
            'limit': 30,
          },
        );
        if (token != _searchToken) return;
        final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
        musicResults = _songsFrom(map['list']);
        final allPage = (map['allPage'] as num?)?.toInt() ?? 1;
        hasMore = allPage > 1 || musicResults.length >= 30;
      } else {
        final result = await engine.call(
          'searchSonglist',
          <String, dynamic>{
            'source': source,
            'keyword': keyword,
            'page': 1,
            'limit': 20,
          },
        );
        if (token != _searchToken) return;
        final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
        songlistResults = _mapsFrom(map['list']);
        final total = (map['total'] as num?)?.toInt() ?? 0;
        hasMore = songlistResults.length >= 20 && (total == 0 || total > 20);
      }
    } catch (e) {
      if (token != _searchToken) return;
      error = _cleanError(e);
    } finally {
      if (token == _searchToken) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore || query.trim().isEmpty) return;
    loadingMore = true;
    notifyListeners();
    final nextPage = page + 1;
    try {
      if (type == SearchType.music) {
        final result = await engine.call(
          'searchMusic',
          <String, dynamic>{
            'source': source,
            'keyword': query,
            'page': nextPage,
            'limit': 30,
          },
        );
        final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
        final incoming = _songsFrom(map['list']);
        final existing = musicResults.map((song) => '${song.source}:${song.id}').toSet();
        musicResults.addAll(incoming.where((song) => existing.add('${song.source}:${song.id}')));
        final allPage = (map['allPage'] as num?)?.toInt() ?? nextPage;
        hasMore = incoming.isNotEmpty && allPage > nextPage;
      } else {
        final result = await engine.call(
          'searchSonglist',
          <String, dynamic>{
            'source': source,
            'keyword': query,
            'page': nextPage,
            'limit': 20,
          },
        );
        final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
        final incoming = _mapsFrom(map['list']);
        final existing = songlistResults.map((item) => '${item['source']}:${item['id']}').toSet();
        songlistResults.addAll(
          incoming.where((item) => existing.add('${item['source']}:${item['id']}')),
        );
        final total = (map['total'] as num?)?.toInt() ?? 0;
        hasMore = incoming.isNotEmpty && (total == 0 || total > nextPage * 20);
      }
      page = nextPage;
    } catch (e) {
      error = _cleanError(e);
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }

  void updateTips(String text) {
    _tipTimer?.cancel();
    final keyword = text.trim();
    if (keyword.isEmpty) {
      tips = <String>[];
      notifyListeners();
      return;
    }
    _tipTimer = Timer(const Duration(milliseconds: 250), () async {
      try {
        final value = await engine.call('tipSearch', <String, dynamic>{'keyword': keyword});
        if (value is List) {
          tips = value.map((item) => '$item').toList();
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  List<Song> _songsFrom(dynamic value) {
    if (value is! List) return <Song>[];
    return value
        .whereType<Map>()
        .map((item) => Song.fromOnline(Map<String, dynamic>.from(item)))
        .where((song) => song.id.isNotEmpty)
        .toList();
  }

  List<Map<String, dynamic>> _mapsFrom(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  String _cleanError(Object error) {
    var message = error.toString();
    for (final prefix in <String>['Exception: ', 'StateError: ', 'Bad state: ']) {
      if (message.startsWith(prefix)) message = message.substring(prefix.length);
    }
    return message;
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    super.dispose();
  }
}
