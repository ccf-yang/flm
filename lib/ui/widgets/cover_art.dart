import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../kit.dart';
import 'cover_image.dart';

class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    this.song,
    this.size = 52,
    this.radius = 10,
    this.showMark = false,
  });

  final Song? song;
  final double size;
  final double radius;
  final bool showMark;

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
        image = CoverImage(
          url: current.picUrl,
          width: size,
          height: size,
          placeholder: _placeholder,
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
    final seed = song == null
        ? 'flm-empty'
        : '${song!.source}:${song!.id}:${song!.name}';
    return GradientArt(
      seed: seed,
      radius: radius,
      width: size,
      height: size,
      decorate: true,
      showMark: showMark,
      mark: song?.source ?? '',
    );
  }
}
