import 'package:flutter/material.dart' hide Chip;

import '../kit.dart';

const List<Map<String, String>> kSourceOptions = <Map<String, String>>[
  <String, String>{'id': 'all', 'name': '聚合'},
  <String, String>{'id': 'kw', 'name': '酷我'},
  <String, String>{'id': 'kg', 'name': '酷狗'},
  <String, String>{'id': 'tx', 'name': 'QQ'},
  <String, String>{'id': 'wy', 'name': '网易'},
  <String, String>{'id': 'mg', 'name': '咪咕'},
];

class SourceChips extends StatelessWidget {
  const SourceChips({
    super.key,
    required this.value,
    required this.onChanged,
    this.options = kSourceOptions,
    this.padding = const EdgeInsets.symmetric(horizontal: kGutter),
  });

  final String value;
  final ValueChanged<String> onChanged;
  final List<Map<String, String>> options;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ChipRow(
      padding: padding,
      children: options.map((option) {
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
