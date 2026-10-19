import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../models/custom_source.dart';
import '../models/song.dart';
import 'http_bridge.dart';

class SourceEngine {
  SourceEngine(this._http) {
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
            final completer = _pageReady;
            if (completer != null && !completer.isCompleted) completer.complete();
          },
          onWebResourceError: (error) {
            final completer = _pageReady;
            if (completer != null && !completer.isCompleted) {
              completer.completeError(StateError('自定义源引擎加载失败: ${error.description}'));
            }
          },
        ),
      );
  }

  static const _key = 'flm_user_source_key';

  final HttpBridge _http;
  final WebViewController _controller = WebViewController();
  Completer<void>? _pageReady;
  Completer<SourceCapabilities>? _initCompleter;
  final Map<String, Completer<Map<String, dynamic>>> _requestWaiters =
      <String, Completer<Map<String, dynamic>>>{};
  final Map<String, int> _httpRequestIds = <String, int>{};

  CustomSourceInfo? _current;
  SourceCapabilities _capabilities = SourceCapabilities.empty();
  bool _loaded = false;

  WebViewController get controller => _controller;
  CustomSourceInfo? get current => _current;
  SourceCapabilities get capabilities => _capabilities;
  bool get hasSource => _current != null && !_capabilities.isEmpty;

  Future<void> load() async {
    if (_loaded) return;
    _pageReady = Completer<void>();
    await _controller.loadFlutterAsset('assets/js/user_source.html');
    await _pageReady!.future.timeout(const Duration(seconds: 30));
    _loaded = true;
  }

  Future<SourceCapabilities> activate(CustomSourceInfo info, String script) async {
    await load();
    _pageReady = Completer<void>();
    await _controller.loadFlutterAsset('assets/js/user_source.html');
    await _pageReady!.future.timeout(const Duration(seconds: 30));

    _current = info;
    _capabilities = SourceCapabilities.empty();
    for (final waiter in _requestWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('自定义源已切换'));
      }
    }
    _requestWaiters.clear();

    final initCompleter = Completer<SourceCapabilities>();
    _initCompleter = initCompleter;

    await _controller.runJavaScript(
      'FlmSource.prepare(${jsonEncode(<String, dynamic>{
        'key': _key,
        'id': info.id,
        'name': info.name,
        'description': info.description,
        'version': info.version,
        'author': info.author,
        'homepage': info.homepage,
        'script': script,
      })});',
    );

    try {
      await _controller.runJavaScript(script);
    } catch (error) {
      if (!initCompleter.isCompleted) {
        initCompleter.completeError(StateError('自定义源脚本执行失败: $error'));
      }
    }

    return initCompleter.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw TimeoutException('自定义源初始化超时'),
    );
  }

  void clear() {
    _current = null;
    _capabilities = SourceCapabilities.empty();
  }

  bool supports(String source, String action) => _capabilities.supports(source, action);

  List<String> qualitysFor(String source) => _capabilities.qualitysFor(source);

  Future<Map<String, dynamic>> requestMusicUrl({
    required String source,
    required String quality,
    required Song song,
  }) {
    return _requestAction(
      source: source,
      action: 'musicUrl',
      info: <String, dynamic>{
        'type': quality,
        'musicInfo': song.toLegacyInfo(),
      },
    );
  }

  Future<Map<String, dynamic>> requestLyric({
    required String source,
    required Song song,
  }) {
    return _requestAction(
      source: source,
      action: 'lyric',
      info: <String, dynamic>{
        'musicInfo': song.toLegacyInfo(),
      },
    );
  }

  Future<Map<String, dynamic>> requestPic({
    required String source,
    required Song song,
  }) {
    return _requestAction(
      source: source,
      action: 'pic',
      info: <String, dynamic>{
        'musicInfo': song.toLegacyInfo(),
      },
    );
  }

  Future<Map<String, dynamic>> _requestAction({
    required String source,
    required String action,
    required Map<String, dynamic> info,
  }) async {
    final currentInfo = _current;
    if (currentInfo == null) throw StateError('尚未启用自定义源');
    if (!_capabilities.supports(source, action)) {
      throw StateError('当前自定义源不支持 ${source.toUpperCase()} 的 $action');
    }

    final requestKey = 'flm_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    _requestWaiters[requestKey] = completer;

    final payload = <String, dynamic>{
      'requestKey': requestKey,
      'data': <String, dynamic>{
        'source': source,
        'action': action,
        'info': info,
      },
    };

    await _controller.runJavaScript(
      '__lx_native__(${jsonEncode(_key)}, \'request\', ${jsonEncode(jsonEncode(payload))});',
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _requestWaiters.remove(requestKey);
        throw TimeoutException('自定义源响应超时');
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
    if (data['type'] != 'sourceNative') return;

    final action = '${data['action'] ?? ''}';
    final payload = data['data'] is Map
        ? Map<String, dynamic>.from(data['data'] as Map)
        : <String, dynamic>{};
    final key = '${data['key'] ?? _key}';

    switch (action) {
      case 'init':
        _handleInit(payload);
        break;
      case 'request':
        await _handleHttpRequest(key, payload);
        break;
      case 'cancelRequest':
        final requestKey = '${payload['requestKey'] ?? ''}';
        final id = _httpRequestIds.remove(requestKey) ?? requestKey.hashCode;
        _http.cancel(id);
        break;
      case 'response':
        _handleSourceResponse(payload);
        break;
      case 'showUpdateAlert':
        break;
      default:
        break;
    }
  }

  void _handleInit(Map<String, dynamic> payload) {
    final completer = _initCompleter;
    if (completer == null || completer.isCompleted) return;
    if (payload['status'] == true) {
      final info = payload['info'];
      final sources = info is Map && info['sources'] is Map
          ? Map<String, dynamic>.from(info['sources'] as Map)
          : <String, dynamic>{};
      _capabilities = SourceCapabilities.fromJson(sources);
      completer.complete(_capabilities);
    } else {
      completer.completeError(
        StateError('${payload['errorMessage'] ?? '自定义源初始化失败'}'),
      );
    }
  }

  Future<void> _handleHttpRequest(String key, Map<String, dynamic> payload) async {
    final requestKey = '${payload['requestKey'] ?? ''}';
    final id = requestKey.hashCode & 0x7fffffff;
    _httpRequestIds[requestKey] = id;
    try {
      final options = payload['options'] is Map
          ? Map<String, dynamic>.from(payload['options'] as Map)
          : <String, dynamic>{};
      final response = await _http.request(id, '${payload['url']}', options);
      if (options['binary'] != true && response['body'] is String) {
        final text = response['body'] as String;
        try {
          response['body'] = jsonDecode(text);
        } catch (_) {
          // Keep plain text (HTML, XML, LRC ...).
        }
      }
      await _controller.runJavaScript(
        '__lx_native__(${jsonEncode(key)}, \'response\', ${jsonEncode(jsonEncode(<String, dynamic>{
          'requestKey': requestKey,
          'status': true,
          'result': response,
        }))});',
      );
    } catch (error) {
      await _controller.runJavaScript(
        '__lx_native__(${jsonEncode(key)}, \'response\', ${jsonEncode(jsonEncode(<String, dynamic>{
          'requestKey': requestKey,
          'status': false,
          'errorMessage': '$error',
        }))});',
      );
    } finally {
      _httpRequestIds.remove(requestKey);
    }
  }

  void _handleSourceResponse(Map<String, dynamic> payload) {
    final requestKey = '${payload['requestKey'] ?? ''}';
    final completer = _requestWaiters.remove(requestKey);
    if (completer == null || completer.isCompleted) return;
    if (payload['status'] == true) {
      final result = payload['result'];
      if (result is Map) {
        completer.complete(Map<String, dynamic>.from(result));
      } else {
        completer.completeError(StateError('自定义源返回了无效数据'));
      }
    } else {
      completer.completeError(
        StateError('${payload['errorMessage'] ?? '自定义源请求失败'}'),
      );
    }
  }
}
