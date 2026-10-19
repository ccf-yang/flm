import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/lyric.dart';

class LyricView extends StatefulWidget {
  const LyricView({
    super.key,
    required this.lines,
    required this.activeLine,
    required this.onSeek,
  });

  final List<LyricLine> lines;
  final int activeLine;
  final ValueChanged<Duration> onSeek;

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final ScrollController _controller = ScrollController();
  final Map<int, GlobalKey> _keys = <int, GlobalKey>{};

  @override
  void didUpdateWidget(covariant LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) {
      _keys.clear();
    }
    if (widget.activeLine != oldWidget.activeLine && widget.activeLine >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  void _scrollToActive() {
    final context = _keys[widget.activeLine]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.42,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(fontSize: 13, color: faintFor(context)),
        ),
      );
    }
    return SingleChildScrollView(
      controller: _controller,
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 120),
          ...widget.lines.asMap().entries.map((entry) {
            final index = entry.key;
            final line = entry.value;
            final active = index == widget.activeLine;
            final key = _keys.putIfAbsent(index, () => GlobalKey());
            return GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSeek(line.time),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Column(
                  children: <Widget>[
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      style: TextStyle(
                        fontSize: active ? 20 : 15.5,
                        height: 1.35,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                        letterSpacing: active ? -0.43 : 0,
                        color: active
                            ? accentFor(context)
                            : textFor(context).withValues(alpha: 0.48),
                        shadows: active
                            ? <Shadow>[
                                Shadow(
                                  color: accentFor(context).withValues(alpha: 0.32),
                                  blurRadius: 18,
                                ),
                              ]
                            : const <Shadow>[],
                      ),
                      child: Text(
                        line.displayText,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (line.hasTranslation) ...<Widget>[
                      const SizedBox(height: 5),
                      Text(
                        line.translation,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: active ? 11 : 10.5,
                          height: 1.45,
                          color: active
                              ? accentFor(context).withValues(alpha: 0.62)
                              : faintFor(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 160),
        ],
      ),
    );
  }
}
