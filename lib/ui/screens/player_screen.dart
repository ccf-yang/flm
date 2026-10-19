import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../models/app_settings.dart';
import '../../models/song.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import '../widgets/cover_art.dart';
import '../widgets/empty_state.dart';
import '../widgets/lyric_view.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_tile.dart' show srcShortLabel;

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
    final isDark = auroraIsDark(context);

    return Scaffold(
      backgroundColor: const Color(0xFF06080A),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (song != null)
            Positioned.fill(
              child: Opacity(
                opacity: isDark ? 0.52 : 0.30,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
                  child: Transform.scale(
                    scale: 1.4,
                    child: CoverArt(song: song, size: 420, radius: 0),
                  ),
                ),
              ),
            ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x29040608),
                      Color(0x80040608),
                      Color(0xCC040608),
                    ],
                    stops: <double>[0, 0.64, 1],
                  ),
                ),
              ),
            ),
          ),
          if (song == null)
            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        CupertinoIcons.music_note,
                        size: 34,
                        color: Color(0x99FFFFFF),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '还没有播放歌曲',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '去搜索一首歌，或从「我的」里选择列表播放',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Color(0x80FFFFFF)),
                      ),
                      const SizedBox(height: 18),
                      AuroraButton(
                        label: '返回',
                        secondary: true,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(21, 8, 21, 20),
                child: Column(
                  children: <Widget>[
                    _PlayerTop(player: player, song: song),
                    Expanded(
                      child: PageView(
                        controller: _pageController,
                        onPageChanged: (value) => setState(() => _page = value),
                        children: <Widget>[
                          _CoverPage(player: player, song: song),
                          LyricView(
                            lines: player.lyrics,
                            activeLine: player.activeLine,
                            onSeek: player.seek,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        _pageDot(0),
                        const SizedBox(width: 6),
                        _pageDot(1),
                      ],
                    ),
                    _TrackInfo(
                      song: song,
                      loved: library.isLoved(song),
                      onFavorite: () {
                        final loved = library.toggleLove(song);
                        flmToast(context, loved ? '已收藏到「我喜欢」' : '已取消收藏');
                      },
                    ),
                    _SeekBar(player: player),
                    _Controls(player: player, song: song),
                    const SizedBox(height: 7),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        _PAction(
                          icon: CupertinoIcons.timer,
                          label: player.sleepRemaining == null
                              ? '定时'
                              : formatDuration(player.sleepRemaining!),
                          onTap: () => _showSleepSheet(context),
                        ),
                        _PAction(
                          icon: CupertinoIcons.slider_horizontal_3,
                          label: '音量',
                          onTap: () => _showPlaybackSheet(context),
                        ),
                        _PAction(
                          icon: CupertinoIcons.music_note_list,
                          label: '队列',
                          onTap: () => _showQueueSheet(context),
                        ),
                        _PAction(
                          icon: CupertinoIcons.text_quote,
                          label: '详情',
                          onTap: () => showSongActions(context, song),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pageDot(int index) {
    final active = index == _page;
    return GestureDetector(
      onTap: () {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: AuroraMotion.ease,
        width: active ? 17 : 5,
        height: 5,
        decoration: BoxDecoration(
          color: active ? AppColors.accentDark : const Color(0x38FFFFFF),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _PlayerTop extends StatelessWidget {
  const _PlayerTop({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    final appState = player.appState;
    final quality = appState.settings.quality;
    final qualityLabel = switch (quality) {
      '128k' => '标准',
      '320k' => '高清',
      'flac' => '无损',
      _ => quality,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          _GlassIconBtn(
            icon: CupertinoIcons.chevron_down,
            onTap: () => Navigator.of(context).maybePop(),
            tooltip: '收起播放器',
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                const Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    fontSize: 7.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.28,
                    color: Color(0x61FFFFFF),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Container(
                      width: 4,
                      height: 4,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentDark,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${srcShortLabel(song.source)} · $qualityLabel',
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Color(0x8CFFFFFF),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _GlassIconBtn(
            icon: CupertinoIcons.slider_horizontal_3,
            onTap: () => _showPlaybackSheet(context),
            tooltip: '播放设置',
          ),
        ],
      ),
    );
  }
}

class _GlassIconBtn extends StatelessWidget {
  const _GlassIconBtn({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Pressable(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Icon(icon, size: 17, color: const Color(0xD1FFFFFF)),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
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
        final size = math.min(constraints.maxWidth * 0.86, constraints.maxHeight * 0.72);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            AnimatedScale(
              duration: const Duration(milliseconds: 520),
              curve: AuroraMotion.ease,
              scale: player.isPlaying ? 1 : 0.93,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x7A000000),
                      blurRadius: 80,
                      offset: Offset(0, 44),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Stack(
                    children: <Widget>[
                      CoverArt(song: song, size: size, radius: 30, showMark: true),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(30),
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: <Color>[
                                  Color(0x22FFFFFF),
                                  Color(0x00FFFFFF),
                                  Color(0x0DFFFFFF),
                                ],
                                stops: <double>[0, 0.45, 0.72],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (player.errorText != null) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0x1CFF8F7A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x2EFF8F7A)),
                ),
                child: Text(
                  player.errorText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFFF0A99B)),
                ),
              ),
            ],
            if (player.loading && player.errorText == null) ...<Widget>[
              const SizedBox(height: 16),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.8, color: AppColors.accentDark),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '正在获取播放链接…',
                    style: TextStyle(fontSize: 11, color: Color(0x8CFFFFFF)),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    required this.song,
    required this.loved,
    required this.onFavorite,
  });

  final Song song;
  final bool loved;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  song.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 21,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.84,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.subtitle.isEmpty ? song.displaySinger : song.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Color(0x7AFFFFFF),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Pressable(
            onTap: onFavorite,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: loved ? const Color(0x1AFF8F7A) : const Color(0x0EFFFFFF),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: loved ? const Color(0x47FF8F7A) : const Color(0x1AFFFFFF),
                ),
              ),
              child: Icon(
                loved ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                size: 18,
                color: loved ? const Color(0xFFFF8F7A) : const Color(0x85FFFFFF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final maxMs = player.duration.inMilliseconds;
    final value = maxMs <= 0
        ? 0.0
        : (player.position.inMilliseconds / maxMs).clamp(0.0, 1.0).toDouble();

    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        children: <Widget>[
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: AppColors.accentDark,
              inactiveTrackColor: const Color(0x29FFFFFF),
              thumbColor: Colors.white,
              overlayColor: const Color(0x149AF4D2),
              trackShape: const RectangularSliderTrackShape(),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value,
              onChanged: maxMs <= 0
                  ? null
                  : (next) =>
                      player.seek(Duration(milliseconds: (next * maxMs).round())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  formatDuration(player.position),
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0x5CFFFFFF),
                  ),
                ),
                Text(
                  formatDuration(player.duration),
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0x5CFFFFFF),
                  ),
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
  const _Controls({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  static IconData _modeIcon(PlayMode mode) {
    switch (mode) {
      case PlayMode.listLoop:
        return CupertinoIcons.repeat;
      case PlayMode.random:
        return CupertinoIcons.shuffle;
      case PlayMode.sequence:
        return CupertinoIcons.list_number;
      case PlayMode.singleLoop:
        return CupertinoIcons.repeat_1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _Ctrl(
            icon: _modeIcon(player.playMode),
            onTap: () {
              const modes = PlayMode.values;
              final next = modes[(player.playMode.index + 1) % modes.length];
              player.setPlayMode(next);
              flmToast(context, '播放模式：${next.label}');
            },
          ),
          _Ctrl(
            icon: CupertinoIcons.backward_fill,
            size: 24,
            bright: true,
            onTap: player.previous,
          ),
          Pressable(
            onTap: player.togglePlay,
            child: Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xFF9AF4D2), Color(0xFF61E6B8)],
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x4D61E6B8),
                    blurRadius: 34,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
              child: player.loading
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Color(0xFF06241B),
                      ),
                    )
                  : Icon(
                      player.isPlaying
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      size: 28,
                      color: const Color(0xFF06241B),
                    ),
            ),
          ),
          _Ctrl(
            icon: CupertinoIcons.forward_fill,
            size: 24,
            bright: true,
            onTap: player.next,
          ),
          _Ctrl(
            icon: CupertinoIcons.music_note_list,
            onTap: () => _showQueueSheet(context),
          ),
        ],
      ),
    );
  }
}

class _Ctrl extends StatelessWidget {
  const _Ctrl({
    required this.icon,
    required this.onTap,
    this.size = 23,
    this.bright = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final bool bright;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: SizedBox(
        width: 42,
        height: 42,
        child: Icon(
          icon,
          size: size,
          color: bright ? const Color(0xCCFFFFFF) : const Color(0x99FFFFFF),
        ),
      ),
    );
  }
}

class _PAction extends StatelessWidget {
  const _PAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 18, color: const Color(0x66FFFFFF)),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w500,
                color: Color(0x66FFFFFF),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showQueueSheet(BuildContext context) {
  showFlmSheet<void>(
    context,
    title: '播放队列',
    titleTrailing: Builder(
      builder: (sheetContext) {
        final player = context.watch<PlayerController>();
        return Text(
          '${player.queue.length} 首',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.darkText2,
          ),
        );
      },
    ),
    child: Builder(
      builder: (sheetContext) {
        return Consumer<PlayerController>(
          builder: (context, player, _) {
            if (player.queue.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(top: 30, bottom: 40),
                child: EmptyState(
                  title: '播放队列是空的',
                  icon: CupertinoIcons.music_note_list,
                ),
              );
            }
            return ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 6),
              itemCount: player.queue.length,
              itemBuilder: (context, index) {
                final song = player.queue[index];
                final active = player.index == index;
                return Pressable(
                  onTap: () {
                    player.jumpToQueueIndex(index);
                    Navigator.pop(sheetContext);
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      gradient: active
                          ? LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: <Color>[
                                accentSoftColor(context),
                                Colors.transparent,
                              ],
                              stops: const <double>[0, 0.85],
                            )
                          : null,
                    ),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 22,
                          child: active
                              ? EqBars(height: 11, color: accentFor(context))
                              : Text(
                                  '${index + 1}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.darkText3,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 10),
                        CoverArt(song: song, size: 40, radius: 11),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                song.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: active
                                      ? accentFor(context)
                                      : textFor(context),
                                ),
                              ),
                              const SizedBox(height: 2.5),
                              Text(
                                song.displaySinger,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.darkText3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Pressable(
                          onTap: () => player.removeFromQueue(song),
                          child: const SizedBox(
                            width: 30,
                            height: 30,
                            child: Icon(
                              CupertinoIcons.xmark_circle_fill,
                              size: 15,
                              color: AppColors.darkText3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    ),
  );
}

void _showSleepSheet(BuildContext context) {
  showFlmSheet<void>(
    context,
    title: '定时停止播放',
    child: Builder(
      builder: (sheetContext) {
        return Consumer<PlayerController>(
          builder: (context, player, _) {
            final remaining = player.sleepRemaining;
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 6),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(kGutter, 2, kGutter, 10),
                  child: Text(
                    remaining == null
                        ? '选择时长后，播放会在倒计时结束时停止。'
                        : '当前剩余 ${formatDuration(remaining)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.darkText2,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <int>[15, 30, 45, 60, 90].map((minutes) {
                      return OptionPill(
                        label: '$minutes 分钟',
                        active: false,
                        onTap: () {
                          player.setSleepTimer(Duration(minutes: minutes));
                          Navigator.pop(sheetContext);
                          flmToast(context, '将在 $minutes 分钟后停止');
                        },
                      );
                    }).toList(),
                  ),
                ),
                if (remaining != null) ...<Widget>[
                  const SizedBox(height: 8),
                  SheetAction(
                    icon: CupertinoIcons.timer,
                    label: '关闭定时',
                    danger: true,
                    onTap: () {
                      player.setSleepTimer(null);
                      Navigator.pop(sheetContext);
                      flmToast(context, '已关闭定时');
                    },
                  ),
                ],
              ],
            );
          },
        );
      },
    ),
  );
}

void _showPlaybackSheet(BuildContext context) {
  showFlmSheet<void>(
    context,
    title: '播放设置',
    child: Builder(
      builder: (sheetContext) {
        return Consumer<PlayerController>(
          builder: (context, player, _) {
            final volume = player.appState.settings.volume;
            final speed = player.appState.settings.speed;
            return Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Overline('VOLUME'),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Slider(
                          value: volume.clamp(0.0, 1.0).toDouble(),
                          onChanged: player.setVolume,
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${(volume * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.darkText2,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Overline('SPEED'),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Slider(
                          value: speed.clamp(0.5, 2.0).toDouble(),
                          min: 0.5,
                          max: 2.0,
                          divisions: 12,
                          onChanged: (value) => player
                              .setSpeed(double.parse(value.toStringAsFixed(2))),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${speed.toStringAsFixed(2)}x',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.darkText2,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '提示：播放速度会同时影响歌词滚动。',
                    style: TextStyle(
                      fontSize: 11,
                      color: faintFor(context),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}
