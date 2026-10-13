import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// An inline playable video bubble using video_player. Falls back to a
/// poster-style card when the platform cannot play network video.
class VideoBubble extends StatefulWidget {
  const VideoBubble({
    super.key,
    required this.url,
    required this.headers,
    this.poster,
    this.mine = false,
    this.radius = 12,
  });

  final String url;
  final Map<String, String> headers;
  final Widget? poster;
  final bool mine;
  final double radius;

  @override
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _playing = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

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
      c.addListener(_onController);
      setState(() {
        _controller = c;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onController() {
    if (!mounted) return;
    setState(() {
      _playing = _controller!.value.isPlaying;
    });
  }

  Future<void> _toggle() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
      if (mounted) setState(() => _showControls = false);
    }
  }

  String get _position {
    final c = _controller;
    if (c == null) return '';
    final pos = c.value.position;
    final total = c.value.duration;
    if (pos.inSeconds <= 0 && total.inSeconds <= 0) return '0:00';
    final totalSec = total.inSeconds > 0 ? total.inSeconds : pos.inSeconds;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _controller?.removeListener(_onController);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = Size(240, 150);

    Widget content;
    if (_failed || _controller == null) {
      content = Container(
        width: size.width,
        height: size.height,
        color: scheme.surfaceContainerHighest,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.movie_creation_outlined,
              color: Colors.white70, size: 34),
          const SizedBox(height: 6),
          Text('Video', style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      );
    } else {
      content = GestureDetector(
        onTap: _toggle,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size.width,
              height: size.height,
              child: VideoPlayer(_controller!),
            ),
            if (!_playing || _showControls) ...[
              Container(
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(10),
                child: Icon(
                  _playing ? Icons.pause : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              Positioned(
                right: 8,
                bottom: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(_position,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: content,
    );
  }
}
