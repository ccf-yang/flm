import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../models/song.dart';
import '../kit.dart';
import 'cover_art.dart';

/// Short badge code for a song source id.
String srcShortLabel(String source) {
  switch (source) {
    case 'kw':
      return 'KW';
    case 'kg':
      return 'KG';
    case 'tx':
      return 'QQ';
    case 'wy':
      return 'NE';
    case 'mg':
      return 'MG';
    case 'local':
      return 'LC';
    default:
      return source.toUpperCase();
  }
}

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
    this.ranked = false,
    this.dragging = false,
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
  final bool ranked;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final subtitle = song.subtitle;
    final ordinal = index == null ? null : (ranked ? (index! + 1) : (index! + 1));
    final isTop = ranked && ordinal != null && ordinal <= 3;

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 7, 6, 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: active
              ? LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[accentSoftColor(context), Colors.transparent],
                  stops: const <double>[0, 0.82],
                )
              : null,
          color: active ? null : (selected ? accentSoftColor(context) : Colors.transparent),
        ),
        child: Row(
          children: <Widget>[
            // Selection check or ordinal number.
            SizedBox(
              width: 26,
              child: selectionMode
                  ? Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? accentFor(context) : Colors.transparent,
                        border: Border.all(
                          color: selected ? accentFor(context) : faintFor(context),
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? Icon(
                              CupertinoIcons.check_mark,
                              size: 12,
                              color: accentInkFor(context),
                            )
                          : null,
                    )
                  : (ordinal == null
                      ? const SizedBox.shrink()
                      : Text(
                          isTop
                              ? ordinal.toString().padLeft(2, '0')
                              : '$ordinal',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: isTop ? 15 : 10,
                            fontWeight: isTop ? FontWeight.w800 : FontWeight.w600,
                            letterSpacing: isTop ? -0.6 : 0,
                            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                            color: isTop || active
                                ? accentFor(context)
                                : faintFor(context),
                          ),
                        )),
            ),
            // Cover art (always visible).
            if (active)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentBorderColor(context)),
                ),
                child: CoverArt(song: song, size: 45, radius: 12),
              )
            else
              CoverArt(song: song, size: 45, radius: 12),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (active) ...<Widget>[
                        EqBars(height: 11, color: accentFor(context)),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          song.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.15,
                            color: active ? accentFor(context) : textFor(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: mutedFor(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 7),
            SrcBadge(srcShortLabel(song.source)),
            const SizedBox(width: 7),
            Text(
              formatInterval(song.interval),
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                color: faintFor(context),
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onMore != null)
              Pressable(
                onTap: onMore,
                child: Container(
                  width: 29,
                  height: 29,
                  margin: const EdgeInsets.only(left: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: dragging ? surfaceHighFor(context) : Colors.transparent,
                  ),
                  child: Icon(
                    CupertinoIcons.ellipsis,
                    size: 14,
                    color: faintFor(context),
                  ),
                ),
              )
            else
              const SizedBox(width: 33),
          ],
        ),
      ),
    );
  }
}
