import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/app_settings.dart';
import '../../models/song.dart';
import '../../services/cover_palette.dart';
import '../../state/app_state.dart';
import '../../state/player_state.dart';
import '../screens/player_screen.dart';
import 'cover_art.dart';

/// Draggable "now playing" pendant, floating above the tab bar.
///
/// It is a frosted glass disc with a progress ring around the current cover.
/// Drag it anywhere (the position is persisted as a fraction of the usable
/// area, so it survives rotation and app restarts); tap it to open the full
/// player with a soft slide-up transition.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, required this.bottomReserved});

  /// Vertical space that stays untouchable at the bottom of the root screen
  /// (tab bar + safe area + gap), so the pendant never covers the tabs.
  final double bottomReserved;

  static const double diameter = 66;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  static const double _edge = 12;
  static const double _topGap = 8;

  Offset? _offset;
  bool _dragging = false;
  bool _pressed = false;

  /// Cover-derived accent, resolved asynchronously per song so the pendant can
  /// match the artwork when 跟随封面配色 is on.
  String? _accentKey;
  Color? _autoAccent;

  void _loadAccent(Song song, String key) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final color = await CoverPalette.accent(song);
      if (!mounted || _accentKey != key) return;
      setState(() => _autoAccent = color);
    });
  }

  /// The colour the pendant wears: the cover's dominant colour while 跟随封面配色
  /// is on (falling back to the stored accent until it resolves), otherwise the
  /// stored accent itself.
  Color _accentFor(Song song, AppSettings settings) {
    final center =
        Color(AppSettings.miniPlayerColorValue(settings.miniPlayerColor));
    if (!settings.miniPlayerUseImageColor) {
      _accentKey = null;
      return center;
    }
    final key = '${song.source}:${song.id}';
    if (_accentKey != key) {
      _accentKey = key;
      _autoAccent = null;
      _loadAccent(song, key);
    }
    return _autoAccent ?? center;
  }

  void _openPlayer() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => const PlayerScreen(),
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: AuroraMotion.ease,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.035),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void _persist(Offset position, Rect bounds) {
    final appState = context.read<AppState>();
    final spanX = math.max(1.0, bounds.right - bounds.left);
    final spanY = math.max(1.0, bounds.bottom - bounds.top);
    appState.settings.miniPlayerX =
        ((position.dx - bounds.left) / spanX).clamp(0.0, 1.0).toDouble();
    appState.settings.miniPlayerY =
        ((position.dy - bounds.top) / spanY).clamp(0.0, 1.0).toDouble();
    unawaited(appState.repository.save());
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final media = MediaQuery.of(context);
    const diameter = MiniPlayer.diameter;
    final bounds = Rect.fromLTRB(
      _edge,
      media.padding.top + _topGap,
      media.size.width - _edge - diameter,
      media.size.height - widget.bottomReserved - diameter,
    );
    if (bounds.right < bounds.left || bounds.bottom < bounds.top) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final settings = context.watch<AppState>().settings;
    final storedX = settings.miniPlayerX;
    final storedY = settings.miniPlayerY;
    final stored = storedX >= 0 && storedY >= 0
        ? Offset(
            bounds.left + storedX * (bounds.right - bounds.left),
            bounds.top + storedY * (bounds.bottom - bounds.top),
          )
        : null;
    final base = _offset ?? stored ?? Offset(bounds.right, bounds.bottom);
    final position = Offset(
      base.dx.clamp(bounds.left, bounds.right).toDouble(),
      base.dy.clamp(bounds.top, bounds.bottom).toDouble(),
    );

    return AnimatedPositioned(
      duration: _dragging ? Duration.zero : AuroraMotion.base,
      curve: AuroraMotion.spring,
      left: position.dx,
      top: position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openPlayer,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onPanStart: (_) {
          setState(() {
            _dragging = true;
            _pressed = false;
            _offset = position;
          });
        },
        onPanUpdate: (details) {
          final next = (_offset ?? position) + details.delta;
          setState(() {
            _offset = Offset(
              next.dx.clamp(bounds.left, bounds.right).toDouble(),
              next.dy.clamp(bounds.top, bounds.bottom).toDouble(),
            );
          });
        },
        onPanEnd: (_) {
          final resting = _offset ?? position;
          setState(() => _dragging = false);
          _persist(resting, bounds);
        },
        onPanCancel: () {
          setState(() => _dragging = false);
        },
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          curve: AuroraMotion.spring,
          scale: _dragging ? 1.06 : (_pressed ? 0.95 : 1),
          child: Opacity(
            opacity: settings.miniPlayerOpacity.clamp(0.3, 1.0).toDouble(),
            child: _GlassPendant(
              song: song,
              player: player,
              shape: settings.miniPlayerShape,
              accent: _accentFor(song, settings),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassPendant extends StatelessWidget {
  const _GlassPendant({
    required this.song,
    required this.player,
    required this.shape,
    required this.accent,
  });

  final Song song;
  final PlayerController player;
  final String shape;
  final Color accent;

  static const double _box = MiniPlayer.diameter;

  @override
  Widget build(BuildContext context) {
    final isDark = auroraIsDark(context);
    final durationMs = player.duration.inMilliseconds;
    final progress = durationMs > 0
        ? (player.position.inMilliseconds / durationMs)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;

    // Silhouette metrics. Everything is centred in the fixed 66x66 hit area so
    // the draggable position math never changes — only the drawn shape does.
    final double discW;
    final double discH;
    final double corner;
    final double cover;
    switch (shape) {
      case 'rect':
        discW = 60;
        discH = 60;
        corner = 16;
        cover = 44;
      default:
        discW = _box;
        discH = _box;
        corner = _box / 2;
        cover = 48;
    }
    final bool isRect = shape == 'rect';
    final BorderRadius discRadius = BorderRadius.circular(corner);
    final ringColor =
        player.errorText != null ? coralFor(context) : accent;
    final topInset = (_box - discH) / 2;

    // Frosted glass disc. The shape outline and its border are drawn by the
    // progress ring's track stroke, so the fill itself needs no border.
    final Widget glass = Container(
      width: discW,
      height: discH,
      decoration: BoxDecoration(
        borderRadius: discRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? <Color>[
                  const Color(0x26FFFFFF),
                  surfaceFor(context),
                  const Color(0x0DFFFFFF),
                ]
              : <Color>[
                  const Color(0xF2FFFFFF),
                  surfaceFor(context),
                  const Color(0xB3FFFFFF),
                ],
          stops: const <double>[0, 0.55, 1],
        ),
      ),
    );

    return SizedBox(
      width: _box,
      height: _box,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Drop shadow, painted behind the glass so it stays visible.
          Container(
            width: discW,
            height: discH,
            decoration: BoxDecoration(
              borderRadius: discRadius,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: player.willPlay
                      ? ringColor.withValues(alpha: 0.24)
                      : Colors.black.withValues(
                          alpha: isDark ? 0.34 : 0.16,
                        ),
                  blurRadius: player.willPlay ? 30 : 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
          ),
          if (isRect)
            ClipRRect(
              borderRadius: discRadius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: glass,
              ),
            )
          else
            ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: glass,
              ),
            ),
          // Glass rim highlight, near the top edge of the disc.
          Positioned(
            left: discW * 0.22,
            right: discW * 0.22,
            top: topInset + 4,
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(
                  colors: <Color>[
                    Colors.transparent,
                    Colors.white.withValues(alpha: 0.35),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // Centre medallion: the chosen colour backs the artwork, so the
          // "center image colour" reads clearly behind the cover.
          Container(
            width: cover + 12,
            height: cover + 12,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(isRect ? (cover + 12) / 2 * 0.55 : (cover + 12) / 2),
              color: accent.withValues(alpha: 0.18),
              border: Border.all(color: accent.withValues(alpha: 0.5)),
            ),
          ),
          CoverArt(
            song: song,
            size: cover,
            radius: isRect ? 12 : cover / 2,
          ),
          // Progress ring, tracing the disc outline for every shape.
          Positioned.fill(
            child: CustomPaint(
              painter: _RingPainter(
                progress: player.loading ? 1 : progress,
                color: ringColor,
                trackColor: lineStrongColor(context),
                thickness: 2.4,
                discW: discW,
                discH: discH,
                corner: isRect ? corner : 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.thickness,
    required this.discW,
    required this.discH,
    required this.corner,
  });

  final double progress;
  final Color color;
  final Color trackColor;
  final double thickness;
  final double discW;
  final double discH;
  final double corner;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = thickness / 2 + 0.5;
    final Rect base = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: discW,
      height: discH,
    );
    final Rect inner = Rect.fromLTRB(
      base.left + pad,
      base.top + pad,
      base.right - pad,
      base.bottom - pad,
    );

    final Path outline = Path();
    if (corner > 0) {
      outline.addRRect(
        RRect.fromRectAndRadius(
          inner,
          Radius.circular(math.max(0.0, corner - pad)),
        ),
      );
    } else {
      outline.addOval(inner);
    }

    canvas.drawPath(
      outline,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness,
    );

    if (progress <= 0) return;
    final metric = outline.computeMetrics().first;
    final arc = metric.extractPath(0, metric.length * progress);
    canvas.drawPath(
      arc,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.thickness != thickness ||
      oldDelegate.discW != discW ||
      oldDelegate.discH != discH ||
      oldDelegate.corner != corner;
}
