import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show Color, HSVColor;

import '../models/song.dart';
import '../ui/widgets/cover_image.dart' show coverHeaders, secureCoverUrl;

/// Pulls a single representative colour out of a song's cover so the floating
/// pendant can match the artwork. Covers come from the same places the thumbnail
/// does — a cached local file or the CDN — and both are decoded to a tiny
/// thumbnail whose pixels are averaged, then saturation-boosted so the tint stays
/// readable on any background. Failures simply return null and the caller falls
/// back to the stored accent colour.
class CoverPalette {
  CoverPalette._();

  static final Map<String, Color> _cache = <String, Color>{};
  static final Map<String, bool> _failed = <String, bool>{};

  static final Dio _dio = Dio(
    BaseOptions(
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  static String _key(Song song) => '${song.source}:${song.id}';

  static Future<Color?> accent(Song song) async {
    final key = _key(song);
    if (_cache.containsKey(key)) return _cache[key];
    if (_failed[key] == true) return null;

    final bytes = await _bytesFor(song);
    if (bytes == null || bytes.isEmpty) {
      _failed[key] = true;
      return null;
    }
    final color = await _average(bytes);
    if (color == null) {
      _failed[key] = true;
      return null;
    }
    // Bound the cache so a long shuffle run cannot grow it without limit.
    if (_cache.length > 64) _cache.remove(_cache.keys.first);
    _cache[key] = color;
    return color;
  }

  static Future<Uint8List?> _bytesFor(Song song) async {
    try {
      final local = song.localCoverPath;
      if (local != null && local.isNotEmpty) {
        final file = File(local);
        if (await file.exists()) return await file.readAsBytes();
      }
      final link = secureCoverUrl(song.picUrl);
      if (link.isEmpty) return null;
      final response = await _dio.get<List<int>>(
        link,
        options: Options(headers: coverHeaders(link)),
      );
      final data = response.data;
      if (data == null) return null;
      return Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }

  static Future<Color?> _average(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 40,
        targetHeight: 40,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        image.dispose();
        return null;
      }
      final px = data.buffer.asUint8List();
      double r = 0, g = 0, b = 0;
      int n = 0;
      for (var i = 0; i + 3 < px.length; i += 4) {
        final a = px[i + 3];
        if (a < 200) continue;
        r += px[i];
        g += px[i + 1];
        b += px[i + 2];
        n += 1;
      }
      image.dispose();
      if (n == 0) return null;
      final hsv = HSVColor.fromColor(
        Color.fromARGB(255, (r / n).round(), (g / n).round(), (b / n).round()),
      );
      final boosted = hsv.withSaturation(
        math.min(1.0, hsv.saturation * 1.7 + 0.12),
      ).withValue(
        math.min(0.92, math.max(0.55, hsv.value * 1.05)),
      );
      return boosted.toColor();
    } catch (_) {
      return null;
    }
  }
}
