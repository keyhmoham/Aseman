import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/uploaded_file.dart';
import 'audio_bubble.dart';
import 'download_helper.dart';
import 'media_preview_screen.dart';
import 'video_bubble.dart';

/// Renders a single attached file inside a chat bubble, adapting to its type:
/// images/gifs inline preview, videos/audio inline players (with graceful
/// fallbacks), and documents as a card with a download action.
class AttachmentBubble extends StatelessWidget {
  const AttachmentBubble({
    super.key,
    required this.file,
    required this.headers,
    required this.fetchBytes,
    this.resolveUrl,
    this.mine = false,
    this.maxWidth = 240,
  });

  final UploadedFile file;
  final Map<String, String> headers;
  final Future<Uint8List> Function(UploadedFile file) fetchBytes;

  /// Resolves the file's relative content url into an absolute, streamable URL
  /// (the service also appends the auth token on web). Defaults to the raw
  /// backend value.
  final String Function(UploadedFile file)? resolveUrl;
  final bool mine;
  final double maxWidth;

  String get _url => resolveUrl?.call(file) ?? file.contentUrl;

  /// Whether the running platform can play network video via video_player.
  static bool get _videoSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Whether the running platform can play network audio via just_audio.
  static bool get _audioSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (file.isImage) {
      return _image(context);
    }
    if (file.isVideo) {
      if (_videoSupported) {
        return VideoBubble(
          url: _url,
          headers: headers,
          mine: mine,
        );
      }
      return _fallbackMediaCard(
          context, Icons.videocam_rounded, 'Video · ${file.humanSize}');
    }
    if (file.isPlayableAudio) {
      if (_audioSupported) {
        return AudioBubble(
          url: _url,
          headers: headers,
          mime: file.mime,
          durationLabel: file.humanSize,
          mine: mine,
        );
      }
      return _fallbackMediaCard(
          context, Icons.graphic_eq_rounded, 'Audio · ${file.humanSize}');
    }
    // Documents and everything else.
    return _document(context, scheme);
  }

  Widget _image(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = Column(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: maxWidth,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: file.bytes != null
                ? Image.memory(file.bytes!, fit: BoxFit.cover)
                : Image.network(
                    _url,
                    headers: headers,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: scheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Icon(Icons.broken_image_outlined,
                          color: scheme.onSurfaceVariant),
                    ),
                    loadingBuilder: (_, child, progress) =>
                        progress == null ? child : const SizedBox(),
                  ),
          ),
        ),
      ),
      const SizedBox(height: 5),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(file.isGif ? Icons.gif_box_rounded : Icons.image_rounded,
            size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            file.isGif ? 'GIF · ${file.humanSize}' : file.name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ),
      ]),
    ]);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MediaPreviewScreen(
          file: file,
          headers: headers,
          bytes: file.bytes,
          url: _url,
        ),
      )),
      child: child,
    );
  }

  Widget _fallbackMediaCard(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openExternal(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: scheme.primary, size: 22),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            const Icon(Icons.open_in_new_rounded, size: 15),
          ]),
        ),
      ),
    );
  }

  Widget _document(BuildContext context, ColorScheme scheme) {
    final color = _docColor(file);
    final ext = file.extension.isEmpty ? 'FILE' : file.extension.toUpperCase();
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _downloadAndOpen(context),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 38,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: .4)),
              ),
              alignment: Alignment.center,
              child: Text(ext,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w800, fontSize: 10)),
            ),
            const SizedBox(width: 10),
            Flexible(
                child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth - 70),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12)),
                  const SizedBox(height: 2),
                  Text('${file.humanSize} · tap to download',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                ],
              ),
            )),
            const SizedBox(width: 8),
            Icon(Icons.download_rounded,
                color: scheme.onSurfaceVariant, size: 20),
          ]),
        ),
      ),
    );
  }

  Color _docColor(UploadedFile file) {
    if (file.mime.contains('pdf')) return AppColors.danger;
    if (file.mime.contains('sheet') ||
        file.mime.contains('excel') ||
        ['xls', 'xlsx', 'csv', 'tsv'].contains(file.extension)) {
      return AppColors.success;
    }
    if (file.mime.contains('presentation') ||
        file.mime.contains('powerpoint') ||
        ['ppt', 'pptx', 'key'].contains(file.extension)) {
      return AppColors.warning;
    }
    if (file.mime.contains('zip') ||
        file.mime.contains('compressed') ||
        ['zip', 'rar', '7z', 'tar', 'gz'].contains(file.extension)) {
      return AppColors.primary;
    }
    return AppColors.primary;
  }

  Future<void> _openExternal() async {
    final uri = Uri.parse(_url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _downloadAndOpen(BuildContext context) async {
    try {
      // On web, the browser handles the download via the Content-Disposition
      // header on the content URL; there is no writable filesystem.
      if (kIsWeb) {
        final uri = Uri.parse(_url);
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
      final bytes = await fetchBytes(file);
      if (!context.mounted) return;
      final saved = await saveBytes(file.name, bytes);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(saved.isEmpty
              ? 'Could not save ${file.name}'
              : 'Downloaded ${file.name} → $saved')));
      if (saved.isNotEmpty) {
        try {
          await launchUrl(Uri.file(saved),
              mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }
}
