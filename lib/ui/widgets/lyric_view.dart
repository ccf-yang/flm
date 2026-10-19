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
          style: TextStyle(fontSize: 14, color: mutedFor(context)),
        ),
      );
    }
    return SingleChildScrollView(
      controller: _controller,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 120),
          ...widget.lines.asMap().entries.map((entry) {
            final index = entry.key;
            final line = entry.value;
            final active = index == widget.activeLine;
            final key = _keys.putIfAbsent(index, () => GlobalKey());
            return InkWell(
              key: key,
              borderRadius: BorderRadius.circular(10),
              onTap: () => widget.onSeek(line.time),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  children: <Widget>[
                    Text(
                      line.displayText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: active ? 20 : 16,
                        height: 1.35,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        color: active
                            ? AppColors.accent
                            : textFor(context).withValues(alpha: 0.55),
                      ),
                    ),
                    if (line.hasTranslation) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        line.translation,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: active ? 14 : 12.5,
                          height: 1.35,
                          color: active
                              ? AppColors.accent.withValues(alpha: 0.78)
                              : mutedFor(context),
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
