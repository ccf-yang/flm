import 'song.dart';

class Playlist {
  Playlist({
    required this.id,
    required this.name,
    List<Song>? songs,
    this.isBuiltIn = false,
    this.source,
    this.sourceListId,
  }) : songs = songs ?? <Song>[];

  final String id;
  String name;
  final List<Song> songs;
  final bool isBuiltIn;
  final String? source;
  final String? sourceListId;

  bool get canDelete => !isBuiltIn;

  factory Playlist.defaultList() => Playlist(
        id: 'default',
        name: '试听列表',
        isBuiltIn: true,
      );

  factory Playlist.loveList() => Playlist(
        id: 'love',
        name: '我的收藏',
        isBuiltIn: true,
      );

  factory Playlist.localList() => Playlist(
        id: 'local',
        name: '本地音乐',
        isBuiltIn: true,
      );

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名列表'}',
      songs: (json['songs'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map>()
          .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      isBuiltIn: json['isBuiltIn'] == true,
      source: json['source'] as String?,
      sourceListId: json['sourceListId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'songs': songs.map((song) => song.toJson()).toList(),
        'isBuiltIn': isBuiltIn,
        if (source != null) 'source': source,
        if (sourceListId != null) 'sourceListId': sourceListId,
      };

  bool contains(Song song) => songs.any((item) => item.id == song.id && item.source == song.source);

  bool containsId(String id) => songs.any((item) => item.id == id);

  void add(Song song, {bool toTop = false}) {
    if (contains(song)) return;
    if (toTop) {
      songs.insert(0, song);
    } else {
      songs.add(song);
    }
  }

  void addAll(Iterable<Song> items, {bool toTop = false}) {
    final existing = songs.map((item) => '${item.source}:${item.id}').toSet();
    final incoming = items
        .where((item) => existing.add('${item.source}:${item.id}'))
        .toList();
    if (incoming.isEmpty) return;
    if (toTop) {
      songs.insertAll(0, incoming);
    } else {
      songs.addAll(incoming);
    }
  }

  void removeIds(Set<String> ids) {
    songs.removeWhere((song) => ids.contains(song.id));
  }

  int indexOf(Song song) => songs.indexWhere(
        (item) => item.id == song.id && item.source == song.source,
      );
}
