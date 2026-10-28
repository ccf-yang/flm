import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'debug_log.dart';

class HttpBridge {
  HttpBridge()
      : _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 25),
            sendTimeout: const Duration(seconds: 25),
            validateStatus: (_) => true,
            followRedirects: true,
            maxRedirects: 5,
            responseType: ResponseType.plain,
            headers: const <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
              'Accept': 'application/json, text/plain, */*',
            },
          ),
        );

  final Dio _dio;
  final _CookieJar _cookies = _CookieJar();
  final Map<int, CancelToken> _cancelTokens = <int, CancelToken>{};
  int _idSeq = 0;

  /// Handle for one in-flight request, unique across every sandbox sharing this
  /// bridge.
  ///
  /// Scripts mint their own `requestKey` inside their sandbox, and two sandboxes
  /// asked at the same moment produce the same key — hashing the key into a bridge
  /// id would let one worker cancel another worker's HTTP request, which a batch
  /// probe would then read as "this source is dead".
  int nextRequestId() => ++_idSeq;

  /// When non-null and its `enabled` flag is on, request *failures* are mirrored
  /// to the in-app debug page.
  ///
  /// The full url / headers / body / response dump is gone: it buried the playback
  /// trace that the debug page exists for, and a source script can issue dozens of
  /// requests per song. Anything that still needs to be seen here arrives as a
  /// resolve error on the source's own log line.
  DebugLog? debugLog;

  Future<Map<String, dynamic>> request(
    int id,
    String url,
    Map<String, dynamic> options,
  ) async {
    final startedAt = DateTime.now();
    final uri = Uri.parse(url);
    final method = '${options['method'] ?? 'get'}'.toUpperCase();
    final headers = <String, String>{};
    final rawHeaders = options['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (value == null) return;
        headers['$key'] = '$value';
      });
    }

    final cookie = _cookies.headerFor(uri);
    if (cookie != null && !headers.keys.any((key) => key.toLowerCase() == 'cookie')) {
      headers['Cookie'] = cookie;
    }

    dynamic data;
    final form = options['form'];
    final formData = options['formData'];
    final body = options['body'];

    if (form is Map) {
      headers.putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded');
      data = Uri(
        queryParameters: form.map((key, value) => MapEntry('$key', '$value')),
      ).query;
    } else if (formData is Map) {
      data = FormData.fromMap(Map<String, dynamic>.from(formData));
    } else if (body != null) {
      final contentType = headers.entries
          .firstWhere(
            (entry) => entry.key.toLowerCase() == 'content-type',
            orElse: () => const MapEntry('content-type', ''),
          )
          .value
          .toLowerCase();
      if (body is String) {
        data = body;
      } else if (contentType.contains('x-www-form-urlencoded') && body is Map) {
        headers.putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded');
        data = Uri(
          queryParameters: body.map((key, value) => MapEntry('$key', '$value')),
        ).query;
      } else {
        headers.putIfAbsent('Content-Type', () => 'application/json');
        data = jsonEncode(body);
      }
    }

    final binary = options['binary'] == true;
    final timeoutMs = options['timeout'];
    final receiveTimeout = timeoutMs is num && timeoutMs > 0
        ? Duration(milliseconds: timeoutMs.toInt())
        : null;
    final cancelToken = CancelToken();
    _cancelTokens[id] = cancelToken;

    try {
      final response = await _dio.request<dynamic>(
        url,
        data: data,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: headers,
          responseType: binary ? ResponseType.bytes : ResponseType.plain,
          validateStatus: (_) => true,
          followRedirects: true,
          receiveTimeout: receiveTimeout,
        ),
      );

      final responseHeaders = <String, String>{};
      response.headers.map.forEach((key, values) {
        responseHeaders[key.toLowerCase()] = values.join(', ');
      });
      final setCookies = response.headers.map['set-cookie'];
      if (setCookies != null) _cookies.save(uri, setCookies);

      String textBody;
      final responseData = response.data;
      if (binary) {
        final bytes = responseData is Uint8List
            ? responseData
            : responseData is List<int>
                ? Uint8List.fromList(responseData)
                : Uint8List(0);
        textBody = base64Encode(bytes);
      } else if (responseData == null) {
        textBody = '';
      } else {
        textBody = responseData is String ? responseData : jsonEncode(responseData);
      }

      final status = response.statusCode ?? 0;
      if (status >= 400) {
        debugLog?.record('HTTP $status $url', <String, Object?>{
          '耗时': '${DateTime.now().difference(startedAt).inMilliseconds}ms',
          '响应头': responseHeaders,
        });
      }

      return <String, dynamic>{
        'statusCode': response.statusCode ?? 0,
        'statusMessage': response.statusMessage ?? '',
        'headers': responseHeaders,
        'body': textBody,
        'url': url,
        'ok': (response.statusCode ?? 0) >= 200 && (response.statusCode ?? 0) < 300,
      };
    } catch (error) {
      debugLog?.record('HTTP 失败 $url', <String, Object?>{
        '耗时': '${DateTime.now().difference(startedAt).inMilliseconds}ms',
        '错误类型': error.runtimeType.toString(),
        '错误': '$error',
      });
      rethrow;
    } finally {
      _cancelTokens.remove(id);
    }
  }

  void cancel(int id) {
    final token = _cancelTokens.remove(id);
    if (token != null && !token.isCancelled) token.cancel('cancelled');
  }
}

class _CookieJar {
  final Map<String, Map<String, String>> _store = <String, Map<String, String>>{};

  void save(Uri uri, List<String> setCookies) {
    final host = uri.host;
    final jar = _store.putIfAbsent(host, () => <String, String>{});
    for (final raw in setCookies) {
      final first = raw.split(';').first.trim();
      final index = first.indexOf('=');
      if (index <= 0) continue;
      final name = first.substring(0, index).trim();
      final value = first.substring(index + 1).trim();
      if (name.isEmpty) continue;
      if (value.isEmpty) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  String? headerFor(Uri uri) {
    final host = uri.host;
    final jar = _store[host];
    if (jar == null || jar.isEmpty) return null;
    return jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
  }
}
