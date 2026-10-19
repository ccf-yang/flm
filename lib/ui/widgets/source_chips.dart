import 'package:flutter/material.dart';

import '../../core/theme.dart';

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
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final String value;
  final ValueChanged<String> onChanged;
  final List<Map<String, String>> options;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final option = options[index];
          final active = option['id'] == value;
          return GestureDetector(
            onTap: () => onChanged(option['id']!),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? AppColors.accent : surfaceHighFor(context),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                option['name'] ?? option['id'] ?? '',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? Colors.white : textFor(context),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
