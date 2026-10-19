import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';

/// Shared primitives for the Quiet Aurora design language.
const double kGutter = 18.0;

/// Soft full-bleed aurora behind every screen (mirrors body::before).
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, this.deep = false});

  final bool deep;

  @override
  Widget build(BuildContext context) {
    final isDark = auroraIsDark(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? <Color>[AppColors.darkBg, deep ? AppColors.darkBgDeep : AppColors.darkBg]
              : <Color>[AppColors.lightBg, deep ? AppColors.lightBgDeep : AppColors.lightBg],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -1.02),
                    radius: 1.05,
                    colors: isDark
                        ? <Color>[const Color(0x179AF4D2), Colors.transparent]
                        : <Color>[const Color(0x1A0E9F78), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.92, -0.66),
                    radius: 0.85,
                    colors: isDark
                        ? <Color>[const Color(0x0FFF8F7A), Colors.transparent]
                        : <Color>[const Color(0x12D65E48), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.92, 0.64),
                    radius: 0.9,
                    colors: isDark
                        ? <Color>[const Color(0x135C78FF), Colors.transparent]
                        : <Color>[const Color(0x145068DC), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Glass icon button (the design's .icon-btn, 38×38 r13).
class IconBtn extends StatelessWidget {
  const IconBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 38,
    this.iconSize,
    this.active = false,
    this.color,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double? iconSize;
  final bool active;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.34);
    final button = Pressable(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: active ? accentSoftColor(context) : surfaceFor(context),
              borderRadius: radius,
              border: Border.all(
                color: active ? accentBorderColor(context) : lineColor(context),
              ),
            ),
            child: Icon(
              icon,
              size: iconSize ?? size * 0.47,
              color: onTap == null
                  ? faintFor(context)
                  : (active ? accentFor(context) : (color ?? mutedFor(context))),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Tiny uppercase label above section titles (.overline).
class Overline extends StatelessWidget {
  const Overline(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 8.5,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.6,
        color: color ?? faintFor(context),
      ),
    );
  }
}

/// Big screen title with the accent period (.topline h1).
class ScreenHead extends StatelessWidget {
  const ScreenHead({
    super.key,
    required this.overline,
    required this.title,
    this.subtitle,
    this.trailing,
    this.period = true,
  });

  final String overline;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool period;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Overline(overline),
              const SizedBox(height: 7),
              Text.rich(
                TextSpan(
                  text: title,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.3,
                    height: 1.08,
                    color: textFor(context),
                  ),
                  children: period
                      ? <InlineSpan>[
                          TextSpan(
                            text: '。',
                            style: TextStyle(color: accentFor(context)),
                          ),
                        ]
                      : null,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: mutedFor(context),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 12),
          trailing!,
        ],
      ],
    );
  }
}

/// Rounded pill chip used for source filters (.chip).
class Chip extends StatelessWidget {
  const Chip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AuroraMotion.quick,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? accentFor(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? Colors.transparent : lineColor(context),
          ),
          boxShadow: active
              ? <BoxShadow>[
                  BoxShadow(
                    color: accentFor(context).withValues(alpha: 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? accentInkFor(context) : mutedFor(context),
          ),
        ),
      ),
    );
  }
}

/// Horizontal scrolling row of chips.
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: kGutter),
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, index) => children[index],
      ),
    );
  }
}

/// Sort/tag pill with a bordered ghost look (.option-pill).
class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AuroraMotion.quick,
        height: 29,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? accentSoftColor(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: active ? accentFor(context) : faintFor(context),
          ),
        ),
      ),
    );
  }
}

/// Two-column segmented control (.segmented).
class AuroraSegmented extends StatelessWidget {
  const AuroraSegmented({
    super.key,
    required this.items,
    required this.activeIndex,
    required this.onChanged,
  });

  final List<String> items;
  final int activeIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: surface2For(context),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: lineColor(context)),
      ),
      child: Row(
        children: List<Widget>.generate(items.length, (index) {
          final active = index == activeIndex;
          return Expanded(
            child: Pressable(
              onTap: () => onChanged(index),
              child: AnimatedContainer(
                duration: AuroraMotion.quick,
                decoration: BoxDecoration(
                  color: active ? panelFor(context) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: active
                      ? const <BoxShadow>[
                          BoxShadow(color: Color(0x2E000000), blurRadius: 8, offset: Offset(0, 2)),
                        ]
                      : null,
                ),
                margin: const EdgeInsets.all(3),
                alignment: Alignment.center,
                child: Text(
                  items[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? textFor(context) : mutedFor(context),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// The signature search field (.searchbar, h48 r15, surface-2 → accent on
/// focus with a soft accent ring).
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.compact = false,
    this.autofocus = false,
    this.trailing,
    this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool compact;
  final bool autofocus;
  final Widget? trailing;
  final VoidCallback? onClear;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    return AnimatedContainer(
      duration: AuroraMotion.quick,
      curve: AuroraMotion.ease,
      height: compact ? 42 : 48,
      decoration: BoxDecoration(
        color: _focused ? surfaceFor(context) : surface2For(context),
        borderRadius: BorderRadius.circular(compact ? 13 : 15),
        border: Border.all(
          color: _focused ? accentFor(context) : lineColor(context),
        ),
        boxShadow: _focused
            ? <BoxShadow>[
                BoxShadow(
                  color: accentSoftColor(context),
                  blurRadius: 0,
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          Icon(CupertinoIcons.search, size: compact ? 15 : 17, color: faintFor(context)),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: textFor(context),
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                hintStyle: TextStyle(fontSize: 13, color: faintFor(context)),
                hintText: widget.hint,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (widget.controller.text.isNotEmpty && widget.onClear != null)
            Pressable(
              onTap: widget.onClear,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(CupertinoIcons.xmark_circle_fill, size: 16, color: faintFor(context)),
              ),
            )
          else if (widget.trailing != null)
            DefaultTextStyle(
              style: DefaultTextStyle.of(context).style,
              child: widget.trailing!,
            ),
        ],
      ),
    );
  }
}

/// The ↵ key hint inside the search field.
class EnterKbd extends StatelessWidget {
  const EnterKbd({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: bgFor(context),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: lineColor(context)),
      ),
      child: Text(
        '↵',
        style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: faintFor(context)),
      ),
    );
  }
}

/// Section header row (.section-head).
class SectionHead extends StatelessWidget {
  const SectionHead({
    super.key,
    required this.title,
    this.note,
    this.onAction,
    this.actionLabel,
    this.actionIcon,
  });

  final String title;
  final String? note;
  final VoidCallback? onAction;
  final String? actionLabel;
  final IconData? actionIcon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 22, kGutter - 6, 11),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: textFor(context),
              ),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                note!,
                style: TextStyle(
                  fontSize: 11,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  color: faintFor(context),
                ),
              ),
            ),
          if (onAction != null && actionLabel != null)
            Pressable(
              onTap: onAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: <Widget>[
                    if (actionIcon != null) ...<Widget>[
                      Icon(actionIcon, size: 12.5, color: accentFor(context)),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      actionLabel!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accentFor(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small platform badge (.src-badge / .card-badge).
class SrcBadge extends StatelessWidget {
  const SrcBadge(this.label, {super.key, this.onDark = false});

  final String label;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: onDark
          ? BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
            )
          : BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: lineStrongColor(context)),
            ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 7.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          height: 1.3,
          color: onDark ? Colors.white.withValues(alpha: 0.88) : mutedFor(context),
        ),
      ),
    );
  }
}

/// Source status pill on the search hero (.status-chip).
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.ok, required this.label});

  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = ok ? accentFor(context) : faintFor(context);
    final radius = BorderRadius.circular(999);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: surfaceFor(context),
            borderRadius: radius,
            border: Border.all(color: ok ? accentBorderColor(context) : lineColor(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: ok
                      ? <BoxShadow>[
                          BoxShadow(
                            color: accentSoftColor(context),
                            blurRadius: 0,
                            spreadRadius: 3,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pressable with the springy scale of the design's buttons.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 120),
        curve: AuroraMotion.spring,
        child: widget.child,
      ),
    );
  }
}

/// Animated equalizer bars shown on the playing row.
class EqBars extends StatefulWidget {
  const EqBars({super.key, this.height = 13, this.color});

  final double height;
  final Color? color;

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 760),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? accentFor(context);
    const factors = <double>[0.35, 0.85, 0.55, 1.0];
    const phases = <double>[0.0, 0.35, 0.62, 0.18];
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(4, (i) {
            final wave = 0.5 + 0.5 * math.sin((t + phases[i]) * 2 * math.pi);
            return Container(
              width: 2.5,
              height: widget.height * (0.3 + 0.7 * factors[i] * wave),
              margin: EdgeInsets.only(right: i == 3 ? 0 : 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

// ---------- Gradient album art ----------

class _ArtSpec {
  const _ArtSpec({
    required this.base,
    required this.baseStops,
    required this.begin,
    required this.end,
    required this.blobs,
    required this.name,
  });

  final List<Color> base;
  final List<double> baseStops;
  final Alignment begin;
  final Alignment end;
  final List<_Blob> blobs;
  final String name;
}

class _Blob {
  const _Blob(this.center, this.color, this.radius);

  final Alignment center;
  final Color color;
  final double radius;
}

const List<_ArtSpec> _arts = <_ArtSpec>[
  _ArtSpec(
    name: 'NOCTURNE',
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    base: <Color>[Color(0xFF0A0F1C), Color(0xFF111A33), Color(0xFF070A12)],
    baseStops: <double>[0, 0.55, 1],
    blobs: <_Blob>[
      _Blob(Alignment(0.44, -0.52), Color(0xC79AF4D2), 0.18),
      _Blob(Alignment(-0.4, 0.6), Color(0xFF2E4BFF), 0.62),
    ],
  ),
  _ArtSpec(
    name: 'BLOOM',
    begin: Alignment(-0.8, -1),
    end: Alignment(0.8, 1),
    base: <Color>[Color(0xFF5C142B), Color(0xFFD64B58), Color(0xFFF2A06F)],
    baseStops: <double>[0, 0.58, 1],
    blobs: <_Blob>[
      _Blob(Alignment(0.4, 0.36), Color(0xCCFFD0A6), 0.28),
      _Blob(Alignment(-0.6, -0.6), Color(0xFFFF7B6E), 0.55),
    ],
  ),
  _ArtSpec(
    name: 'TIDES',
    begin: Alignment(-0.35, -1),
    end: Alignment(0.35, 1),
    base: <Color>[Color(0xFF063A46), Color(0xFF0A6977), Color(0xFF041B25)],
    baseStops: <double>[0, 0.52, 1],
    blobs: <_Blob>[
      _Blob(Alignment(-0.44, -0.48), Color(0xCCC3FFEF), 0.17),
      _Blob(Alignment(0.48, 0.48), Color(0xFF1F7AA3), 0.6),
    ],
  ),
  _ArtSpec(
    name: 'STATIC',
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    base: <Color>[Color(0xFF101310), Color(0xFF1A2118), Color(0xFF060806)],
    baseStops: <double>[0, 0.58, 1],
    blobs: <_Blob>[
      _Blob(Alignment(0.44, -0.4), Color(0xF2D0FF5C), 0.16),
    ],
  ),
  _ArtSpec(
    name: 'VELVET',
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    base: <Color>[Color(0xFF2A0C27), Color(0xFF4C123F), Color(0xFF140713)],
    baseStops: <double>[0, 0.56, 1],
    blobs: <_Blob>[
      _Blob(Alignment(0.32, -0.44), Color(0x99FFA8D1), 0.26),
      _Blob(Alignment(-0.52, 0.48), Color(0xFF6D1F5B), 0.58),
    ],
  ),
  _ArtSpec(
    name: 'GOLDEN',
    begin: Alignment(-0.8, -1),
    end: Alignment(0.8, 1),
    base: <Color>[Color(0xFF4B2B11), Color(0xFFD69A45), Color(0xFFF4D9A1)],
    baseStops: <double>[0, 0.55, 1],
    blobs: <_Blob>[
      _Blob(Alignment(-0.52, -0.56), Color(0xE6FFEEC2), 0.2),
      _Blob(Alignment(0.44, 0.6), Color(0xFFB06A22), 0.52),
    ],
  ),
  _ArtSpec(
    name: 'AFTERGLOW',
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    base: <Color>[Color(0xFF0E1030), Color(0xFF29307F), Color(0xFF0B0C1D)],
    baseStops: <double>[0, 0.54, 1],
    blobs: <_Blob>[
      _Blob(Alignment(0.56, -0.6), Color(0xCCFFBFAA), 0.2),
      _Blob(Alignment(-0.6, 0.6), Color(0xFF5646D8), 0.6),
    ],
  ),
];

int auroraArtIndex(String seed) {
  final hash = md5Hex(seed.isEmpty ? 'flm' : seed);
  return int.parse(hash.substring(0, 6), radix: 16) % _arts.length;
}

/// Deterministic gradient placeholder mirroring .art a1–a7.
class GradientArt extends StatelessWidget {
  const GradientArt({
    super.key,
    required this.seed,
    this.radius = 12,
    this.width,
    this.height,
    this.mark = '',
    this.showMark = false,
    this.decorate = false,
  });

  final String seed;
  final double radius;
  final double? width;
  final double? height;
  final String mark;
  final bool showMark;
  final bool decorate;

  @override
  Widget build(BuildContext context) {
    final spec = _arts[auroraArtIndex(seed)];
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: LayoutBuilder(
        builder: (context, constraints) {
          // Resolve the effective pixel size so marks and decorations scale
          // correctly even when this widget is unbounded on one axis.
          final double size;
          if (width != null && height != null) {
            size = math.min(width!, height!);
          } else if (width != null) {
            size = width!;
          } else if (height != null) {
            size = height!;
          } else {
            size = math.min(
              constraints.maxWidth.isFinite ? constraints.maxWidth : 48.0,
              constraints.maxHeight.isFinite ? constraints.maxHeight : 48.0,
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: spec.begin,
                    end: spec.end,
                    colors: spec.base,
                    stops: spec.baseStops,
                  ),
                ),
              ),
              for (final blob in spec.blobs)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: blob.center,
                        radius: blob.radius,
                        colors: <Color>[blob.color, blob.color.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ),
              if (decorate)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ArtDecoPainter(index: _arts.indexOf(spec), pixelSize: size),
                  ),
                ),
              if (showMark)
                Positioned(
                  left: size * 0.1,
                  bottom: size * 0.08,
                  child: Text(
                    (mark.isEmpty ? spec.name : mark).toUpperCase(),
                    style: TextStyle(
                      fontSize: math.max(7, size * 0.045),
                      fontWeight: FontWeight.w800,
                      letterSpacing: size * 0.012,
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.78),
                      shadows: const <Shadow>[Shadow(color: Color(0x59000000), blurRadius: 5)],
                    ),
                  ),
                ),
            ],
          );
        },
        ),
      ),
    );
  }
}

class _ArtDecoPainter extends CustomPainter {
  _ArtDecoPainter({required this.index, required this.pixelSize});

  final int index;
  final double pixelSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (pixelSize < 70) return;
    final paint = Paint()..style = PaintingStyle.stroke;
    switch (index) {
      case 0: // NOCTURNE — orbit ring, right edge
        paint
          ..color = const Color(0x7A9AF4D2)
          ..strokeWidth = 1;
        canvas.drawCircle(
          Offset(size.width * 1.02, size.height * 0.34),
          size.shortestSide * 0.34,
          paint,
        );
      case 1: // BLOOM — soft dark moon, bottom-left
        paint.style = PaintingStyle.fill;
        paint.color = const Color(0x73180812);
        canvas.drawCircle(Offset(size.width * 0.06, size.height * 1.0), size.shortestSide * 0.26, paint);
      case 2: // TIDES — diagonal light stripes
        paint.color = Colors.white.withValues(alpha: 0.07);
        paint.strokeWidth = 1;
        for (double d = -size.height; d < size.width; d += 14) {
          canvas.drawLine(Offset(d, 0), Offset(d + size.height * 0.42, size.height), paint);
        }
      case 3: // STATIC — perspective grid
        paint.color = const Color(0x26D0FF5C);
        paint.strokeWidth = 0.7;
        final top = size.height * 0.42;
        for (int i = 0; i < 6; i += 1) {
          final y = top + (size.height - top) * (i / 5);
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
        for (int i = 0; i < 7; i += 1) {
          final x = size.width * (i / 6);
          canvas.drawLine(Offset(size.width * 0.5, top), Offset(x, size.height), paint);
        }
      case 4: // VELVET — blurred rose disc
        paint.style = PaintingStyle.fill;
        paint.color = Colors.white.withValues(alpha: 0.13);
        canvas.drawCircle(Offset(size.width * 0.46, size.height * 0.42), size.shortestSide * 0.24, paint);
      case 5: // GOLDEN — concentric vinyl rings
        paint.color = const Color(0x59371E0A);
        paint.strokeWidth = 1;
        final center = Offset(size.width * 1.06, size.height * -0.06);
        for (int i = 1; i <= 3; i += 1) {
          canvas.drawCircle(center, size.shortestSide * (0.18 + i * 0.1), paint);
        }
      case 6: // AFTERGLOW — shine band
        final shine = Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0x00FFFFFF), Color(0x1CFFFFFF), Color(0x00FFFFFF)],
          ).createShader(Offset.zero & size);
        canvas.drawRect(Offset.zero & size, shine);
    }
  }

  @override
  bool shouldRepaint(_ArtDecoPainter old) => old.index != index || old.pixelSize != pixelSize;
}

// ---------- Floating navbar ----------

class FlmNavBar extends StatelessWidget {
  const FlmNavBar({
    super.key,
    this.leading,
    this.title,
    this.trailing,
    this.centered = true,
  });

  final Widget? leading;
  final String? title;
  final List<Widget>? trailing;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, top + 8, 12, 0),
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: 8),
          ],
          Expanded(
            child: title == null
                ? const SizedBox.shrink()
                : Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: centered ? TextAlign.center : TextAlign.start,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: textFor(context).withValues(alpha: 0.72),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          if (trailing != null)
            Row(mainAxisSize: MainAxisSize.min, children: trailing!),
        ],
      ),
    );
  }
}

// ---------- Sheets ----------

/// Opens a Quiet Aurora bottom sheet; content scrolls on its own.
Future<T?> showFlmSheet<T>(
  BuildContext context, {
  required String title,
  Widget? titleTrailing,
  required Widget child,
  double maxHeight = 0.82,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x66000000),
    builder: (sheetContext) => _FlmSheet(
      title: title,
      titleTrailing: titleTrailing,
      maxHeight: maxHeight,
      child: child,
    ),
  );
}

class _FlmSheet extends StatelessWidget {
  const _FlmSheet({
    required this.title,
    required this.child,
    this.titleTrailing,
    this.maxHeight = 0.82,
  });

  final String title;
  final Widget child;
  final Widget? titleTrailing;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * maxHeight,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: panelFor(context),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: lineStrongColor(context))),
              boxShadow: const <BoxShadow>[
                BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, -12)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: faintFor(context).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: textFor(context),
                          ),
                        ),
                      ),
                      if (titleTrailing != null) titleTrailing!,
                    ],
                  ),
                ),
                Flexible(child: child),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon + label action row inside sheets (.sheet-item).
class SheetAction extends StatelessWidget {
  const SheetAction({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    this.danger = false,
    this.accentIcon = false,
    this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool danger;
  final bool accentIcon;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? coralFor(context)
        : accentIcon
            ? accentFor(context)
            : textFor(context);
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2.5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: danger
                    ? coralFor(context).withValues(alpha: 0.11)
                    : surface2For(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: lineColor(context)),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: danger ? coralFor(context) : textFor(context),
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 11, color: faintFor(context)),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// Radio-style row for option sheets (theme / quality / play mode).
class OptionRow extends StatelessWidget {
  const OptionRow({
    super.key,
    required this.label,
    required this.active,
    this.caption,
    this.icon,
    required this.onTap,
  });

  final String label;
  final bool active;
  final String? caption;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: active ? accentSoftColor(context) : surface2For(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? accentBorderColor(context) : lineColor(context),
          ),
        ),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 17, color: active ? accentFor(context) : mutedFor(context)),
              const SizedBox(width: 11),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: active ? accentFor(context) : textFor(context),
                    ),
                  ),
                  if (caption != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(caption!, style: TextStyle(fontSize: 11, color: faintFor(context))),
                  ],
                ],
              ),
            ),
            if (active)
              Icon(CupertinoIcons.checkmark_circle_fill, size: 19, color: accentFor(context)),
          ],
        ),
      ),
    );
  }
}

/// Primary / ghost button, matching `.btn` in the design study (solid accent
/// fill, 14px rounded rect, soft accent glow).
class AuroraButton extends StatelessWidget {
  const AuroraButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.expand = false,
    this.secondary = false,
    this.square = false,
    this.height = 45,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool expand;
  final bool secondary;
  final bool square;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final Widget content;
    if (label == null && icon != null) {
      content = Icon(
        icon,
        size: height * 0.4,
        color: secondary
            ? (enabled ? textFor(context) : faintFor(context))
            : (enabled ? accentInkFor(context) : faintFor(context)),
      );
    } else {
      content = Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(
              icon,
              size: 17,
              color: secondary
                  ? (enabled ? textFor(context) : faintFor(context))
                  : (enabled ? accentInkFor(context) : faintFor(context)),
            ),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Text(
              label ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
                color: secondary
                    ? (enabled ? textFor(context) : faintFor(context))
                    : (enabled ? accentInkFor(context) : faintFor(context)),
              ),
            ),
          ),
        ],
      );
    }

    // `.btn` in the design study: a 14px rounded rect, not a full pill.
    final borderRadius = BorderRadius.circular(square ? 13 : 14);
    final filled = !secondary && enabled;

    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AuroraMotion.quick,
        height: height,
        width: square ? height : null,
        padding: square ? null : const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          color: filled
              ? accentFor(context)
              : secondary || !enabled
                  ? surface2For(context)
                  : null,
          border: Border.all(
            color: filled
                ? Colors.transparent
                : lineColor(context),
          ),
          boxShadow: filled
              ? <BoxShadow>[
                  BoxShadow(
                    color: accentFor(context).withValues(alpha: 0.20),
                    blurRadius: 26,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: content,
      ),
    );
  }
}

/// Thin card container used across library/settings rows.
class AuroraCard extends StatelessWidget {
  const AuroraCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: surfaceFor(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: lineColor(context)),
        ),
        child: child,
      ),
    );
  }
}

// ---------- Toast ----------

OverlayEntry? _toastEntry;

/// Centered floating toast matching the design's #toast element.
void flmToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _toastEntry?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FlmToast(
      message: message,
      onDismiss: () {
        if (_toastEntry == entry) _toastEntry = null;
        entry.remove();
      },
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
}

class _FlmToast extends StatefulWidget {
  const _FlmToast({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  State<_FlmToast> createState() => _FlmToastState();
}

class _FlmToastState extends State<_FlmToast> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future<void>.delayed(const Duration(milliseconds: 1900), () async {
      if (!mounted) return;
      await _controller.reverse();
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width - 60;
    final radius = BorderRadius.circular(12);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(
          left: 30,
          right: 30,
          bottom: MediaQuery.paddingOf(context).bottom + 96,
        ),
        child: FadeTransition(
          opacity: _controller,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.28),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: _controller, curve: AuroraMotion.spring)),
            child: Material(
              type: MaterialType.transparency,
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xED0F1317),
                      borderRadius: radius,
                      border: Border.all(color: const Color(0x1AFFFFFF)),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Color(0x4D000000), blurRadius: 30, offset: Offset(0, 12)),
                      ],
                    ),
                    child: Text(
                      widget.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                        color: AppColors.darkText,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered styled confirm dialog (.dialog) — replaces AlertDialog.
Future<bool> flmConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return Material(
        type: MaterialType.transparency,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 23),
            child: _FlmDialogShell(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: textFor(dialogContext),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.55,
                      color: mutedFor(dialogContext),
                    ),
                  ),
                  const SizedBox(height: 17),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      _DialogBtn(
                        label: cancelLabel,
                        onTap: () => Navigator.pop(dialogContext, false),
                      ),
                      const SizedBox(width: 8),
                      _DialogBtn(
                        label: confirmLabel,
                        danger: danger,
                        primary: !danger,
                        onTap: () => Navigator.pop(dialogContext, true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  return result ?? false;
}

/// Centered styled input dialog (.dialog with .dialog-input).
/// Returns the entered text, or null when cancelled.
Future<String?> flmInputDialog(
  BuildContext context, {
  required String title,
  String? message,
  String placeholder = '',
  String initialValue = '',
  String cancelLabel = '取消',
  String confirmLabel = '确定',
}) async {
  final controller = TextEditingController(text: initialValue);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return Material(
        type: MaterialType.transparency,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 23),
            child: _FlmDialogShell(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: textFor(dialogContext),
                    ),
                  ),
                  if (message != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.55,
                        color: mutedFor(dialogContext),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: TextStyle(fontSize: 13, color: textFor(dialogContext)),
                    decoration: InputDecoration(
                      hintText: placeholder,
                      hintStyle: TextStyle(color: faintFor(dialogContext)),
                      filled: true,
                      fillColor: surface2For(dialogContext),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 11),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: BorderSide(color: lineColor(dialogContext)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: BorderSide(color: accentFor(dialogContext)),
                      ),
                    ),
                    onSubmitted: (value) =>
                        Navigator.pop(dialogContext, value),
                  ),
                  const SizedBox(height: 17),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      _DialogBtn(
                        label: cancelLabel,
                        onTap: () => Navigator.pop(dialogContext),
                      ),
                      const SizedBox(width: 8),
                      _DialogBtn(
                        label: confirmLabel,
                        primary: true,
                        onTap: () =>
                            Navigator.pop(dialogContext, controller.text),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  controller.dispose();
  return result;
}

class _FlmDialogShell extends StatelessWidget {
  const _FlmDialogShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 318,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: panelFor(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: lineColor(context)),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x73000000), blurRadius: 70, offset: Offset(0, 30)),
        ],
      ),
      child: child,
    );
  }
}

class _DialogBtn extends StatelessWidget {
  const _DialogBtn({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final active = primary || danger;
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 35,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: danger
              ? coralFor(context)
              : primary
                  ? accentFor(context)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? Colors.transparent : lineColor(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: danger
                ? Colors.white
                : primary
                    ? accentInkFor(context)
                    : mutedFor(context),
          ),
        ),
      ),
    );
  }
}
