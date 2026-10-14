import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'resources.dart';

/// Where an image, video or audio `src` is loaded from: the network (with the
/// headers it needs), bytes already at hand, or the asset bundle.
class ElpianMedia {
  const ElpianMedia.network(this.url, {this.headers = const {}, this.mime = ''})
      : bytes = null,
        asset = false;
  const ElpianMedia.memory(Uint8List this.bytes, {this.mime = ''})
      : url = '',
        headers = const {},
        asset = false;
  const ElpianMedia.asset(this.url)
      : bytes = null,
        headers = const {},
        mime = '',
        asset = true;

  final String url;
  final Map<String, String> headers;
  final Uint8List? bytes;

  /// The media type when known (`image/svg+xml`, `video/mp4`…).
  final String mime;
  final bool asset;

  bool get isNetwork => !asset && bytes == null;

  /// SVG is drawn by a vector renderer, not the image codecs.
  bool get isSvg {
    if (mime.contains('svg')) return true;
    final b = bytes;
    if (b != null) return looksLikeSvg(b);
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.svg');
  }

  /// A short name for players to show (never a data URI).
  String get label {
    if (!isNetwork) return '';
    final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    return segments.isEmpty ? '' : Uri.decodeComponent(segments.last);
  }

  static bool looksLikeSvg(Uint8List b) {
    final head = utf8
        .decode(b.length > 512 ? b.sublist(0, 512) : b, allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return head.startsWith('<svg') ||
        (head.startsWith('<?xml') && head.contains('<svg')) ||
        head.startsWith('<!doctype svg');
  }

  /// The media type of [b] from its leading bytes ('' when unknown).
  static String sniff(Uint8List b) {
    bool at(List<int> sig, [int offset = 0]) {
      if (b.length < offset + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[offset + i] != sig[i]) return false;
      }
      return true;
    }

    if (at([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (at([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (at([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (at([0x52, 0x49, 0x46, 0x46]) && at([0x57, 0x45, 0x42, 0x50], 8)) {
      return 'image/webp';
    }
    if (at([0x66, 0x74, 0x79, 0x70], 4)) return 'video/mp4';
    if (at([0x1A, 0x45, 0xDF, 0xA3])) return 'video/webm';
    if (at([0x49, 0x44, 0x33]) || at([0xFF, 0xFB])) return 'audio/mpeg';
    if (looksLikeSvg(b)) return 'image/svg+xml';
    return '';
  }

  /// The media type a file name suggests ('' when unknown).
  static String mimeOfName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return const {
          'png': 'image/png',
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'gif': 'image/gif',
          'webp': 'image/webp',
          'bmp': 'image/bmp',
          'svg': 'image/svg+xml',
          'mp4': 'video/mp4',
          'm4v': 'video/mp4',
          'mov': 'video/quicktime',
          'webm': 'video/webm',
          'mkv': 'video/x-matroska',
          'mp3': 'audio/mpeg',
          'wav': 'audio/wav',
          'ogg': 'audio/ogg',
          'm4a': 'audio/mp4',
          'aac': 'audio/aac',
          'flac': 'audio/flac',
        }[name.substring(dot + 1).toLowerCase()] ??
        '';
  }

  /// How a `src` loads with nothing but the engine to go on: `data:` URIs,
  /// inline SVG markup and bare base64 are bytes; `asset:` targets the asset
  /// bundle; everything else resolves as a URL ([ElpianResources]).
  static ElpianMedia? fallback(String src) {
    src = src.trim();
    if (src.isEmpty) return null;
    final lower = src.length > 16 ? src.substring(0, 16).toLowerCase() : src;
    if (lower.startsWith('<svg') || lower.startsWith('<?xml')) {
      return ElpianMedia.memory(Uint8List.fromList(utf8.encode(src)),
          mime: 'image/svg+xml');
    }
    if (lower.startsWith('data:')) {
      try {
        final data = UriData.parse(src);
        return ElpianMedia.memory(data.contentAsBytes(), mime: data.mimeType);
      } catch (_) {
        return null;
      }
    }
    if (src.length >= 64 && _base64.hasMatch(src)) {
      try {
        final bytes = base64.decode(src.replaceAll(RegExp(r'\s'), ''));
        return ElpianMedia.memory(bytes, mime: sniff(bytes));
      } catch (_) {}
    }
    if (src.startsWith('asset:')) return ElpianMedia.asset(src.substring(6));
    final resolved = ElpianResources.resolve(src);
    if (ElpianResources.isNetwork(resolved)) {
      return ElpianMedia.network(resolved);
    }
    return ElpianMedia.asset(resolved);
  }

  static final _base64 = RegExp(r'^[A-Za-z0-9+/=\s_-]+$');
}

/// Resolves a `src` for the host (its own files, storage, credentials); null
/// leaves it to [ElpianMedia.fallback].
typedef ElpianMediaResolver = FutureOr<ElpianMedia?> Function(String src);

/// The host's [ElpianMediaResolver] for the frontends under it.
class ElpianMediaScope extends InheritedWidget {
  const ElpianMediaScope(
      {super.key, required this.resolver, required super.child});

  final ElpianMediaResolver resolver;

  static ElpianMediaResolver? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ElpianMediaScope>()?.resolver;

  @override
  bool updateShouldNotify(ElpianMediaScope old) => old.resolver != resolver;
}

/// Resolves [src] with the host's resolver, then the engine's fallback.
Future<ElpianMedia?> resolveElpianMedia(
    ElpianMediaResolver? resolver, String src) async {
  if (resolver != null) {
    final media = await resolver(src);
    if (media != null) return media;
  }
  return ElpianMedia.fallback(src);
}

/// An image from any `src` the engine or its host can load: network (with
/// the host's credentials), bytes, `data:` URIs, inline SVG, or assets. While
/// it loads it holds its size; a source that fails shows what it was of.
class ElpianMediaImage extends StatefulWidget {
  const ElpianMediaImage({
    super.key,
    required this.src,
    this.fit = BoxFit.contain,
    this.width,
    this.height,
    this.alt,
  });

  final String src;
  final BoxFit fit;
  final double? width;
  final double? height;
  final String? alt;

  @override
  State<ElpianMediaImage> createState() => _ElpianMediaImageState();
}

class _ElpianMediaImageState extends State<ElpianMediaImage> {
  ElpianMediaResolver? _resolver;
  bool _started = false;
  ElpianMedia? _media;
  Object? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resolver = ElpianMediaScope.maybeOf(context);
    if (!_started || resolver != _resolver) {
      _resolver = resolver;
      _resolve();
    }
  }

  @override
  void didUpdateWidget(ElpianMediaImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) _resolve();
  }

  void _resolve() {
    _started = true;
    final generation = ++_generation;
    _error = null;
    if (_resolver == null) {
      // Nothing asynchronous to wait for: no flash of a placeholder.
      _media = ElpianMedia.fallback(widget.src);
      if (_media == null) _error = 'no image';
      return;
    }
    _media = null;
    resolveElpianMedia(_resolver, widget.src).then((media) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _media = media;
        if (media == null) _error = 'no image';
      });
    }, onError: (Object e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = e);
    });
  }

  int? _cache(double? v) {
    if (v == null || v <= 0 || !v.isFinite) return null;
    final ratio = WidgetsBinding
            .instance.platformDispatcher.implicitView?.devicePixelRatio ??
        1;
    return (v * ratio).round();
  }

  Widget _broken(Object? error) {
    final scheme = Theme.of(context).colorScheme;
    final alt = widget.alt ?? '';
    return SizedBox(
      width: widget.width,
      height: widget.height ?? (widget.width == null ? 120 : null),
      child: ColoredBox(
        color: scheme.surfaceContainerHighest.withValues(alpha: .6),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.broken_image_outlined,
                  color: scheme.onSurfaceVariant, size: 22),
              if (alt.isNotEmpty)
                Text(alt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _loading() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: widget.width,
      height: widget.height ?? (widget.width == null ? 120 : null),
      child: ColoredBox(
          color: scheme.surfaceContainerHighest.withValues(alpha: .35)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _broken(_error);
    final media = _media;
    if (media == null) return _loading();
    final w = widget.width, h = widget.height;
    Widget onError(BuildContext _, Object e, StackTrace? __) => _broken(e);
    if (media.isSvg) {
      final placeholder = _loading();
      if (media.bytes != null) {
        return SvgPicture.memory(media.bytes!,
            width: w,
            height: h,
            fit: widget.fit,
            semanticsLabel: widget.alt,
            placeholderBuilder: (_) => placeholder,
            errorBuilder: onError);
      }
      if (media.asset) {
        return SvgPicture.asset(media.url,
            width: w,
            height: h,
            fit: widget.fit,
            semanticsLabel: widget.alt,
            errorBuilder: onError);
      }
      return SvgPicture.network(media.url,
          headers: media.headers,
          width: w,
          height: h,
          fit: widget.fit,
          semanticsLabel: widget.alt,
          placeholderBuilder: (_) => placeholder,
          errorBuilder: onError);
    }
    if (media.bytes != null) {
      return Image.memory(media.bytes!,
          width: w,
          height: h,
          fit: widget.fit,
          semanticLabel: widget.alt,
          gaplessPlayback: true,
          cacheWidth: _cache(w),
          errorBuilder: onError);
    }
    if (media.asset) {
      return Image.asset(media.url,
          width: w,
          height: h,
          fit: widget.fit,
          semanticLabel: widget.alt,
          cacheWidth: _cache(w),
          errorBuilder: onError);
    }
    return Image.network(media.url,
        headers: media.headers.isEmpty ? null : media.headers,
        width: w,
        height: h,
        fit: widget.fit,
        semanticLabel: widget.alt,
        gaplessPlayback: true,
        cacheWidth: _cache(w),
        // On the web an image from a host without CORS headers cannot be
        // fetched as bytes; it is shown by an <img> element instead (which
        // cannot carry headers, so only for sources that need none).
        webHtmlElementStrategy: kIsWeb && media.headers.isEmpty
            ? WebHtmlElementStrategy.fallback
            : WebHtmlElementStrategy.never,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : _loading(),
        errorBuilder: onError);
  }
}
