import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_shape.dart';
import '../../../data/models/uploaded_file.dart';
import '../../rooms/presentation/widgets/media_preview_screen.dart';

/// A post's images, GIFs and videos: one fills the width, more sit in a
/// two-column grid (at most four shown, the rest counted on the last tile).
/// Tapping one opens it full screen, where videos play.
class PostMediaGrid extends StatelessWidget {
  const PostMediaGrid({
    super.key,
    required this.media,
    required this.resolveUrl,
    required this.headers,
    required this.download,
  });

  final List<UploadedFile> media;

  /// The absolute streamable URL of a file (service.fileContentUrl).
  final String Function(UploadedFile file) resolveUrl;
  final Map<String, String> headers;

  /// A file's bytes, for the full-screen view's Download.
  final Future<Uint8List> Function(UploadedFile file) download;

  static const _shown = 4;

  @override
  Widget build(BuildContext context) {
    final files =
        media.where((f) => f.isImage || f.isVideo).toList(growable: false);
    if (files.isEmpty) return const SizedBox.shrink();
    final shown = files.take(_shown).toList();
    final more = files.length - shown.length;
    final radius = BorderRadius.circular(AppShape.inner);
    if (shown.length == 1) {
      return ClipRRect(
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: AspectRatio(
              aspectRatio: 16 / 10, child: _tile(context, files, 0, 0)),
        ),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: shown.length == 2 ? 1 : 16 / 10,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < shown.length; i++)
            _tile(context, files, i, i == shown.length - 1 ? more : 0),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, List<UploadedFile> files, int i, int more) {
    final file = files[i];
    final scheme = Theme.of(context).colorScheme;
    final url = resolveUrl(file);
    final Widget content = file.isImage
        ? Image.network(url,
            headers: headers,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant)))
        : ColoredBox(
            color: Colors.black87,
            child: Center(
                child: Icon(Icons.play_circle_fill_rounded,
                    size: 52, color: Colors.white.withValues(alpha: .9))));
    return Semantics(
      button: true,
      label: file.isVideo ? 'Play video' : 'Open image',
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => MediaPreviewScreen(
                file: file,
                headers: headers,
                url: resolveUrl(file),
                onDownload: download))),
        child: Stack(fit: StackFit.expand, children: [
          content,
          if (file.isGif)
            const Positioned(left: 8, bottom: 8, child: _Label('GIF')),
          if (more > 0)
            ColoredBox(
                color: Colors.black54,
                child: Center(
                    child: Text('+$more',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700)))),
        ]),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: BoxDecoration(
          color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700))));
}
