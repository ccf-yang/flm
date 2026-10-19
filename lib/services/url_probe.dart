import 'dart:io';

class AudioProbe {
  AudioProbe({
    required this.status,
    required this.contentType,
    required this.length,
    required this.elapsedMs,
    this.error,
  });

  final int status;
  final String contentType;
  final int length;
  final int elapsedMs;
  final String? error;

  bool get networkFailed => error != null;
  bool get rejected => status >= 400;
  bool get notAudio => contentType.startsWith('text/');
}

/// The player reports these source links only as opaque AVFoundation codes, so
/// the HTTP status and content type have to be captured while we still own the
/// request. One byte is fetched, just enough to read the response head.
Future<AudioProbe> probeAudioUrl(
  String url, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final started = DateTime.now();
  int elapsed() => DateTime.now().difference(started).inMilliseconds;
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';
  try {
    final uri = Uri.parse(url);
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(timeout);
    final length = response.contentLength;
    final subscription = response.listen((_) {});
    await subscription.cancel();
    return AudioProbe(
      status: response.statusCode,
      contentType: response.headers.contentType?.mimeType ?? '',
      length: length,
      elapsedMs: elapsed(),
    );
  } catch (error) {
    return AudioProbe(
      status: 0,
      contentType: '',
      length: -1,
      elapsedMs: elapsed(),
      error: '$error',
    );
  } finally {
    client.close(force: true);
  }
}
