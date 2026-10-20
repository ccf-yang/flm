import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/debug_log.dart';

/// The music SDKs hand out cover links in two flavours that both used to render
/// as a blank gradient on iOS: plain `http://` (netease playlist covers, kuwo,
/// kugou) and a `Dart/x (dart:io)` user agent the CDNs answer with 403.
/// Every one of these hosts serves the same path on 443, so the fix is to
/// upgrade the scheme and introduce ourselves like the web player does.
const String coverUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';

String secureCoverUrl(String raw) =>
    raw.startsWith('http://') ? 'https://${raw.substring(7)}' : raw;

Map<String, String> coverHeaders(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  String refererFor() {
    if (host.endsWith('music.126.net') || host.endsWith('music.163.com')) {
      return 'https://music.163.com/';
    }
    if (host.endsWith('kuwo.cn')) return 'https://www.kuwo.cn/';
    if (host.endsWith('kugou.com') || host.endsWith('kgimg.com')) {
      return 'https://www.kugou.com/';
    }
    if (host.endsWith('gtimg.cn') || host.endsWith('y.qq.com')) {
      return 'https://y.qq.com/';
    }
    if (host.endsWith('migu.cn') || host.endsWith('miguvideo.com')) {
      return 'https://music.migu.cn/';
    }
    return '';
  }

  final referer = refererFor();
  return <String, String>{
    'User-Agent': coverUserAgent,
    if (referer.isNotEmpty) 'Referer': referer,
  };
}

/// Network cover image with the scheme upgrade, the CDN-friendly headers and a
/// debug-log trace of any failure, so "why is this picture missing" stays
/// answerable from the phone instead of guessing.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.gaplessPlayback = false,
    this.placeholder,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final bool gaplessPlayback;
  final WidgetBuilder? placeholder;

  static final Set<String> _reported = <String>{};

  @override
  Widget build(BuildContext context) {
    final link = secureCoverUrl(url);
    if (link.isEmpty) return _fallback(context);
    return Image.network(
      link,
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: gaplessPlayback,
      headers: coverHeaders(link),
      errorBuilder: (context, _, error) {
        _report(context, link, error);
        return _fallback(context);
      },
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _fallback(context),
    );
  }

  Widget _fallback(BuildContext context) =>
      placeholder?.call(context) ?? const SizedBox.shrink();

  /// Each broken host would otherwise add one log line per rebuild; recording
  /// after the frame keeps the ring buffer useful instead of flooded.
  void _report(BuildContext context, String link, Object? error) {
    if (!_reported.add(link)) return;
    if (_reported.length > 40) _reported.remove(_reported.first);
    final log = context.read<DebugLog>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      log.record('封面加载失败', <String, Object?>{
        '地址': link,
        '原因': '$error',
      });
    });
  }
}
