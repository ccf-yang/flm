import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../models/app_settings.dart';
import '../../models/song.dart';
import '../../state/app_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import '../widgets/cover_art.dart';
import '../widgets/lyric_view.dart';
import '../widgets/queue_sheet.dart';
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

  /// Cumulative vertical drag on the player. Negative values mean the finger
  /// moved up; releasing past [_swipeTrigger] starts the next track.
  double _swipeDy = 0;

  /// Horizontal distance travelled by the left-edge back gesture.
  double _backDx = 0;

  static const double _swipeTrigger = 54;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goPage(int page) {
    if (page == _page || !_pageController.hasClients) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _swipeDy = 0;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final next = (_swipeDy + details.delta.dy).clamp(-160.0, 0.0).toDouble();
    if (next != _swipeDy) setState(() => _swipeDy = next);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final goNext = _swipeDy <= -_swipeTrigger ||
        details.velocity.pixelsPerSecond.dy <= -420;
    setState(() => _swipeDy = 0);
    if (!goNext) return;
    HapticFeedback.mediumImpact();
    context.read<PlayerController>().next();
  }

  void _onVerticalDragCancel() {
    if (_swipeDy == 0) return;
    setState(() => _swipeDy = 0);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final library = context.watch<LibraryState>();
    final song = player.current;
    final isDark = auroraIsDark(context);
    final media = MediaQuery.of(context);
    // The back strip sits below the top bar and above the controls, so it never
    // steals taps from the close button or the transport row.
    final backZoneHeight = math.max(
      140.0,
      media.size.height - media.padding.top - media.padding.bottom - 250,
    );

    final loved = song == null ? false : library.isLoved(song);
    void onFavorite() {
      if (song == null) return;
      final nowLoved = library.toggleLove(song);
      flmToast(context, nowLoved ? '已收藏到「我喜欢」' : '已取消收藏');
    }

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
          else ...<Widget>[
            SafeArea(
              bottom: true,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: _onVerticalDragStart,
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                onVerticalDragCancel: _onVerticalDragCancel,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                  child: Column(
                    children: <Widget>[
                      _PlayerTop(
                        player: player,
                        song: song,
                        onOpenQueue: () => showPlayQueueSheet(context),
                      ),
                      // No page dots: the cover and the lyrics swap with a
                      // horizontal swipe, and tapping the artwork (or the mini
                      // strip on the lyric page) switches the other way.
                      Expanded(
                        child: PageView(
                          controller: _pageController,
                          onPageChanged: (value) => setState(() => _page = value),
                          children: <Widget>[
                            _CoverPage(
                              player: player,
                              song: song,
                              loved: loved,
                              onFavorite: onFavorite,
                              onOpenLyrics: () => _goPage(1),
                            ),
                            _LyricPage(
                              player: player,
                              song: song,
                              loved: loved,
                              onFavorite: onFavorite,
                              onOpenCover: () => _goPage(0),
                            ),
                          ],
                        ),
                      ),
                      _SeekBar(player: player),
                      _Controls(player: player),
                      const SizedBox(height: 4),
                      _UpNextBar(player: player),
                    ],
                  ),
                ),
              ),
            ),
            // Swipe-up feedback. It only appears once the finger has moved,
            // so it never covers the artwork at rest.
            Positioned(
              top: media.padding.top + 58,
              left: 0,
              right: 0,
              child: _swipeHint(),
            ),
            // Left-edge swipe back, matching the Cupertino pages. It is a
            // narrow strip above the content so the cover PageView cannot
            // swallow the gesture.
            Positioned(
              left: 0,
              top: media.padding.top + 58,
              width: 22,
              height: backZoneHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _backDx = 0,
                onHorizontalDragUpdate: (details) => _backDx += details.delta.dx,
                onHorizontalDragEnd: (details) {
                  final travelled = _backDx;
                  _backDx = 0;
                  if (travelled > 48 ||
                      details.velocity.pixelsPerSecond.dx > 360) {
                    Navigator.of(context).maybePop();
                  }
                },
                onHorizontalDragCancel: () => _backDx = 0,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _swipeHint() {
    final progress = (-_swipeDy / _swipeTrigger).clamp(0.0, 1.0).toDouble();
    return IgnorePointer(
      child: Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - progress)),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xD9101519),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0x2EFFFFFF)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    CupertinoIcons.chevron_up,
                    size: 14,
                    color: AppColors.accentDark,
                  ),
                  SizedBox(width: 6),
                  Text(
                    '松开播放下一首',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Top bar ----------

class _PlayerTop extends StatelessWidget {
  const _PlayerTop({
    required this.player,
    required this.song,
    required this.onOpenQueue,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final quality = _qualityLabel(player.appState.settings.quality);
    final sleep = player.sleepRemaining;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
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
                    Flexible(
                      child: Text(
                        sleep == null
                            ? '${srcShortLabel(song.source)} · $quality'
                            : '${srcShortLabel(song.source)} · $quality · 定时 ${formatDuration(sleep)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: sleep == null
                              ? const Color(0x8CFFFFFF)
                              : const Color(0xCCF2D08C),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // The only control in the top-right corner, and it is unmistakably the
          // queue: the count is written next to the word, not as a badge.
          _QueuePill(
            count: player.queue.length,
            onTap: onOpenQueue,
          ),
        ],
      ),
    );
  }
}

class _QueuePill extends StatelessWidget {
  const _QueuePill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x24FFFFFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.list_bullet,
              size: 13,
              color: Color(0xCCFFFFFF),
            ),
            const SizedBox(width: 6),
            const Text(
              '队列',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: Color(0xE8FFFFFF),
              ),
            ),
            if (count > 1) ...<Widget>[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accentDark,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
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
        width: 44,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Icon(icon, size: 19, color: const Color(0xD1FFFFFF)),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

// ---------- Pages ----------

class _CoverPage extends StatelessWidget {
  const _CoverPage({
    required this.player,
    required this.song,
    required this.loved,
    required this.onFavorite,
    required this.onOpenLyrics,
  });

  final PlayerController player;
  final Song song;
  final bool loved;
  final VoidCallback onFavorite;
  final VoidCallback onOpenLyrics;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = math.min(
                constraints.maxWidth * 0.92,
                constraints.maxHeight * 0.90,
              );
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    // Tap the artwork to read the lyrics — the swipe stays the
                    // primary path, this is just the discoverable one.
                    Pressable(
                      onTap: onOpenLyrics,
                      child: AnimatedScale(
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
                                CoverArt(
                                  song: song,
                                  size: size,
                                  radius: 30,
                                  showMark: true,
                                ),
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
                    ),
                    if (player.errorText != null) ...<Widget>[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x1CFF8F7A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0x2EFF8F7A)),
                        ),
                        child: Text(
                          player.errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFF0A99B),
                          ),
                        ),
                      ),
                    ],
                    if (player.loading && player.errorText == null) ...<Widget>[
                      const SizedBox(height: 12),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.7,
                              color: AppColors.accentDark,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            '正在获取播放链接…',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0x8CFFFFFF),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        _TitleRow(
          song: song,
          loved: loved,
          onFavorite: onFavorite,
          onMore: () => _showPlaybackSheet(context, song),
          onOpenLyrics: onOpenLyrics,
        ),
      ],
    );
  }
}

class _LyricPage extends StatelessWidget {
  const _LyricPage({
    required this.player,
    required this.song,
    required this.loved,
    required this.onFavorite,
    required this.onOpenCover,
  });

  final PlayerController player;
  final Song song;
  final bool loved;
  final VoidCallback onFavorite;
  final VoidCallback onOpenCover;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _MiniStrip(
          song: song,
          loved: loved,
          onFavorite: onFavorite,
          onOpenCover: onOpenCover,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: LyricView(
            lines: player.lyrics,
            activeLine: player.activeLine,
            onSeek: player.seek,
          ),
        ),
        // Keeps the lyric column the same height as the cover page, so the
        // seek bar below does not move when the pages swap.
        const SizedBox(height: 50),
      ],
    );
  }
}

/// Title, artist, favourite and the entry to playback settings — all on one
/// line, right under the artwork. The heart is a frequent action and does not
/// belong buried in the transport row.
class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.song,
    required this.loved,
    required this.onFavorite,
    required this.onMore,
    required this.onOpenLyrics,
  });

  final Song song;
  final bool loved;
  final VoidCallback onFavorite;
  final VoidCallback onMore;
  final VoidCallback onOpenLyrics;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenLyrics,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
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
                  const SizedBox(height: 3),
                  Text(
                    song.subtitle.isEmpty ? song.displaySinger : song.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0x7AFFFFFF),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _IconDot(
            icon: loved ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
            color: loved ? const Color(0xFFFF8F7A) : const Color(0xA6FFFFFF),
            size: 22,
            onTap: onFavorite,
            tooltip: loved ? '取消收藏' : '收藏',
          ),
          const SizedBox(width: 2),
          _IconDot(
            icon: CupertinoIcons.ellipsis,
            color: const Color(0xA6FFFFFF),
            size: 21,
            onTap: onMore,
            tooltip: '播放设置',
          ),
        ],
      ),
    );
  }
}

class _MiniStrip extends StatelessWidget {
  const _MiniStrip({
    required this.song,
    required this.loved,
    required this.onFavorite,
    required this.onOpenCover,
  });

  final Song song;
  final bool loved;
  final VoidCallback onFavorite;
  final VoidCallback onOpenCover;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: Row(
        children: <Widget>[
          Pressable(
            onTap: onOpenCover,
            child: Row(
              children: <Widget>[
                CoverArt(song: song, size: 52, radius: 14, showMark: false),
                const SizedBox(width: 11),
                SizedBox(
                  width: math.max(120.0, MediaQuery.sizeOf(context).width * 0.42),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.subtitle.isEmpty
                            ? song.displaySinger
                            : song.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0x73FFFFFF),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _IconDot(
            icon: loved ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
            color: loved ? const Color(0xFFFF8F7A) : const Color(0xA6FFFFFF),
            size: 20,
            onTap: onFavorite,
            tooltip: loved ? '取消收藏' : '收藏',
          ),
        ],
      ),
    );
  }
}

class _IconDot extends StatelessWidget {
  const _IconDot({
    required this.icon,
    required this.color,
    required this.size,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Pressable(
      onTap: onTap,
      child: SizedBox(
        width: 42,
        height: 42,
        child: Icon(icon, size: size, color: color),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

// ---------- Seek + transport ----------

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});

  final PlayerController player;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didUpdateWidget(covariant _SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBreath();
  }

  @override
  void initState() {
    super.initState();
    _syncBreath();
  }

  /// While a link is being fetched the track gently breathes instead of showing
  // a buffered segment — there is no buffered position to draw, and the play
  // state machine stays untouched.
  void _syncBreath() {
    if (widget.player.loading) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else if (_breath.isAnimating) {
      _breath.stop();
      _breath.value = 1;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final maxMs = player.duration.inMilliseconds;
    final value = maxMs <= 0
        ? 0.0
        : (player.position.inMilliseconds / maxMs).clamp(0.0, 1.0).toDouble();
    final remaining = maxMs <= 0
        ? Duration.zero
        : player.duration - player.position;

    return Column(
      children: <Widget>[
        AnimatedBuilder(
          animation: _breath,
          builder: (context, child) => Opacity(
            opacity: player.loading ? 0.62 + 0.38 * _breath.value : 1,
            child: child,
          ),
          child: SliderTheme(
            data: const SliderThemeData(
              trackHeight: 4,
              activeTrackColor: AppColors.accentDark,
              inactiveTrackColor: Color(0x29FFFFFF),
              thumbColor: Colors.white,
              overlayColor: Color(0x1F9AF4D2),
              trackShape: RectangularSliderTrackShape(),
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 20),
            ),
            child: Slider(
              value: value,
              onChanged: maxMs <= 0
                  ? null
                  : (next) =>
                      player.seek(Duration(milliseconds: (next * maxMs).round())),
            ),
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
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0x70FFFFFF),
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              Text(
                // Remaining time, because "how long is this song" is the
                // question the number under the bar actually answers.
                maxMs <= 0 ? '--:--' : '-${formatDuration(remaining)}',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0x70FFFFFF),
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.player});

  final PlayerController player;

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

  void _nudgeVolume(BuildContext context) {
    final current = player.appState.settings.volume;
    final next = (current - 0.05).clamp(0.0, 1.0).toDouble();
    player.setVolume(next);
    flmToast(context, '音量 ${(next * 100).round()}%');
  }

  void _fastForward(BuildContext context) {
    final maxMs = player.duration.inMilliseconds;
    if (maxMs <= 0) return;
    final target = math.min(
      player.position.inMilliseconds + 15000,
      maxMs - 1000,
    );
    player.seek(Duration(milliseconds: target));
    flmToast(context, '快进 15 秒');
  }

  @override
  Widget build(BuildContext context) {
    // The speed pill used to sit on the right; it is redundant now that 倍速
    // lives in the ⋯ panel, so the transport is the classic 4: mode · prev ·
    // play · next. An invisible mirror of the mode button keeps the play
    // button dead-centre.
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
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
          const Spacer(),
          // Long-press keeps the two fine adjustments that used to live on the
          // removed toolbar without adding a sixth button.
          _Ctrl(
            icon: CupertinoIcons.backward_fill,
            size: 56,
            iconSize: 26,
            bright: true,
            onTap: player.previous,
            onLongPress: () => _nudgeVolume(context),
          ),
          const SizedBox(width: 14),
          Pressable(
            onTap: player.togglePlay,
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xFF9AF4D2), Color(0xFF61E6B8)],
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Color(0x4D61E6B8),
                    blurRadius: 36,
                    offset: Offset(0, 15),
                  ),
                ],
              ),
              child: player.loading
                  ? const Padding(
                      padding: EdgeInsets.all(22),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Color(0xFF06241B),
                      ),
                    )
                  : Icon(
                      player.willPlay
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      size: 29,
                      color: const Color(0xFF06241B),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          _Ctrl(
            icon: CupertinoIcons.forward_fill,
            size: 56,
            iconSize: 26,
            bright: true,
            onTap: player.next,
            onLongPress: () => _fastForward(context),
          ),
          const Spacer(),
          // Balance the left-hand mode button so the play button stays centred.
          IgnorePointer(
            child: Opacity(
              opacity: 0,
              child: _Ctrl(icon: _modeIcon(player.playMode), onTap: () {}),
            ),
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
    this.size = 50,
    this.iconSize = 21,
    this.bright = false,
    this.onLongPress,
  });

  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double size;
  final double iconSize;
  final bool bright;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(
          icon,
          size: iconSize,
          color: bright ? const Color(0xCCFFFFFF) : const Color(0x99FFFFFF),
        ),
      ),
    );
  }
}

/// One bar that answers "what comes next" and opens the queue. It replaced the
/// old three-entry toolbar, two of which duplicated the settings sheet.
class _UpNextBar extends StatelessWidget {
  const _UpNextBar({required this.player});

  final PlayerController player;

  String get _kicker {
    switch (player.playMode) {
      case PlayMode.random:
        return '随机播放';
      case PlayMode.singleLoop:
        return '单曲循环';
      case PlayMode.listLoop:
      case PlayMode.sequence:
        return 'UP NEXT';
    }
  }

  Song? get _next {
    final queue = player.queue;
    final index = player.index;
    if (queue.length <= 1 || index < 0) return null;
    switch (player.playMode) {
      case PlayMode.random:
        return null;
      case PlayMode.singleLoop:
        return queue[index];
      case PlayMode.listLoop:
        return queue[(index + 1) % queue.length];
      case PlayMode.sequence:
        return index + 1 < queue.length ? queue[index + 1] : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = _next;
    final count = player.queue.length;
    final line = next == null
        ? (player.playMode == PlayMode.random
            ? '下一首随机 · 点开队列看'
            : count <= 1
                ? '队列里只有这一首'
                : '播放到队列末尾了')
        : '${next.displayTitle} · ${next.displaySinger}';

    return Pressable(
      onTap: () => showPlayQueueSheet(context),
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x1AFFFFFF)),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 42,
              height: 42,
              child: next == null
                  ? Container(
                      decoration: BoxDecoration(
                        color: const Color(0x14FFFFFF),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        CupertinoIcons.music_note_list,
                        size: 17,
                        color: Color(0x8AFFFFFF),
                      ),
                    )
                  : CoverArt(song: next, size: 42, radius: 11),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _kicker,
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                      color: _kicker == 'UP NEXT'
                          ? const Color(0x59FFFFFF)
                          : const Color(0x80F2D08C),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xE8FFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '队列 $count ›',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: Color(0x8CFFFFFF),
              ),
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

// ---------- Playback settings (the ⋯ sheet) ----------

Future<void> _showPlaybackSheet(BuildContext context, Song song) {
  return showFlmSheet<void>(
    context,
    title: '播放设置',
    maxHeight: 0.66,
    titleTrailing: Consumer<PlayerController>(
      builder: (context, player, _) {
        final sleep = player.sleepRemaining;
        if (sleep == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0x1FF2D08C),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '定时 ${formatDuration(sleep)}',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFFF2D08C),
            ),
          ),
        );
      },
    ),
    child: Builder(
      builder: (sheetContext) => Consumer2<PlayerController, LibraryState>(
        builder: (context, player, library, _) {
          final settings = player.appState.settings;
          final loved = library.isLoved(song);
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _quickActions(
                  context,
                  player: player,
                  library: library,
                  song: song,
                  loved: loved,
                ),
                _settingsRow(
                  context,
                  icon: CupertinoIcons.speaker_2_fill,
                  label: '音量',
                  trailing: Text(
                    '${(settings.volume * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: mutedFor(context),
                    ),
                  ),
                  child: Slider(
                    value: settings.volume.clamp(0.0, 1.0).toDouble(),
                    onChanged: player.setVolume,
                  ),
                ),
                _settingsRow(
                  context,
                  icon: CupertinoIcons.timer,
                  label: '定时停止',
                  caption: player.sleepRemaining == null
                      ? '选一个时长，到点自动暂停'
                      : '剩余 ${formatDuration(player.sleepRemaining!)}',
                  value: player.sleepRemaining == null ? '设置 ›' : '更改 ›',
                  onTap: () => _showSleepSheet(context),
                ),
                _settingsRow(
                  context,
                  icon: CupertinoIcons.waveform,
                  label: '音质',
                  caption: '来源 ${srcShortLabel(song.source)}',
                  value: '${_qualityLabel(settings.quality)} ›',
                  onTap: () => _showQualitySheet(context),
                ),
                _settingsRow(
                  context,
                  icon: CupertinoIcons.forward_end_alt_fill,
                  label: '倍速',
                  value: '${settings.speed.toStringAsFixed(2)}×',
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: <double>[0.75, 1.0, 1.25, 1.5, 2.0]
                          .map(
                            (speed) => OptionPill(
                              label: '${speed.toStringAsFixed(2)}×',
                              active:
                                  (settings.speed - speed).abs() < 0.001,
                              onTap: () => player.setSpeed(speed),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                _settingsRow(
                  context,
                  icon: CupertinoIcons.arrow_clockwise,
                  label: '重载歌词',
                  caption: '歌词不匹配或没有歌词时试试',
                  value: '›',
                  onTap: () {
                    unawaited(player.reloadLyrics());
                    flmToast(context, '正在重新获取歌词');
                  },
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// The four actions people reach for constantly — favourite, add to a list,
/// copy the title, and "not interested". They used to be buried two levels deep
/// behind 歌曲详情, so they live flat across the top of the ⋯ panel now.
Widget _quickActions(
  BuildContext context, {
  required PlayerController player,
  required LibraryState library,
  required Song song,
  required bool loved,
}) {
  final appState = context.read<AppState>();
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: _QuickActionChip(
            icon: loved ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
            label: loved ? '已收藏' : '收藏',
            active: loved,
            activeColor: const Color(0xFFFF8F7A),
            onTap: () {
              final now = library.toggleLove(song);
              flmToast(context, now ? '已收藏到「我喜欢」' : '已取消收藏');
            },
          ),
        ),
        Expanded(
          child: _QuickActionChip(
            icon: CupertinoIcons.music_note_list,
            label: '加列表',
            onTap: () {
              showAddToPlaylist(context, song);
            },
          ),
        ),
        Expanded(
          child: _QuickActionChip(
            icon: CupertinoIcons.doc_on_doc,
            label: '复制歌名',
            onTap: () {
              final text = song.singer.isEmpty
                  ? song.name
                  : '${song.name} - ${song.singer}';
              Clipboard.setData(ClipboardData(text: text));
              flmToast(context, '已复制歌名');
            },
          ),
        ),
        Expanded(
          child: _QuickActionChip(
            icon: CupertinoIcons.xmark_circle_fill,
            label: '不感兴趣',
            activeColor: coralFor(context),
            onTap: () {
              appState.dislike(song);
              Navigator.pop(context);
              if (player.isCurrent(song)) {
                player.next();
              }
              flmToast(context, '已加入不喜欢规则');
            },
          ),
        ),
      ],
    ),
  );
}

class _QuickActionChip extends StatelessWidget {
  const _QuickActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final tint = activeColor ?? accentFor(context);
    final iconColor = active ? tint : mutedFor(context);
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 72,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: active ? tint.withValues(alpha: 0.12) : surface2For(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: active ? tint.withValues(alpha: 0.42) : lineColor(context),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: active ? iconColor : textFor(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _settingsRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  String? caption,
  String? value,
  Widget? trailing,
  Widget? child,
  VoidCallback? onTap,
}) {
  final body = Row(
    children: <Widget>[
      Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: surface2For(context),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: lineColor(context)),
        ),
        child: Icon(icon, size: 15, color: mutedFor(context)),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textFor(context),
              ),
            ),
            if (caption != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                caption,
                style: TextStyle(fontSize: 10.5, color: faintFor(context)),
              ),
            ],
          ],
        ),
      ),
      if (trailing != null) trailing else if (value != null)
        Text(
          value,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: accentFor(context),
          ),
        ),
    ],
  );

  return Pressable(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: EdgeInsets.fromLTRB(10, onTap == null ? 8 : 9, 12, 8),
      decoration: BoxDecoration(
        color: surface2For(context),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: lineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          body,
          if (child != null) child,
        ],
      ),
    ),
  );
}

void _showSleepSheet(BuildContext context) {
  showFlmSheet<void>(
    context,
    title: '定时停止播放',
    child: Builder(
      builder: (sheetContext) => Consumer<PlayerController>(
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
                  style: TextStyle(fontSize: 11, color: mutedFor(context)),
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
      ),
    ),
  );
}

void _showQualitySheet(BuildContext context) {
  showFlmSheet<void>(
    context,
    title: '优先音质',
    child: Builder(
      builder: (sheetContext) {
        final appState = context.read<AppState>();
        final current = appState.settings.quality;
        const options = <String, String>{
          '128k': '标准 128k',
          '320k': '高品质 320k',
          'flac': '无损 FLAC',
          'flac24bit': '24bit FLAC',
        };
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 6),
          children: <Widget>[
            for (final entry in options.entries)
              OptionRow(
                label: entry.value,
                active: current == entry.key,
                onTap: () {
                  appState.update((settings) => settings.quality = entry.key);
                  Navigator.pop(sheetContext);
                  flmToast(context, '优先音质：${entry.value}');
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Text(
                '只影响之后获取的播放链接，当前这首不会重新加载。',
                style: TextStyle(fontSize: 10.5, color: faintFor(context)),
              ),
            ),
          ],
        );
      },
    ),
  );
}

String _qualityLabel(String quality) {
  switch (quality) {
    case '128k':
      return '标准';
    case '320k':
      return '高品质';
    case 'flac':
      return '无损';
    case 'flac24bit':
      return '24bit';
    default:
      return quality;
  }
}
