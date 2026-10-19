import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../state/player_state.dart';
import '../screens/player_screen.dart';
import '../kit.dart';
import 'cover_art.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();

    final durationMs = player.duration.inMilliseconds;
    final progress = durationMs > 0
        ? (player.position.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final lyric = player.activeLine >= 0 && player.activeLine < player.lyrics.length
        ? player.lyrics[player.activeLine].displayText
        : '';
    final subtitle = lyric.isNotEmpty ? lyric : song.subtitle;
    final status = player.loading
        ? '正在获取播放链接…'
        : player.errorText ?? player.statusText ?? subtitle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 2, 11, 8),
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: surfaceFor(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: lineColor(context)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: auroraIsDark(context) ? 0.22 : 0.10),
              blurRadius: 34,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: <Widget>[
            Row(
              children: <Widget>[
                // Tap to open the player page.
                Pressable(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PlayerScreen(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(7, 8, 0, 8),
                    child: Row(
                      children: <Widget>[
                        CoverArt(song: song, size: 46, radius: 12),
                        const SizedBox(width: 10),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 190),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                song.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.15,
                                  color: textFor(context),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: player.errorText != null
                                      ? coralFor(context)
                                      : mutedFor(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                // Play / pause.
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: _MiniBtn(
                    main: true,
                    onTap: player.togglePlay,
                    child: player.loading
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: textFor(context),
                            ),
                          )
                        : Icon(
                            player.isPlaying
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            size: 17,
                            color: textFor(context),
                          ),
                  ),
                ),
                // Next.
                Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: _MiniBtn(
                    onTap: player.next,
                    child: Icon(
                      CupertinoIcons.forward_fill,
                      size: 15,
                      color: mutedFor(context),
                    ),
                  ),
                ),
              ],
            ),
            // Progress line along the bottom edge.
            Positioned(
              left: 13,
              right: 13,
              bottom: 0,
              height: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(color: lineColor(context)),
                    ),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: progress,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: accentFor(context),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn({
    required this.child,
    this.onTap,
    this.main = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool main;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: main ? surface2For(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Center(child: child),
      ),
    );
  }
}

String miniPlayerTime(PlayerController player) {
  return '${formatDuration(player.position)} / ${formatDuration(player.duration)}';
}
