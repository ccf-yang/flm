import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/song.dart';

class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    this.song,
    this.size = 52,
    this.radius = 10,
  });

  final Song? song;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final current = song;
    Widget image = _placeholder(context);
    if (current != null) {
      final localCover = current.localCoverPath;
      if (localCover != null && localCover.isNotEmpty) {
        image = Image.file(
          File(localCover),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(context),
        );
      } else if (current.picUrl.isNotEmpty) {
        image = Image.network(
          current.picUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(context),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _placeholder(context);
          },
        );
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: image,
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const <Color>[Color(0xFF17324A), Color(0xFF0F2233)]
              : const <Color>[Color(0xFFD9F5EF), Color(0xFFEAF7F4)],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.42,
        color: isDark ? AppColors.accentSoft : AppColors.accent,
      ),
    );
  }
}
