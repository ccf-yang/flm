import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';

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

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (image.isNotEmpty)
                    Image.network(
                      image,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder(context),
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return _placeholder(context);
                      },
                    )
                  else
                    _placeholder(context),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${item['source'] ?? ''}'.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: textFor(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            <String>[
              if (author.isNotEmpty) author,
              if (playCount.isNotEmpty) playCount,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: mutedFor(context)),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
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
        Icons.queue_music_rounded,
        size: 34,
        color: isDark ? AppColors.accentSoft : AppColors.accent,
      ),
    );
  }
}
