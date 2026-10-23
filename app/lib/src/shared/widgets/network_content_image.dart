import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Whether [url] streams a stored file from this node (`/v1/files/{id}/content`).
bool isStoredFileContentUrl(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  return RegExp(r'/v1/files/[0-9a-fA-F]{32}/content').hasMatch(path);
}

/// Headers [Image.network] should send for a resolved media [url].
///
/// Public web images must not carry the session bearer: on Flutter web that
/// forces a CORS request CDNs reject, and blocks the `<img>` fallback. Stored
/// files on native need [authHeaders]; on web [fileContentUrl] already puts
/// `?token=` on the URL so headers stay empty.
Map<String, String> mediaRequestHeaders(
  String url,
  Map<String, String> authHeaders,
) {
  if (authHeaders.isEmpty || !isStoredFileContentUrl(url)) return const {};
  if (kIsWeb) return const {};
  return authHeaders;
}

/// How Flutter web should fetch [headers]: `<img>` when there are none (public
/// URLs and tokenised file URLs), XHR when the bearer must be sent.
WebHtmlElementStrategy mediaWebStrategy(Map<String, String> headers) =>
    kIsWeb && headers.isEmpty
        ? WebHtmlElementStrategy.fallback
        : WebHtmlElementStrategy.never;

/// A network image that loads public URLs and this node's stored files.
class NetworkContentImage extends StatelessWidget {
  const NetworkContentImage({
    super.key,
    required this.url,
    this.headers = const {},
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.errorBuilder,
    this.loadingBuilder,
  });

  final String url;
  final Map<String, String> headers;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;

  @override
  Widget build(BuildContext context) {
    final h = mediaRequestHeaders(url, headers);
    return Image.network(
      url,
      headers: h.isEmpty ? null : h,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      webHtmlElementStrategy: mediaWebStrategy(h),
      errorBuilder: errorBuilder,
      loadingBuilder: loadingBuilder,
    );
  }
}
