import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/song.dart';
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

  static const double diameter = 60;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  static const double _edge = 12;
  static const double _topGap = 8;

  Offset? _offset;
  bool _dragging = false;
  bool _pressed = false;

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

    final settings = context.read<AppState>().settings;
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
          child: _GlassPendant(song: song, player: player),
        ),
      ),
    );
  }
}

class _GlassPendant extends StatelessWidget {
  const _GlassPendant({required this.song, required this.player});

  final Song song;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final isDark = auroraIsDark(context);
    const diameter = MiniPlayer.diameter;
    final durationMs = player.duration.inMilliseconds;
    final progress = durationMs > 0
        ? (player.position.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final ringColor =
        player.errorText != null ? coralFor(context) : accentFor(context);

    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Drop shadow, painted outside the clipped glass so it stays visible.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: player.isPlaying
                        ? accentFor(context).withValues(alpha: 0.22)
                        : Colors.black.withValues(
                            alpha: isDark ? 0.34 : 0.16,
                          ),
                    blurRadius: player.isPlaying ? 30 : 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: const SizedBox.expand(),
            ),
          ),
          // Frosted glass disc (`backdrop-filter: blur(26px)` in the study).
          ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
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
                  border: Border.all(color: lineStrongColor(context)),
                ),
              ),
            ),
          ),
          // Glass rim highlight.
          Positioned(
            left: diameter * 0.18,
            right: diameter * 0.18,
            top: 4,
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
          CoverArt(song: song, size: 44, radius: 22),
          // Progress ring (or a spinner while the URL is being fetched).
          Positioned.fill(
            child: player.loading
                ? Padding(
                    padding: const EdgeInsets.all(1.5),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: ringColor,
                    ),
                  )
                : CustomPaint(
                    painter: _RingPainter(
                      progress: progress,
                      color: ringColor,
                      trackColor: lineColor(context),
                      thickness: 2.4,
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
  });

  final double progress;
  final Color color;
  final Color trackColor;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - thickness / 2 - 0.5;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness,
    );

    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.thickness != thickness;
}
