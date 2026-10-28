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

  /// The byte count the way it belongs in a log line. A ranged response used to
  /// report `1`, which read as a broken link even for a perfectly good 4 MB
  /// track; the real total now comes from `content-range`.
  String get lengthLabel {
    if (length < 0) return '未知';
    if (length < 1024) return '$length B';
    if (length < 1024 * 1024) return '${(length / 1024).toStringAsFixed(0)} KB';
    return '${(length / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Broken aggregate hosts answer 200 with a JSON error body, and AVPlayer then
  /// reports that only as the opaque code -11850. Anything that is clearly not a
  /// media type counts as a dead link; unknown types stay playable, because many
  /// hosts label a real mp3 stream as octet-stream or omit the header.
  bool get notAudio {
    final type = contentType.toLowerCase();
    if (type.isEmpty) return false;
    if (type.startsWith('audio/') || type.startsWith('video/')) return false;
    if (type.contains('mpegurl')) return false;
    return type != 'application/octet-stream';
  }
}

/// `bytes 0-0/3456789` — the total size of the whole file. Some hosts answer a
/// ranged request with `*` instead, which means they know the length of nothing.
final RegExp _rangeTotal = RegExp(r'/\s*(\d+)\s*$');

/// The length worth logging. A successful Range response reports only the slice
/// it sent, so `content-length` is 1; the total has to come from `content-range`.
/// Hosts that ignore the Range header return the whole body and their
/// `content-length` is already the answer.
int _totalBytes({required String? contentRange, required int contentLength}) {
  if (contentRange == null) return contentLength;
  final total = int.tryParse(_rangeTotal.firstMatch(contentRange)?.group(1) ?? '');
  // A 206 with an unparseable total tells us less than "unknown", not that the
  // track is one byte long.
  return total ?? -1;
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
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final length = _totalBytes(
      contentRange: contentRange,
      contentLength: response.contentLength,
    );
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
