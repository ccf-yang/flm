import 'package:webview_flutter/webview_flutter.dart';

import '../models/custom_source.dart';
import '../models/song.dart';

/// Common surface of a custom-source sandbox.
///
/// Two implementations exist: `SourceEngine` runs the script inside a
/// WKWebView, `JsSourceEngine` runs the very same script inside an in-process
/// JavaScript engine. The latter keeps resolving links while the app is
/// backgrounded (iOS freezes the WKWebView content process behind the lock
/// screen), so it is preferred whenever it starts successfully.
abstract class MusicSourceEngine {
  void Function(String title, Map<String, Object?> fields)? onEvent;

  CustomSourceInfo? get current;
  SourceCapabilities get capabilities;

  /// Non-null only for engines that need a mounted [WebViewWidget].
  WebViewController? get controller;

  Future<SourceCapabilities> activate(CustomSourceInfo info, String script);

  Future<Map<String, dynamic>> requestMusicUrl({
    required String source,
    required String quality,
    required Song song,
  });

  Future<Map<String, dynamic>> requestLyric({
    required String source,
    required Song song,
  });

  Future<Map<String, dynamic>> requestPic({
    required String source,
    required Song song,
  });

  void clear();
}
