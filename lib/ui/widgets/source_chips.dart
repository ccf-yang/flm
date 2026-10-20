import 'package:flutter/material.dart' hide Chip;

import '../../models/app_settings.dart';
import '../kit.dart';

const List<Map<String, String>> kSourceOptions = <Map<String, String>>[
  <String, String>{'id': 'all', 'name': '聚合'},
  <String, String>{'id': 'kw', 'name': '酷我'},
  <String, String>{'id': 'kg', 'name': '酷狗'},
  <String, String>{'id': 'tx', 'name': 'QQ'},
  <String, String>{'id': 'wy', 'name': '网易'},
  <String, String>{'id': 'mg', 'name': '咪咕'},
];

/// Chips the settings allow: the master switch hides the whole row, and the
/// platform selection decides which entries stay as categories.
List<Map<String, String>> platformOptionsFor(
  AppSettings settings, {
  bool allowAggregate = true,
}) {
  final ids = settings.visiblePlatformIds(allowAggregate: allowAggregate);
  return kSourceOptions
      .where((option) => ids.contains(option['id']))
      .toList();
}

class SourceChips extends StatelessWidget {
  const SourceChips({
    super.key,
    required this.value,
    required this.onChanged,
    this.options = kSourceOptions,
    this.padding = const EdgeInsets.symmetric(horizontal: kGutter),
    this.settings,
    this.allowAggregate = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final List<Map<String, String>> options;
  final EdgeInsetsGeometry padding;

  /// When given, the row follows 设置 → 音乐平台 instead of [options] and collapses
  /// by itself if fewer than two platforms are left to choose from.
  final AppSettings? settings;
  final bool allowAggregate;

  @override
  Widget build(BuildContext context) {
    final visible =
        settings == null ? options : platformOptionsFor(settings!, allowAggregate: allowAggregate);
    if (visible.length < 2) return const SizedBox.shrink();
    return ChipRow(
      padding: padding,
      children: visible.map((option) {
        final id = option['id'] ?? '';
        return Chip(
          label: option['name'] ?? id,
          active: id == value,
          onTap: () => onChanged(id),
        );
      }).toList(),
    );
  }
}
