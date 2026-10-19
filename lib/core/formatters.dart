import 'dart:convert';

import 'package:crypto/crypto.dart';

String formatDuration(Duration duration) {
  if (duration.inMilliseconds <= 0) return '--:--';
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final minuteText = hours > 0 ? minutes.toString().padLeft(2, '0') : minutes.toString();
  if (hours > 0) {
    return '$hours:$minuteText:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minuteText:${seconds.toString().padLeft(2, '0')}';
}

String formatInterval(String interval) {
  if (interval.trim().isEmpty) return '--:--';
  final parts = interval.split(':');
  if (parts.length == 2) return interval;
  if (parts.length == 1) {
    final seconds = int.tryParse(parts.first);
    if (seconds == null) return interval;
    return formatDuration(Duration(seconds: seconds));
  }
  return interval;
}

String formatPlayCount(dynamic value) {
  final number = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  if (number <= 0) return '';
  if (number >= 100000000) {
    return '${(number / 100000000).toStringAsFixed(1)}亿';
  }
  if (number >= 10000) {
    return '${(number / 10000).toStringAsFixed(1)}万';
  }
  return '$number';
}

String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

String sanitizeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  return cleaned.isEmpty ? 'flm_backup' : cleaned;
}
