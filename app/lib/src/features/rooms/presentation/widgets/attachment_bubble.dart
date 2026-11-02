import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/uploaded_file.dart';
import '../../../../shared/widgets/network_content_image.dart';
import 'audio_bubble.dart';
import 'download_helper.dart';
import 'media_preview_screen.dart';
import 'shared_file_viewer.dart';
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

    if (file.isFolder) {
      // A project folder attached to the prompt: it stays on that computer.
      return Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.folder_shared_rounded, color: scheme.primary),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (file.detail.isNotEmpty)
                    Text(file.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                ]),
          ),
        ]),
      );
    }
    if (file.isImage) {
      return _image(context);
    }
    if (file.isVideo) {
      if (_videoSupported) {
        return VideoBubble(
          url: _url,
          headers: headers,
          file: file,
          download: fetchBytes,
          mine: mine,
          width: maxWidth,
        );
      }
      return _fallbackMediaCard(
          context, Icons.videocam_rounded, 'Video · ${file.humanSize}');
    }
    if (file.isPlayableAudio) {
      if (_audioSupported) {
        final player = AudioBubble(
          url: _url,
          headers: headers,
          mime: file.mime,
          durationLabel: file.durationMs > 0
              ? _fmtMs(file.durationMs)
              : file.humanSize,
          mine: mine,
          voice: _voiceNote,
          seed: file.id.isEmpty ? _url : file.id,
          waveform: file.waveform.isEmpty ? null : file.waveform,
          width: (maxWidth - 60).clamp(120.0, 260.0),
        );
        // A voice note is just its player; a track also names itself.
        if (_voiceNote) return player;
        return _audioCard(context, player);
      }
      return _fallbackMediaCard(
          context, Icons.graphic_eq_rounded, 'Audio · ${file.humanSize}');
    }
    if (_isLink) return _link(context, scheme);
    // Documents and everything else.
    return _document(context, scheme);
  }

  /// A recording (voice_….webm, an ogg/opus note) rather than a track.
  bool get _voiceNote =>
      file.voice ||
      file.name.toLowerCase().contains('voice') ||
      const ['ogg', 'opus', 'amr', 'webm'].contains(file.extension);

  static String _fmtMs(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// A saved web page or shortcut (.html, .url, .webloc).
  bool get _isLink =>
      file.mime.contains('html') ||
      file.mime.contains('url') ||
      const ['url', 'webloc', 'htm', 'html'].contains(file.extension);

  /// An audio track: its name over the player, on a card.
  Widget _audioCard(BuildContext context, Widget player) {
    final scheme = Theme.of(context).colorScheme;
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
      decoration: BoxDecoration(
        color: mine
            ? scheme.onPrimaryContainer.withValues(alpha: .08)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.music_note_rounded, size: 14, color: fg),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth - 40),
              child: Text(file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
            ),
          ]),
          const SizedBox(height: 8),
          player,
        ],
      ),
    );
  }

  /// A link: a page's globe, its name and where it opens.
  Widget _link(BuildContext context, ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: SizedBox(
          width: maxWidth.isFinite ? maxWidth : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    scheme.primary.withValues(alpha: .35),
                    scheme.tertiary.withValues(alpha: .25),
                  ]),
                ),
                child: Icon(Icons.public_rounded,
                    size: 30, color: scheme.onPrimaryContainer),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                child: Row(children: [
                  Expanded(
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
                        Text('Link · ${file.humanSize}',
                            style: TextStyle(
                                fontSize: 10, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Icon(Icons.open_in_new_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
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
            child: Stack(fit: StackFit.expand, children: [
              file.bytes != null
                ? Image.memory(file.bytes!, fit: BoxFit.cover)
                : NetworkContentImage(
                    url: _url,
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
              if (file.isGif)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('GIF',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
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
      // A stored photo opens like the workspace's own: a card window on the
      // desk on wide screens, else a bottom sheet. One only in memory (not
      // sent yet) opens full screen.
      onTap: () => file.id.isEmpty && file.bytes != null
          ? Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => MediaPreviewScreen(
                file: file,
                headers: headers,
                bytes: file.bytes,
                url: _url,
              ),
            ))
          : openSharedFile(context,
              file: file, url: _url, headers: headers, download: fetchBytes),
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
        onTap: () => _open(context),
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
                  Text('${file.humanSize} · tap to open',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                ],
              ),
            )),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Download',
              visualDensity: VisualDensity.compact,
              onPressed: () => _downloadAndOpen(context),
              icon: Icon(Icons.download_rounded,
                  color: scheme.onSurfaceVariant, size: 20),
            ),
          ]),
        ),
      ),
    );
  }

  /// Opens a stored document or page the way the workspace's files open
  /// (a desk card window on wide screens, else a bottom sheet), shown by
  /// the same viewer: PDFs, books, documents, sheets, slides, code. One not
  /// stored yet is downloaded instead.
  void _open(BuildContext context) {
    if (file.id.isEmpty) {
      _downloadAndOpen(context);
      return;
    }
    openSharedFile(context,
        file: file, url: _url, headers: headers, download: fetchBytes);
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
