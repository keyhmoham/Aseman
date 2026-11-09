import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../../data/models/uploaded_file.dart';
import '../../../files/presentation/play_badge.dart';
import 'shared_file_viewer.dart';

/// A video as a card: its first frame (where the platform can show it) under
/// a play button, its length and name. Tapping it opens the player — a card
/// window on the desk beside a room's chat on wide screens, else a bottom
/// sheet (see [openSharedFile]).
class VideoBubble extends StatefulWidget {
  const VideoBubble({
    super.key,
    required this.url,
    required this.headers,
    this.file,
    this.download,
    this.poster,
    this.mine = false,
    this.radius = 12,
    this.width = 240,
  });

  final String url;
  final Map<String, String> headers;

  /// The stored file, when the video is one (its name, size and id).
  final UploadedFile? file;
  final Future<Uint8List> Function(UploadedFile file)? download;
  final Widget? poster;
  final bool mine;
  final double radius;
  final double width;

  @override
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Loads the video far enough to show its first frame and length.
  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
        httpHeaders: widget.headers,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      // The card keeps its plain poster.
    }
  }

  UploadedFile get _file =>
      widget.file ??
      UploadedFile(
          id: sharedFileIdOf(widget.url),
          name: 'Video',
          mime: 'video/mp4',
          size: 0);

  String get _length {
    final total = _controller?.value.duration ?? Duration.zero;
    if (total <= Duration.zero) return '';
    final m = total.inMinutes.toString();
    final s = (total.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final file = _file;
    final caption = [
      if (widget.file != null && file.name.isNotEmpty) file.name,
      if (file.size > 0) file.humanSize,
    ].join(' · ');
    final length = _length;
    return Semantics(
      button: true,
      label: 'Play video',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: SizedBox(
          width: widget.width,
          child: AspectRatio(
            aspectRatio: 16 / 10,
            child: Material(
              color: Colors.black,
              child: InkWell(
                onTap: () => openSharedFile(context,
                    file: file,
                    url: widget.url,
                    headers: widget.headers,
                    download: widget.download),
                child: Stack(fit: StackFit.expand, children: [
                  if (c != null)
                    FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: c.value.size.width <= 0 ? 16 : c.value.size.width,
                        height:
                            c.value.size.height <= 0 ? 10 : c.value.size.height,
                        child: VideoPlayer(c),
                      ),
                    )
                  else
                    widget.poster ??
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF2A2340), Color(0xFF0E0C16)],
                            ),
                          ),
                        ),
                  // A shade at the foot keeps the caption readable.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                  ),
                  const Center(child: PlayBadge(size: 54)),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Row(children: [
                      const Icon(Icons.videocam_rounded,
                          size: 14, color: Colors.white70),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ),
                      if (length.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(length,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10)),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
