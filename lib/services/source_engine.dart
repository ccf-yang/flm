import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/custom_source.dart';
import '../models/song.dart';
import 'http_bridge.dart';
import 'music_source_engine.dart';

class SourceEngine implements MusicSourceEngine {
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
            // Ignore failed sub-resources; only the main document matters.
            if (error.isForMainFrame != true) return;
            onEvent?.call('沙箱页面加载失败', <String, Object?>{
              '描述': error.description,
              '代码': error.errorCode,
            });
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
  String? _script;
  bool _loaded = false;
  int _consecutiveTimeouts = 0;
  Future<void>? _recovery;

  /// Optional mirror of engine-level events (timeouts, recovery) for the
  /// in-app debug page.
  @override
  void Function(String title, Map<String, Object?> fields)? onEvent;

  @override
  WebViewController get controller => _controller;

  /// iOS suspends the WKWebView content process once the app is backgrounded, so
  /// a script running here stops answering `musicUrl` until the user unlocks and
  /// opens the app. Android has no such freeze — the renderer keeps working while
  /// the playback service holds the process alive.
  @override
  bool get canRunInBackground => !Platform.isIOS;

  @override
  CustomSourceInfo? get current => _current;
  @override
  SourceCapabilities get capabilities => _capabilities;
  bool get hasSource => _current != null && !_capabilities.isEmpty;

  Future<void> load() async {
    if (_loaded) return;
    _pageReady = Completer<void>();
    await _controller.loadFlutterAsset('assets/js/user_source.html');
    await _pageReady!.future.timeout(const Duration(seconds: 30));
    _loaded = true;
  }

  @override
  Future<SourceCapabilities> activate(CustomSourceInfo info, String script) async {
    // The sandbox's `lx_setup` deletes itself after running (see
    // assets/js/user_source.html), so a source can only ever be prepared on a
    // *freshly loaded* page. Always reload here; the one-time cost per source
    // is paid at init, never on the play path.
    _pageReady = Completer<void>();
    await _controller.loadFlutterAsset('assets/js/user_source.html');
    await _pageReady!.future.timeout(const Duration(seconds: 30));
    // The page is up and `lx_setup` is armed, so this sandbox is ready for every
    // later request. Forgetting this line made `_loaded` stay false for the whole
    // life of a WebView source (nothing else ever calls `load()`), which meant
    // *every* musicUrl request reloaded the page and re-ran setup. That is cheap
    // in the foreground — one observed round trip was 400–950 ms — but fatal in
    // the background: an off-screen WebView gets no `onPageFinished` once the
    // renderer is throttled, so each request waited the full 30 s of the page-ready
    // timeout and died there, and the reload also threw every other in-flight
    // request out with 「自定义源已切换». Executing JavaScript in an already loaded
    // page *does* keep working behind the lock screen (measured 956 ms), which is
    // exactly the path this flag now keeps alive.
    _loaded = true;

    _current = info;
    _script = script;
    _capabilities = SourceCapabilities.empty();
    _consecutiveTimeouts = 0;
    for (final waiter in _requestWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('自定义源已切换'));
      }
    }
    _requestWaiters.clear();

    final initCompleter = Completer<SourceCapabilities>();
    _initCompleter = initCompleter;

    try {
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
    } catch (error) {
      if (!initCompleter.isCompleted) {
        initCompleter.completeError(StateError('自定义源环境准备失败: $error'));
      }
      return initCompleter.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('自定义源初始化超时'),
      );
    }

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

  @override
  void clear() {
    _current = null;
    _capabilities = SourceCapabilities.empty();
  }

  bool supports(String source, String action) => _capabilities.supports(source, action);

  List<String> qualitysFor(String source) => _capabilities.qualitysFor(source);

  @override
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

  @override
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

  @override
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

  /// Reload the sandbox if a previous call timed out (a suspended or reclaimed
  /// WKWebView never answers again until its page is recreated). Concurrent
  /// requests share one recovery instead of reloading the page twice.
  Future<void> _ensureReady() {
    if (_loaded) return Future<void>.value();
    return _recovery ??= _recover().whenComplete(() => _recovery = null);
  }

  Future<void> _recover() async {
    final info = _current;
    final script = _script;
    if (info != null && script != null) {
      await activate(info, script);
    } else {
      await load();
    }
  }

  Future<Map<String, dynamic>> _requestAction({
    required String source,
    required String action,
    required Map<String, dynamic> info,
  }) async {
    await _ensureReady();
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

    try {
      await _controller.runJavaScript(
        '__lx_native__(${jsonEncode(_key)}, \'request\', ${jsonEncode(jsonEncode(payload))});',
      );
    } catch (error) {
      _requestWaiters.remove(requestKey);
      throw StateError('自定义源请求发送失败: $error');
    }

    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _requestWaiters.remove(requestKey);
      // A single timeout is usually a slow/dead platform *inside* the script,
      // not a dead WebView. Only a second consecutive timeout is treated as
      // sandbox suspension and triggers a full reload + re-activation. (The
      // sandbox's lx_setup is one-shot per page load, so reloading eagerly on
      // first timeout used to leave the engine permanently broken.)
      _consecutiveTimeouts++;
      onEvent?.call('音源超时 ${_current?.name ?? ''}', <String, Object?>{
        'action': '$source/$action',
        'quality': '${info['type'] ?? ''}',
        '连续超时': _consecutiveTimeouts,
      });
      if (_consecutiveTimeouts >= 2) {
        _loaded = false;
        unawaited(_ensureReady());
      }
      throw TimeoutException('自定义源响应超时');
    }
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
        // 沙箱端 nativeCall('cancelRequest', requestKey) 直接把 requestKey
        // 字符串作为 data 发送，不是对象。
        final raw = decoded['data'];
        final requestKey = raw is String
            ? raw
            : '${payload['requestKey'] ?? ''}';
        final id = _httpRequestIds.remove(requestKey) ?? -1;
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
    final id = _http.nextRequestId();
    _httpRequestIds[requestKey] = id;
    // 音源脚本沙箱 (user_source.html) 的 handleNativeResponse 期望的字段是
    // { requestKey, error, response }，与 lx-music-mobile 的
    // SendResponseParams 完全一致；这里曾错发成 { status, result }，
    // 导致脚本拿到的 response 为 undefined，回调抛错后整条 musicUrl
    // 链路永远不 resolve，宿主只能等到超时（表现为"卡在获取音频地址"）。
    dynamic result;
    String? failure;
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
      result = response;
    } catch (error) {
      failure = '$error';
    } finally {
      _httpRequestIds.remove(requestKey);
    }

    try {
      await _controller.runJavaScript(
        '__lx_native__(${jsonEncode(key)}, \'response\', ${jsonEncode(jsonEncode(<String, dynamic>{
          'requestKey': requestKey,
          'error': failure,
          'response': failure == null ? result : null,
        }))});',
      );
    } catch (error) {
      // runJavaScript failing outright means the content process is gone.
      _loaded = false;
      onEvent?.call('音源投递失败 ${_current?.name ?? ''}', <String, Object?>{
        '错误': '$error',
      });
      debugPrint('[flm][source-engine] deliver http response failed: $error');
    }
  }

  void _handleSourceResponse(Map<String, dynamic> payload) {
    final requestKey = '${payload['requestKey'] ?? ''}';
    final completer = _requestWaiters.remove(requestKey);
    if (completer == null || completer.isCompleted) return;
    // Any reply from the sandbox proves it is alive.
    _consecutiveTimeouts = 0;
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
