import '../models/lyric.dart';

class LyricParser {
  static final RegExp _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _wordTag = RegExp(r'<[^>]*>');

  static List<LyricLine> parse(String? lrc, {String? translation}) {
    if (lrc == null || lrc.trim().isEmpty) return const <LyricLine>[];
    final translations = _parseMap(translation);
    final result = <LyricLine>[];
    final seen = <int>{};

    for (final rawLine in lrc.split(RegExp(r'\r\n|\r|\n'))) {
      final matches = _timeTag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      var text = rawLine.replaceAll(_timeTag, '').replaceAll(_wordTag, '').trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        final time = _toDuration(match);
        final key = time.inMilliseconds;
        if (!seen.add(key)) continue;
        result.add(
          LyricLine(
            time: time,
            text: text,
            translation: translations[key] ?? '',
          ),
        );
      }
    }

    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  static Map<int, String> _parseMap(String? lrc) {
    if (lrc == null || lrc.trim().isEmpty) return const <int, String>{};
    final result = <int, String>{};
    for (final rawLine in lrc.split(RegExp(r'\r\n|\r|\n'))) {
      final matches = _timeTag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final text = rawLine.replaceAll(_timeTag, '').replaceAll(_wordTag, '').trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        result[_toDuration(match).inMilliseconds] = text;
      }
    }
    return result;
  }

  static Duration _toDuration(RegExpMatch match) {
    final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
    final fractionRaw = match.group(3) ?? '';
    var fraction = 0;
    if (fractionRaw.isNotEmpty) {
      switch (fractionRaw.length) {
        case 1:
          fraction = int.parse(fractionRaw) * 100;
          break;
        case 2:
          fraction = int.parse(fractionRaw) * 10;
          break;
        default:
          fraction = int.parse(fractionRaw.substring(0, 3));
          break;
      }
    }
    return Duration(
      milliseconds: minutes * 60 * 1000 + seconds * 1000 + fraction,
    );
  }

  static int activeIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    var low = 0;
    var high = lines.length - 1;
    var answer = -1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].time <= position) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return answer;
  }
}
