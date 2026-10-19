import '../models/song.dart';

List<Song> songsFromJson(dynamic value) {
  if (value is! List) return <Song>[];
  return value
      .whereType<Map>()
      .map((item) => Song.fromOnline(Map<String, dynamic>.from(item)))
      .where((song) => song.id.isNotEmpty)
      .toList();
}

List<Map<String, dynamic>> mapsFromJson(dynamic value) {
  if (value is! List) return <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}

Map<String, dynamic> mapFromJson(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

String cleanError(Object error) {
  var message = error.toString();
  for (final prefix in <String>['Exception: ', 'StateError: ', 'Bad state: ']) {
    if (message.startsWith(prefix)) message = message.substring(prefix.length);
  }
  return message;
}
