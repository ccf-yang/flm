import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import 'http_bridge.dart';

class OnlineEngine {
  OnlineEngine(this._http) {
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlmBridge',
        onMessageReceived: (message) {
          _onMessage(message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!_ready.isCompleted) _ready.complete();
          },
          onWebResourceError: (error) {
            if (!_ready.isCompleted) {
              _ready.completeError(StateError('在线引擎加载失败: ${error.description}'));
            }
          },
        ),
      );
  }

  final HttpBridge _http;
  final WebViewController _controller = WebViewController();
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _sequence = 0;
  bool _loaded = false;

  WebViewController get controller => _controller;

  Future<void> load() async {
    if (_loaded) return;
    await _controller.loadFlutterAsset('assets/js/engine.html');
    await _ready.future.timeout(const Duration(seconds: 30));
    _loaded = true;
  }

  Future<dynamic> call(String action, [Map<String, dynamic> params = const <String, dynamic>{}]) async {
    await load();
    final id = ++_sequence;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      await _controller.runJavaScript(
        'LXEngine.dispatch($id, ${jsonEncode(action)}, ${jsonEncode(params)});',
      );
    } catch (error) {
      _pending.remove(id);
      rethrow;
    }
    return completer.future.timeout(
      const Duration(seconds: 35),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('在线请求超时');
      },
    );
  }

  Future<void> _onMessage(JavaScriptMessage message) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final data = Map<String, dynamic>.from(decoded);
    switch (data['type']) {
      case 'http':
        await _handleHttp(data);
        break;
      case 'httpCancel':
        _http.cancel((data['id'] as num?)?.toInt() ?? -1);
        break;
      case 'engineResult':
        _completeResult(data);
        break;
      case 'engineError':
        _completeError(data);
        break;
      default:
        break;
    }
  }

  Future<void> _handleHttp(Map<String, dynamic> data) async {
    final id = (data['id'] as num?)?.toInt() ?? -1;
    try {
      final response = await _http.request(
        id,
        '${data['url']}',
        data['options'] is Map
            ? Map<String, dynamic>.from(data['options'] as Map)
            : <String, dynamic>{},
      );
      await _controller.runJavaScript(
        'window.__flmHttpResolve($id, true, ${jsonEncode(response)});',
      );
    } catch (error) {
      await _controller.runJavaScript(
        'window.__flmHttpResolve($id, false, ${jsonEncode(<String, dynamic>{'message': '$error'})});',
      );
    }
  }

  void _completeResult(Map<String, dynamic> data) {
    final id = (data['id'] as num?)?.toInt() ?? -1;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(data['data']);
    }
  }

  void _completeError(Map<String, dynamic> data) {
    final id = (data['id'] as num?)?.toInt() ?? -1;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        StateError('${data['message'] ?? '在线请求失败'}'),
      );
    }
  }
}
