import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/custom_source.dart';
import '../models/song.dart';
import 'http_bridge.dart';
import 'music_source_engine.dart';

/// Thrown when the in-process engine itself cannot start or run this script.
/// [SourceState] reacts by swapping the slot back to [SourceEngine] (WKWebView).
class JsEngineUnavailable implements Exception {
  const JsEngineUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs a custom-source (userApi) script inside an in-process JavaScript
/// runtime instead of a WKWebView.
///
/// Why this exists: iOS suspends the WKWebView content process as soon as the
/// app goes to the background, even though background audio keeps the *app*
/// alive. Resolving a play URL is a JS -> native HTTP -> JS round trip, so with
/// a WebView the second half of the round trip only runs after the app is
/// unlocked again: playback silently stops at the track boundary and resumes
/// when the user opens the app. QuickJS runs in the Dart isolate, which stays
/// alive while audio is playing, so the whole round trip keeps working behind
/// the lock screen.
///
/// The asset (`assets/js/user_source.html`) is the same bundle the WebView
/// loads; its inline scripts are extracted at runtime and evaluated in order,
/// so no separate build step is required. The browser globals the bundle needs
/// (`window`, timers, btoa/atob, TextEncoder, the FlmBridge channel) are
/// provided by [prelude].
class JsSourceEngine implements MusicSourceEngine {
  JsSourceEngine(this._http);

  static const String _key = 'flm_user_source_key';

  final HttpBridge _http;

  JavascriptRuntime? _runtime;
  Completer<SourceCapabilities>? _initCompleter;
  final Map<String, Completer<Map<String, dynamic>>> _requestWaiters =
      <String, Completer<Map<String, dynamic>>>{};
  final Map<String, int> _httpRequestIds = <String, int>{};
  final Map<int, Timer> _timers = <int, Timer>{};

  CustomSourceInfo? _current;
  SourceCapabilities _capabilities = SourceCapabilities.empty();
  bool _disposed = false;

  static List<String>? _sandboxScripts;

  @override
  void Function(String title, Map<String, Object?> fields)? onEvent;

  @override
  CustomSourceInfo? get current => _current;

  @override
  SourceCapabilities get capabilities => _capabilities;

  @override
  WebViewController? get controller => null;

  /// Browser surface the LX sandbox expects. Everything here is deliberately
  /// small: the bundle guards every optional browser API (`navigator`,
  /// `MutationObserver`, `localStorage`, `crypto.subtle`, ...) with `typeof`,
  /// so the only hard requirements are the bridge channel and timers.
  static const String prelude = r'''
(function () {
  var g = (typeof globalThis !== 'undefined') ? globalThis : this;
  if (typeof g.window === 'undefined') g.window = g;
  if (typeof g.global === 'undefined') g.global = g;

  function post(channel, value) {
    try { sendMessage(channel, value); } catch (_) {}
  }

  function noop() {}
  if (!g.console) g.console = {};
  if (!g.console.log) g.console.log = noop;
  if (!g.console.info) g.console.info = noop;
  if (!g.console.warn) g.console.warn = noop;
  if (!g.console.debug) g.console.debug = noop;
  if (!g.console.error) g.console.error = noop;

  var timers = {};
  var timerSeq = 0;
  g.__flmFireTimer = function (id) {
    var entry = timers[id];
    if (!entry) return;
    if (!entry.repeat) delete timers[id];
    try {
      entry.fn.apply(null, entry.args);
    } catch (error) {
      try { g.console.error(error && error.stack ? error.stack : error); } catch (_) {}
    }
  };
  g.setTimeout = function (fn, ms) {
    var args = Array.prototype.slice.call(arguments, 2);
    var id = ++timerSeq;
    timers[id] = { fn: fn, args: args, repeat: false };
    post('timer', JSON.stringify({ id: id, ms: Number(ms) || 0, repeat: false }));
    return id;
  };
  g.clearTimeout = function (id) {
    delete timers[id];
    post('timer', JSON.stringify({ id: id, cancel: true }));
  };
  g.setInterval = function (fn, ms) {
    var args = Array.prototype.slice.call(arguments, 2);
    var id = ++timerSeq;
    timers[id] = { fn: fn, args: args, repeat: true };
    post('timer', JSON.stringify({ id: id, ms: Number(ms) || 0, repeat: true }));
    return id;
  };
  g.clearInterval = g.clearTimeout;

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  if (typeof g.btoa !== 'function') {
    g.btoa = function (input) {
      var str = String(input);
      var out = '';
      var i = 0;
      while (i < str.length) {
        var c1 = str.charCodeAt(i++) & 0xff;
        if (i === str.length) {
          out += B64.charAt(c1 >> 2) + B64.charAt((c1 & 3) << 4) + '==';
          break;
        }
        var c2 = str.charCodeAt(i++) & 0xff;
        if (i === str.length) {
          out += B64.charAt(c1 >> 2)
            + B64.charAt(((c1 & 3) << 4) | (c2 >> 4))
            + B64.charAt((c2 & 15) << 2) + '=';
          break;
        }
        var c3 = str.charCodeAt(i++) & 0xff;
        out += B64.charAt(c1 >> 2)
          + B64.charAt(((c1 & 3) << 4) | (c2 >> 4))
          + B64.charAt(((c2 & 15) << 2) | (c3 >> 6))
          + B64.charAt(c3 & 63);
      }
      return out;
    };
  }
  if (typeof g.atob !== 'function') {
    g.atob = function (input) {
      var str = String(input).replace(/[^A-Za-z0-9+/=]/g, '');
      var out = '';
      var i = 0;
      while (i < str.length) {
        var e1 = B64.indexOf(str.charAt(i++));
        var e2 = B64.indexOf(str.charAt(i++));
        var e3 = B64.indexOf(str.charAt(i++));
        var e4 = B64.indexOf(str.charAt(i++));
        if (e1 < 0 || e2 < 0) break;
        out += String.fromCharCode(((e1 << 2) | (e2 >> 4)) & 0xff);
        if (e3 >= 0) {
          out += String.fromCharCode((((e2 & 15) << 4) | (e3 >> 2)) & 0xff);
          if (e4 >= 0) {
            out += String.fromCharCode((((e3 & 3) << 6) | e4) & 0xff);
          }
        }
      }
      return out;
    };
  }

  if (typeof g.TextEncoder === 'undefined') {
    g.TextEncoder = function () {};
    g.TextEncoder.prototype.encode = function (input) {
      var str = String(input);
      var bytes = [];
      for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c < 0x80) {
          bytes.push(c);
        } else if (c < 0x800) {
          bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
          var c2 = str.charCodeAt(++i);
          var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
          bytes.push(
            0xf0 | (cp >> 18),
            0x80 | ((cp >> 12) & 63),
            0x80 | ((cp >> 6) & 63),
            0x80 | (cp & 63)
          );
        } else {
          bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
      }
      return new Uint8Array(bytes);
    };
  }

  if (typeof g.TextDecoder === 'undefined') {
    g.TextDecoder = function () {};
    g.TextDecoder.prototype.decode = function (input) {
      if (input == null) return '';
      var bytes;
      if (input instanceof ArrayBuffer) {
        bytes = new Uint8Array(input);
      } else if (input && input.buffer && typeof input.byteOffset === 'number') {
        bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      } else if (typeof Uint8Array.from === 'function') {
        bytes = Uint8Array.from(input);
      } else {
        bytes = new Uint8Array(input.length || 0);
        for (var k = 0; k < bytes.length; k++) bytes[k] = input[k] || 0;
      }
      var out = '';
      var i = 0;
      while (i < bytes.length) {
        var b = bytes[i++];
        if (b < 0x80) {
          out += String.fromCharCode(b);
        } else if (b >= 0xc0 && b < 0xe0 && i < bytes.length) {
          out += String.fromCharCode(((b & 31) << 6) | (bytes[i++] & 63));
        } else if (b >= 0xe0 && b < 0xf0 && i + 1 < bytes.length) {
          out += String.fromCharCode(((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
        } else if (b >= 0xf0 && i + 2 < bytes.length) {
          var cp = ((b & 7) << 18) | ((bytes[i++] & 63) << 12)
            | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
          cp -= 0x10000;
          out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
        }
      }
      return out;
    };
  }
  if (typeof g.queueMicrotask !== 'function') {
    g.queueMicrotask = function (fn) {
      Promise.resolve().then(fn);
    };
  }

  if (!g.process) {
    g.process = { versions: { app: '1.9.1' }, env: {}, browser: true };
  }
  g.i18n = g.i18n || {
    t: function (key, params) {
      if (!params) return key;
      return Object.keys(params).reduce(function (text, name) {
        return text.split('{' + name + '}').join(String(params[name]));
      }, key);
    }
  };
  g.lx = g.lx || {
    qualityList: {
      kw: ['128k', '320k', 'flac', 'flac24bit'],
      kg: ['128k', '320k', 'flac', 'flac24bit'],
      tx: ['128k', '320k', 'flac', 'flac24bit'],
      wy: ['128k', '320k', 'flac', 'flac24bit'],
      mg: ['128k', '320k', 'flac', 'flac24bit'],
      local: []
    },
    apis: {},
    gettingUrlId: '',
    playerStatus: {}
  };

  g.FlmBridge = {
    postMessage: function (message) {
      post('bridge', String(message));
    }
  };
})();
''';

  /// Browser-only APIs a userApi script is not supposed to use (the contract is
  /// `lx.request`). Detecting them up front is cheaper and safer than failing
  /// on the first song: the slot falls back to the WebView, which has all of
  /// them, instead of silently losing background playback for that script.
  static final RegExp _browserOnlyApi = RegExp(
    r'\bfetch\s*\(|XMLHttpRequest|\bdocument\s*\.|localStorage'
    r'|\bnew\s+URL\s*\(|URLSearchParams',
  );

  @override
  Future<SourceCapabilities> activate(CustomSourceInfo info, String script) async {
    if (_browserOnlyApi.hasMatch(script)) {
      throw const JsEngineUnavailable('脚本依赖 WebView 专属 API（fetch/document/URL）');
    }
    _disposeRuntime();
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

    try {
      await _startRuntime();
      final runtime = _runtime;
      if (runtime == null) throw const JsEngineUnavailable('JS 运行时创建失败');
      _eval(runtime, 'FlmSource.prepare(${jsonEncode(<String, dynamic>{
            'key': _key,
            'id': info.id,
            'name': info.name,
            'description': info.description,
            'version': info.version,
            'author': info.author,
            'homepage': info.homepage,
            'script': script,
          })});');
      _eval(runtime, script);
    } on JsEngineUnavailable {
      rethrow;
    } catch (error) {
      throw JsEngineUnavailable('JS 引擎执行脚本失败: $error');
    }

    return initCompleter.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw TimeoutException('自定义源初始化超时'),
    );
  }

  Future<void> _startRuntime() async {
    if (_disposed) throw const JsEngineUnavailable('JS 引擎已释放');
    final scripts = await _loadSandboxScripts();
    JavascriptRuntime runtime;
    try {
      runtime = getJavascriptRuntime();
    } catch (error) {
      throw JsEngineUnavailable('JS 运行时不可用: $error');
    }

    try {
      runtime.onMessage('bridge', _onBridgeMessage);
      runtime.onMessage('timer', _onTimerMessage);

      final channel = runtime.evaluate('typeof sendMessage');
      final channelType =
          channel.stringResult.trim().replaceAll('"', '').replaceAll("'", '');
      if (channel.isError || channelType != 'function') {
        throw const JsEngineUnavailable('JS 运行时缺少 sendMessage 通道');
      }

      _runtime = runtime;
      _eval(runtime, prelude);
      for (final script in scripts) {
        _eval(runtime, script);
      }
      // The whole resolve path is promise-driven (lx.request -> native HTTP ->
      // response -> .then). Verify that this runtime drains the microtask queue
      // *synchronously*; if it does not, the request chain would only advance on
      // some later event and every link fetch would time out. Falling back to
      // the WebView is much better than shipping a silent regression.
      _eval(
        runtime,
        'window.__flmPromiseProbe = 0;'
        'Promise.resolve().then(function () { window.__flmPromiseProbe = 1; });',
      );
      var promiseJobsRun = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        final promiseProbe = _eval(runtime, 'String(window.__flmPromiseProbe)');
        if (promiseProbe.trim() == '1') {
          promiseJobsRun = true;
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (!promiseJobsRun) {
        throw const JsEngineUnavailable('JS 运行时不执行 Promise 回调');
      }
    } catch (error) {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
      _runtime = null;
      try {
        runtime.dispose();
      } catch (_) {}
      if (error is JsEngineUnavailable) rethrow;
      throw JsEngineUnavailable('JS 沙箱初始化失败: $error');
    }
  }

  static Future<List<String>> _loadSandboxScripts() async {
    final cached = _sandboxScripts;
    if (cached != null) return cached;
    final html = await rootBundle.loadString('assets/js/user_source.html');
    final matches = RegExp(r'<script[^>]*>([\s\S]*?)</script>').allMatches(html);
    final scripts = <String>[
      for (final match in matches)
        if ((match.group(1) ?? '').trim().isNotEmpty) match.group(1)!,
    ];
    if (scripts.length < 3) {
      throw const JsEngineUnavailable('自定义源沙箱脚本不完整');
    }
    return _sandboxScripts = scripts;
  }

  /// Evaluate [code] and pump the promise/microtask queue once. Throws
  /// [JsEngineUnavailable] when the engine itself fails, which is the signal
  /// for [SourceState] to fall back to the WebView engine.
  String _eval(JavascriptRuntime runtime, String code) {
    final result = runtime.evaluate(code);
    try {
      runtime.executePendingJob();
    } catch (_) {}
    if (result.isError) {
      throw JsEngineUnavailable(_short(result.stringResult));
    }
    return result.stringResult;
  }

  /// Delivery of an HTTP response into the sandbox must never take the engine
  /// down: a script-level throw here only rejects that one request.
  void _evalQuiet(JavascriptRuntime runtime, String code) {
    try {
      _eval(runtime, code);
    } catch (error) {
      debugPrint('[flm][js-source] $error');
    }
  }

  static String _short(String value) {
    final text = value.trim();
    if (text.length <= 400) return text;
    return '${text.substring(0, 400)}…';
  }

  void _onBridgeMessage(dynamic args) {
    final raw = args is String ? args : '$args';
    if (raw.trim().isEmpty) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final data = Map<String, dynamic>.from(decoded);
    if (data['type'] != 'sourceNative') return;
    unawaited(_dispatchSourceNative(data));
  }

  Future<void> _dispatchSourceNative(Map<String, dynamic> data) async {
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
        final rawData = data['data'];
        final requestKey = rawData is String
            ? rawData
            : '${payload['requestKey'] ?? ''}';
        final id = _httpRequestIds.remove(requestKey) ?? -1;
        _http.cancel(id);
        break;
      case 'response':
        _handleSourceResponse(payload);
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
    final runtime = _runtime;
    if (runtime == null) return;
    final requestKey = '${payload['requestKey'] ?? ''}';
    final id = _http.nextRequestId();
    _httpRequestIds[requestKey] = id;
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

    if (_runtime != runtime) return;
    _evalQuiet(
      runtime,
      '__lx_native__(${jsonEncode(key)}, \'response\', ${jsonEncode(jsonEncode(<String, dynamic>{
            'requestKey': requestKey,
            'error': failure,
            'response': failure == null ? result : null,
          }))});',
    );
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

  void _onTimerMessage(dynamic args) {
    final raw = args is String ? args : '$args';
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final data = Map<String, dynamic>.from(decoded);
    final id = (data['id'] as num?)?.toInt();
    if (id == null) return;
    if (data['cancel'] == true) {
      _timers.remove(id)?.cancel();
      return;
    }
    final ms = (data['ms'] as num?)?.toInt() ?? 0;
    final repeat = data['repeat'] == true;
    _timers.remove(id)?.cancel();
    if (repeat) {
      _timers[id] = Timer.periodic(
        Duration(milliseconds: ms < 0 ? 0 : ms),
        (_) => _fireTimer(id),
      );
    } else {
      _timers[id] = Timer(
        Duration(milliseconds: ms < 0 ? 0 : ms),
        () {
          _timers.remove(id);
          _fireTimer(id);
        },
      );
    }
  }

  void _fireTimer(int id) {
    final runtime = _runtime;
    if (runtime == null) return;
    _evalQuiet(runtime, 'window.__flmFireTimer($id);');
  }

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

  Future<Map<String, dynamic>> _requestAction({
    required String source,
    required String action,
    required Map<String, dynamic> info,
  }) async {
    final runtime = _runtime;
    if (runtime == null) throw StateError('自定义源尚未初始化完成');
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
      _eval(
        runtime,
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
      onEvent?.call('音源超时 ${_current?.name ?? ''}', <String, Object?>{
        'action': '$source/$action',
        'quality': '${info['type'] ?? ''}',
        '引擎': 'JS',
      });
      throw TimeoutException('自定义源响应超时');
    }
  }

  @override
  void clear() {
    _current = null;
    _capabilities = SourceCapabilities.empty();
  }

  void _disposeRuntime() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    final runtime = _runtime;
    _runtime = null;
    if (runtime != null) {
      try {
        runtime.dispose();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final waiter in _requestWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('自定义源已释放'));
      }
    }
    _requestWaiters.clear();
    final completer = _initCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('自定义源已释放'));
    }
    _disposeRuntime();
  }
}
