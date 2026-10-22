import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../data/models/uploaded_file.dart';
import '../../../../data/services/aseman_service.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../computer/computer_view.dart' show computerSheetBreakpoint;
import '../../../desk/presentation/desk_controller.dart';
import '../../../files/domain/file_types.dart';
import '../../../files/presentation/file_viewer.dart';
import '../../../files/presentation/media_players.dart';
import 'audio_bubble.dart';
import 'download_helper.dart';

/// The stored file a content URL streams (`…/v1/files/<id>/content`), or ''.
String sharedFileIdOf(String url) =>
    RegExp(r'/v1/files/([0-9a-fA-F]{32})/content').firstMatch(url)?.group(1) ??
    '';

/// Opens a shared file (a video, a photo, a document) to play or read: as a
/// card window on the desk when a desk is on screen beside it (wide
/// screens), as the workspace's own files open; else in a bottom sheet.
Future<void> openSharedFile(
  BuildContext context, {
  required UploadedFile file,
  required String url,
  required Map<String, String> headers,
  Future<Uint8List> Function(UploadedFile file)? download,
}) async {
  final desk = DeskScope.maybeOf(context);
  final id = file.id.isNotEmpty ? file.id : sharedFileIdOf(url);
  if (desk != null &&
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id) &&
      MediaQuery.sizeOf(context).width >= computerSheetBreakpoint) {
    await desk.openSharedFile(id,
        title: file.name,
        // A video is wide; a page of a document is tall, as workspace
        // files open.
        size: file.isVideo ? null : const Size(680, 620));
    return;
  }
  await showAppSheet<void>(
    context,
    Builder(
      builder: (sheet) => SharedFileViewer(
        file: file,
        url: url,
        headers: headers,
        download: download,
        onClose: () => Navigator.of(sheet).pop(),
      ),
    ),
    heightFactor: .94,
  );
}

/// A file shared in a chat or a post, shown as what it is: a video or audio
/// player, an image, or a card to download it.
class SharedFileViewer extends StatelessWidget {
  const SharedFileViewer({
    super.key,
    required this.file,
    required this.url,
    required this.headers,
    this.download,
    this.showHeader = true,
    this.onClose,
  });

  final UploadedFile file;
  final String url;
  final Map<String, String> headers;
  final Future<Uint8List> Function(UploadedFile file)? download;

  /// A card window has its own title bar; the header is left out there.
  final bool showHeader;
  final VoidCallback? onClose;

  Future<void> _save(BuildContext context) async {
    final get = download;
    if (get == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final saved = await saveBytes(file.name, await get(file));
      messenger?.showSnackBar(SnackBar(
          content: Text(saved.isEmpty
              ? 'Downloaded ${file.name}'
              : 'Downloaded ${file.name} → $saved')));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final get = download;
    // Documents, books, PDFs, sheets, slides, code: the workspace's own
    // viewer, reading the shared file's bytes.
    if (!file.isVideo && !file.isImage && !file.isPlayableAudio && get != null) {
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: WorkspaceFileViewer(
          key: ValueKey('shared-${file.id}-$url'),
          path: file.name.isEmpty ? 'file' : file.name,
          read: () => get(file),
          showHeader: showHeader,
          onClose: onClose,
          actions: [
            IconButton(
              tooltip: 'Download',
              visualDensity: VisualDensity.compact,
              onPressed: () => _save(context),
              icon: const Icon(Icons.download_rounded, size: 19),
            ),
          ],
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final type = FileType.of(file.name);
    final name = file.name.isEmpty
        ? file.isVideo
            ? 'Video'
            : 'File'
        : file.name;
    return Material(
      color: scheme.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: type.color.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                    file.isVideo
                        ? Icons.movie_rounded
                        : file.isPlayableAudio
                            ? Icons.graphic_eq_rounded
                            : type.icon,
                    size: 19,
                    color: type.color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
                    if (file.size > 0)
                      Text(file.humanSize,
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (download != null)
                IconButton(
                  tooltip: 'Download',
                  onPressed: () => _save(context),
                  icon: const Icon(Icons.download_rounded, size: 20),
                ),
              if (onClose != null)
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
            ]),
          ),
        Expanded(child: _body(context, scheme, name)),
      ]),
    );
  }

  Widget _body(BuildContext context, ColorScheme scheme, String name) {
    if (file.isVideo) {
      return NetworkVideoPlayer(
          key: ValueKey(url), url: url, headers: headers);
    }
    if (file.isImage) {
      return ColoredBox(
        color: Colors.black,
        child: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.network(url,
                headers: headers,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 56)),
          ),
        ),
      );
    }
    if (file.isPlayableAudio) {
      return Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(file.isVoice ? Icons.mic_rounded : Icons.music_note_rounded,
                color: scheme.primary, size: 40),
            const SizedBox(height: 10),
            Text(name,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            AudioBubble(
              url: url,
              headers: headers,
              mime: file.mime,
              durationLabel: file.humanSize,
              voice: file.isVoice,
              seed: file.id.isEmpty ? url : file.id,
              width: 220,
            ),
          ]),
        ),
      );
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(FileType.of(file.name).icon, color: scheme.primary, size: 44),
        const SizedBox(height: 10),
        Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text([file.mime, file.humanSize].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        if (download != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _save(context),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download'),
          ),
        ],
      ]),
    );
  }
}

/// A desk card window showing a shared file: it is looked up by its id and
/// shown with [SharedFileViewer].
class SharedFileWindow extends StatefulWidget {
  const SharedFileWindow(
      {super.key, required this.service, required this.fileId});
  final AsemanService service;
  final String fileId;

  @override
  State<SharedFileWindow> createState() => _SharedFileWindowState();
}

class _SharedFileWindowState extends State<SharedFileWindow> {
  late final Future<UploadedFile> _file =
      widget.service.fetchFile(widget.fileId);

  @override
  Widget build(BuildContext context) => FutureBuilder<UploadedFile>(
        future: _file,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
                child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('This file is no longer available.',
                  textAlign: TextAlign.center),
            ));
          }
          final file = snap.data;
          if (file == null) {
            return const Padding(
                padding: EdgeInsets.all(24),
                child: SkeletonParagraph(lines: 8));
          }
          return SharedFileViewer(
            file: file,
            url: widget.service.fileContentUrl(widget.fileId),
            headers: widget.service.authHeaders(),
            download: (f) => widget.service.downloadFile(widget.fileId),
            showHeader: false,
          );
        },
      );
}
