import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/uploaded_file.dart';
import 'audio_bubble.dart';
import 'download_helper.dart';

/// Fullscreen preview of a shared file: images/gifs, video (with inline
/// playback), audio/voice (with playback) and documents (with download).
class MediaPreviewScreen extends StatefulWidget {
  const MediaPreviewScreen({
    super.key,
    required this.file,
    required this.headers,
    this.url,
    this.bytes,
    this.onDownload,
  });

  final UploadedFile file;
  final Map<String, String> headers;

  /// Absolute streamable URL for the file (see service.fileContentUrl).
  final String? url;
  final Uint8List? bytes;
  final Future<Uint8List> Function(UploadedFile file)? onDownload;

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  VideoPlayerController? _video;
  bool _videoFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.file.isVideo) _initVideo();
  }

  String get _url => widget.url ?? widget.file.contentUrl;

  Future<void> _initVideo() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(_url),
        httpHeaders: widget.headers,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _video = c);
    } catch (_) {
      if (mounted) setState(() => _videoFailed = true);
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = widget.file;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (file.isImage || file.isVideo || file.isPlayableAudio)
            IconButton(
              tooltip: 'Download',
              onPressed: () => _download(context),
              icon: const Icon(Icons.download_rounded),
            ),
        ],
      ),
      body: Center(
        child: _body(file, scheme),
      ),
    );
  }

  Widget _body(UploadedFile file, ColorScheme scheme) {
    if (file.isImage) {
      return GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(
          maxScale: 6,
          child: file.bytes != null
              ? Image.memory(file.bytes!)
              : Image.network(_url,
                  headers: widget.headers,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                      color: Colors.white54, size: 64)),
        ),
      );
    }
    if (file.isVideo) {
      final v = _video;
      if (_videoFailed || v == null) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_outlined,
                color: Colors.white54, size: 64),
            const SizedBox(height: 12),
            Text('${file.name} · ${file.humanSize}',
                style: const TextStyle(color: Colors.white70)),
          ],
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio:
                v.value.aspectRatio <= 0 ? 16 / 9 : v.value.aspectRatio,
            child: VideoPlayer(v),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  v.value.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 52,
                ),
                onPressed: () {
                  setState(() {
                    if (v.value.isPlaying) {
                      v.pause();
                    } else {
                      v.play();
                    }
                  });
                },
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.replay_rounded,
                    color: Colors.white, size: 34),
                onPressed: () => v.seekTo(Duration.zero),
              ),
            ],
          ),
        ],
      );
    }
    if (file.isPlayableAudio) {
      return Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(file.isVoice ? Icons.mic_rounded : Icons.music_note_rounded,
              color: AppColors.primary, size: 40),
          const SizedBox(height: 8),
          Text(file.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          AudioBubble(
            url: _url,
            headers: widget.headers,
            mime: file.mime,
            durationLabel: file.humanSize,
          ),
        ]),
      );
    }
    // Documents and other binary files: show a card + download.
    return Container(
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.insert_drive_file_outlined,
            color: AppColors.primary, size: 40),
        const SizedBox(height: 8),
        Text(file.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('${file.mime} · ${file.humanSize}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => _download(context),
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download'),
        ),
      ]),
    );
  }

  Future<void> _download(BuildContext context) async {
    final bytes = await (widget.onDownload ??
        (_) async {
          return widget.bytes ?? Uint8List(0);
        })(widget.file);
    if (!context.mounted) return;
    final saved = await saveBytes(widget.file.name, bytes);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved.isEmpty
            ? 'Downloaded ${widget.file.name} (browser)'
            : 'Downloaded ${widget.file.name} → $saved')));
  }
}
