import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'http_bridge.dart';
import 'debug_log.dart';

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
            // Sub-resource failures (fonts, favicons, source maps) must not
            // abort engine startup; only a failed main document is fatal.
            if (error.isForMainFrame != true) return;
            debugLog?.record('在线引擎页面加载失败', <String, Object?>{
              '描述': error.description,
              '代码': error.errorCode,
            });
            if (!_ready.isCompleted) {
              _ready.completeError(StateError('在线引擎加载失败: ${error.description}'));
            }
          },
        ),
      );
  }

  final HttpBridge _http;
  final WebViewController _controller = WebViewController();
  Completer<void> _ready = Completer<void>();
  Future<void>? _loadFuture;
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _sequence = 0;
  bool _loaded = false;
  String? _lastJsError;

  /// When set (and its switch is on), every engine call is mirrored to the
  /// in-app debug page.
  DebugLog? debugLog;

  WebViewController get controller => _controller;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _doLoad();
  }

  Future<void> _doLoad() async {
    try {
      _ready = Completer<void>();
      _lastJsError = null;
      await _controller.loadFlutterAsset('assets/js/engine.html');
      await _ready.future.timeout(const Duration(seconds: 30));

      dynamic ready;
      try {
        ready = await _controller.runJavaScriptReturningResult(
          '(function(){'
          'if (window.__flmEngineReady === true && typeof LXEngine !== "undefined") return true;'
          'var errors = window.__flmErrors || [];'
          'return errors.length ? errors.join(" | ") : "LXEngine is undefined";'
          '})()',
        );
      } catch (error) {
        throw StateError('在线引擎脚本无法执行: $error');
      }
      if (ready != true && ready != 'true') {
        final detail = _lastJsError == null ? '' : ' ($_lastJsError)';
        throw StateError('在线引擎启动失败: $ready$detail');
      }
      _loaded = true;
    } catch (error) {
      _loaded = false;
      _loadFuture = null;
      rethrow;
    }
  }

  Future<dynamic> call(String action, [Map<String, dynamic> params = const <String, dynamic>{}]) async {
    final startedAt = DateTime.now();
    final source = params['source'] ?? '';
    debugLog?.record('在线请求 $action · $source', <String, Object?>{
      '参数': params.entries
          .where((e) => e.key != 'song' && e.key != 'list' && e.key != 'page' && e.key != 'limit')
          .join(', '),
    });
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
      final detail = _lastJsError == null ? '' : ' ($_lastJsError)';
      debugLog?.record('在线请求失败 $action · $source', <String, Object?>{
        '原因': '$error$detail',
      });
      throw StateError('在线引擎执行失败: $error$detail');
    }
    try {
      final result = await completer.future.timeout(const Duration(seconds: 35));
      debugLog?.record(
          '在线完成 $action · $source', <String, Object?>{
        '耗时': '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      });
      return result;
    } on TimeoutException {
      _pending.remove(id);
      debugLog?.record('在线超时 $action · $source', <String, Object?>{
        '耗时': '${DateTime.now().difference(startedAt).inMilliseconds}ms',
        '动作': '标记引擎失效，下次调用重载页面',
      });
      // A timeout usually means the WKWebView was suspended in the background
      // or its content process was reclaimed by iOS. Force a reload on the
      // next call instead of silently timing out forever.
      _markStale();
      throw TimeoutException('在线请求超时');
    }
  }

  void _markStale() {
    _loaded = false;
    _loadFuture = null;
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
      case 'jsError':
        _lastJsError = '${data['message'] ?? 'unknown'}';
        debugPrint('[flm][online-engine] ${message.message}');
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
