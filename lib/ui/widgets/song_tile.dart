import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../models/song.dart';
import 'cover_art.dart';

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    this.index,
    this.onTap,
    this.onLongPress,
    this.onMore,
    this.trailing,
    this.showCover = false,
    this.selected = false,
    this.selectionMode = false,
    this.active = false,
  });

  final Song song;
  final int? index;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMore;
  final Widget? trailing;
  final bool showCover;
  final bool selected;
  final bool selectionMode;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = active
        ? AppColors.accent
        : isDark
            ? Colors.white
            : const Color(0xFF111827);
    final subtitle = song.subtitle;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        color: selected ? AppColors.accent.withValues(alpha: 0.08) : Colors.transparent,
        child: Row(
          children: <Widget>[
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? AppColors.accent : mutedFor(context),
                  size: 22,
                ),
              )
            else if (showCover)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: CoverArt(song: song, size: 46, radius: 8),
              )
            else if (index != null)
              SizedBox(
                width: 30,
                child: Text(
                  '${index! + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: active ? AppColors.accent : mutedFor(context),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: mutedFor(context)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (trailing != null)
              trailing!
            else ...<Widget>[
              Text(
                formatInterval(song.interval),
                style: TextStyle(fontSize: 12, color: mutedFor(context)),
              ),
              if (onMore != null)
                IconButton(
                  onPressed: onMore,
                  icon: Icon(Icons.more_horiz_rounded, color: mutedFor(context)),
                  visualDensity: VisualDensity.compact,
                )
              else
                const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}
