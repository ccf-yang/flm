import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import '../screens/player_screen.dart';
import 'cover_art.dart';

/// Floating "now playing" pendant that sits just above the tab bar. A small
/// semi-transparent glass disc with a progress ring around the current cover,
/// so it blends into the aurora instead of blocking the view like a bar did.
/// Tapping it opens the full player page.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  static const double diameter = 58;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();

    final durationMs = player.duration.inMilliseconds;
    final progress = durationMs > 0
        ? (player.position.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final ringColor = player.errorText != null
        ? coralFor(context)
        : accentFor(context);

    return Pressable(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const PlayerScreen(),
          ),
        );
      },
      child: SizedBox(
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
                      color: Colors.black.withValues(
                        alpha: auroraIsDark(context) ? 0.30 : 0.16,
                      ),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const SizedBox.expand(),
              ),
            ),
            // Frosted glass disc.
            ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  width: diameter,
                  height: diameter,
                  color: surfaceFor(context).withValues(
                    alpha: auroraIsDark(context) ? 0.55 : 0.62,
                  ),
                ),
              ),
            ),
            CoverArt(song: song, size: 42, radius: 21),
            // Progress ring (or a spinner while the URL is being fetched).
            Positioned.fill(
              child: player.loading
                  ? Padding(
                      padding: const EdgeInsets.all(2),
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
                        thickness: 3,
                      ),
                    ),
            ),
          ],
        ),
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
