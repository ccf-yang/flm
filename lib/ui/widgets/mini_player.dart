import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../state/player_state.dart';
import '../screens/player_screen.dart';
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
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      child: Container(
        decoration: BoxDecoration(
          color: surfaceFor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PlayerScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 7),
                  child: Row(
                    children: <Widget>[
                      CoverArt(song: song, size: 44, radius: 9),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              song.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: textFor(context),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: player.errorText != null
                                    ? AppColors.danger
                                    : mutedFor(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          player.togglePlay();
                        },
                        visualDensity: VisualDensity.compact,
                        icon: player.loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                player.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 30,
                                color: textFor(context),
                              ),
                      ),
                      IconButton(
                        onPressed: () {
                          player.next();
                        },
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.skip_next_rounded,
                          size: 26,
                          color: mutedFor(context),
                        ),
                      ),
                      const SizedBox(width: 2),
                    ],
                  ),
                ),
              ),
              LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: AppColors.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String miniPlayerTime(PlayerController player) {
  return '${formatDuration(player.position)} / ${formatDuration(player.duration)}';
}
