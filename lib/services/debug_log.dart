import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Ring buffer of request-level debug events shown on the debug page.
///
/// Everything (HTTP requests made for the source sandboxes, source
/// initialization/resolution, errors) is recorded with url, headers, body and
/// response, and each entry is separated by two blank lines so the raw dump
/// stays readable. Recording is gated on [enabled] at append time; turning the
/// switch off clears what was captured.
class DebugLog extends ChangeNotifier {
  DebugLog({required this.enabled});

  static const int _maxEntries = 200;
  static const int _maxBodyChars = 800;

  bool enabled;

  final Queue<String> _entries = Queue<String>();

  List<String> get entries => List<String>.unmodifiable(_entries);

  String get text => _entries.join('\n\n\n');

  void record(String title, Map<String, Object?> fields) {
    if (!enabled) return;
    final buffer = StringBuffer()
      ..writeln('[${_stamp()}] $title');
    fields.forEach((key, value) {
      if (value == null || '$value'.isEmpty) return;
      buffer.writeln('$key: ${_clip('$value')}');
    });
    _entries.add(buffer.toString());
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  void setEnabled(bool value) {
    enabled = value;
    if (!value) clear();
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
  }

  String _clip(String value) {
    final flat = value.replaceAll('\r', '');
    if (flat.length <= _maxBodyChars) return flat;
    return '${flat.substring(0, _maxBodyChars)}…(${flat.length} chars)';
  }
}
