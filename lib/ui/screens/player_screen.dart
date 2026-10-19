import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../models/app_settings.dart';
import '../../models/song.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../widgets/cover_art.dart';
import '../widgets/empty_state.dart';
import '../widgets/lyric_view.dart';
import '../widgets/song_actions_sheet.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final library = context.watch<LibraryState>();
    final song = player.current;

    return Scaffold(
      appBar: AppBar(
        title: const Text('正在播放'),
        actions: <Widget>[
          IconButton(
            tooltip: '播放队列',
            onPressed: () => _showQueueSheet(context),
            icon: const Icon(Icons.queue_music_rounded),
          ),
          IconButton(
            tooltip: '更多',
            onPressed: () => _showPlaybackOptions(context),
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: song == null
          ? const EmptyState(
              title: '还没有播放歌曲',
              message: '去搜索一首歌，或从「我的」里选择列表播放',
              icon: Icons.headphones_rounded,
            )
          : SafeArea(
              top: false,
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: (value) => setState(() => _page = value),
                      children: <Widget>[
                        _CoverPage(player: player, song: song),
                        LyricView(
                          lines: player.lyrics,
                          activeLine: player.activeLine,
                          onSeek: (position) {
                            player.seek(position);
                          },
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _dot(0),
                      const SizedBox(width: 6),
                      _dot(1),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _ProgressBar(player: player),
                  _Controls(
                    player: player,
                    song: song,
                    loved: library.isLoved(song),
                    onFavorite: () {
                      final loved = library.toggleLove(song);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(loved ? '已收藏' : '已取消收藏')),
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 18),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        _BottomAction(
                          icon: Icons.timer_outlined,
                          label: player.sleepRemaining == null
                              ? '定时'
                              : formatDuration(player.sleepRemaining!),
                          onTap: () => _showSleepSheet(context),
                        ),
                        _BottomAction(
                          icon: Icons.volume_up_rounded,
                          label: '音量',
                          onTap: () => _showPlaybackOptions(context),
                        ),
                        _BottomAction(
                          icon: Icons.queue_music_rounded,
                          label: '队列',
                          onTap: () => _showQueueSheet(context),
                        ),
                        _BottomAction(
                          icon: Icons.info_outline_rounded,
                          label: '详情',
                          onTap: () => showSongActions(context, song),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _dot(int index) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: index == _page ? 18 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: index == _page ? AppColors.accent : mutedFor(context).withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _CoverPage extends StatelessWidget {
  const _CoverPage({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = min(constraints.maxWidth * 0.78, constraints.maxHeight * 0.62);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              CoverArt(song: song, size: size, radius: 22),
              const SizedBox(height: 24),
              Text(
                song.displayTitle,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: textFor(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                song.displaySinger,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: mutedFor(context)),
              ),
              if (song.album.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  song.album,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: mutedFor(context)),
                ),
              ],
              if (player.errorText != null) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    player.errorText!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: AppColors.danger),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final maxMs = player.duration.inMilliseconds;
    final value = maxMs <= 0
        ? 0.0
        : (player.position.inMilliseconds / maxMs).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: <Widget>[
          Slider(
            value: value,
            onChanged: maxMs <= 0
                ? null
                : (next) {
                    player.seek(Duration(milliseconds: (next * maxMs).round()));
                  },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  formatDuration(player.position),
                  style: TextStyle(fontSize: 11, color: mutedFor(context)),
                ),
                Text(
                  formatDuration(player.duration),
                  style: TextStyle(fontSize: 11, color: mutedFor(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.song,
    required this.loved,
    required this.onFavorite,
  });

  final PlayerController player;
  final Song song;
  final bool loved;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          IconButton(
            tooltip: player.playMode.label,
            onPressed: () {
              const modes = PlayMode.values;
              final next = modes[(player.playMode.index + 1) % modes.length];
              player.setPlayMode(next);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(next.label)),
              );
            },
            icon: Icon(_modeIcon(player.playMode), color: mutedFor(context)),
          ),
          IconButton(
            onPressed: () {
              player.previous();
            },
            icon: Icon(Icons.skip_previous_rounded, size: 38, color: textFor(context)),
          ),
          GestureDetector(
            onTap: () {
              player.togglePlay();
            },
            child: Container(
              width: 74,
              height: 74,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: player.loading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(
                      player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 42,
                      color: Colors.white,
                    ),
            ),
          ),
          IconButton(
            onPressed: () {
              player.next();
            },
            icon: Icon(Icons.skip_next_rounded, size: 38, color: textFor(context)),
          ),
          IconButton(
            onPressed: onFavorite,
            icon: Icon(
              loved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: loved ? AppColors.accent : mutedFor(context),
            ),
          ),
        ],
      ),
    );
  }

  IconData _modeIcon(PlayMode mode) {
    switch (mode) {
      case PlayMode.listLoop:
        return Icons.repeat_rounded;
      case PlayMode.random:
        return Icons.shuffle_rounded;
      case PlayMode.sequence:
        return Icons.format_list_numbered_rounded;
      case PlayMode.singleLoop:
        return Icons.repeat_one_rounded;
    }
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 21, color: mutedFor(context)),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 10.5, color: mutedFor(context))),
          ],
        ),
      ),
    );
  }
}

void _showQueueSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return Consumer<PlayerController>(
            builder: (context, player, _) {
              return Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Row(
                      children: <Widget>[
                        Text(
                          '播放队列',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: textFor(context),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${player.queue.length} 首',
                          style: TextStyle(fontSize: 12, color: mutedFor(context)),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: player.queue.isEmpty
                        ? const EmptyState(title: '播放队列是空的', icon: Icons.queue_music_rounded)
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: player.queue.length,
                            itemBuilder: (context, index) {
                              final song = player.queue[index];
                              final active = player.index == index;
                              return ListTile(
                                onTap: () {
                                  player.jumpToQueueIndex(index);
                                  Navigator.pop(sheetContext);
                                },
                                leading: SizedBox(
                                  width: 26,
                                  child: Text(
                                    '${index + 1}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: active ? AppColors.accent : mutedFor(context),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  song.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                                    color: active ? AppColors.accent : textFor(context),
                                  ),
                                ),
                                subtitle: Text(
                                  song.displaySinger,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  onPressed: () => player.removeFromQueue(song),
                                  icon: Icon(Icons.close_rounded, size: 18, color: mutedFor(context)),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      );
    },
  );
}

void _showSleepSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return Consumer<PlayerController>(
        builder: (context, player, _) {
          final remaining = player.sleepRemaining;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      remaining == null ? '定时停止播放' : '剩余 ${formatDuration(remaining)}',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: textFor(context),
                      ),
                    ),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <int>[15, 30, 45, 60, 90].map((minutes) {
                    return ActionChip(
                      label: Text('$minutes 分钟'),
                      onPressed: () {
                        player.setSleepTimer(Duration(minutes: minutes));
                        Navigator.pop(sheetContext);
                      },
                    );
                  }).toList(),
                ),
                ListTile(
                  leading: const Icon(Icons.timer_off_rounded),
                  title: const Text('关闭定时'),
                  onTap: () {
                    player.setSleepTimer(null);
                    Navigator.pop(sheetContext);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    },
  );
}

void _showPlaybackOptions(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return Consumer<PlayerController>(
        builder: (context, player, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '播放设置',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: textFor(context),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.volume_up_rounded, size: 20),
                      Expanded(
                        child: Slider(
                          value: player.appState.settings.volume,
                          onChanged: (value) => player.setVolume(value),
                        ),
                      ),
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${(player.appState.settings.volume * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 12, color: mutedFor(context)),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.speed_rounded, size: 20),
                      Expanded(
                        child: Slider(
                          value: player.appState.settings.speed.clamp(0.5, 2.0).toDouble(),
                          min: 0.5,
                          max: 2.0,
                          divisions: 12,
                          onChanged: (value) {
                            player.setSpeed(double.parse(value.toStringAsFixed(2)));
                          },
                        ),
                      ),
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${player.appState.settings.speed.toStringAsFixed(2)}x',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 12, color: mutedFor(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '提示：播放速度会同时影响歌词滚动。',
                    style: TextStyle(fontSize: 12, color: mutedFor(context)),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
