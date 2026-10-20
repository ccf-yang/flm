import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../kit.dart';
import '../widgets/song_tile.dart' show srcShortLabel;
import 'cover_image.dart';

class SonglistCard extends StatelessWidget {
  const SonglistCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = '${item['img'] ?? ''}';
    final name = '${item['name'] ?? '未命名歌单'}';
    final author = '${item['author'] ?? ''}';
    final playCount = formatPlayCount(item['play_count']);
    final source = '${item['source'] ?? ''}';

    return Pressable(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(19),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    GradientArt(
                      seed: '$source:${item['id'] ?? ''}:$name',
                      decorate: true,
                      showMark: true,
                      mark: srcShortLabel(source),
                    ),
                    if (image.isNotEmpty)
                      Positioned.fill(
                        child: CoverImage(url: image),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0x85040709),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
                        ),
                        child: Text(
                          srcShortLabel(source),
                          style: const TextStyle(
                            fontSize: 7,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            height: 1,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 1, right: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 8),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: textFor(context),
                  ),
                ),
                if (author.isNotEmpty || playCount.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    <String>[
                      if (author.isNotEmpty) author,
                      if (playCount.isNotEmpty) playCount,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9.5, color: faintFor(context)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
