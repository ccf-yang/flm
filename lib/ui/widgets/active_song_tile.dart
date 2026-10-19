import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../state/player_state.dart';
import 'song_tile.dart';

class ActiveSongTile extends StatelessWidget {
  const ActiveSongTile({
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
    this.ranked = false,
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
  final bool ranked;

  @override
  Widget build(BuildContext context) {
    final active = context.select<PlayerController, bool>(
      (player) => player.isCurrent(song),
    );
    return SongTile(
      song: song,
      index: index,
      onTap: onTap,
      onLongPress: onLongPress,
      onMore: onMore,
      trailing: trailing,
      showCover: showCover,
      selected: selected,
      selectionMode: selectionMode,
      active: active,
      ranked: ranked,
    );
  }
}
