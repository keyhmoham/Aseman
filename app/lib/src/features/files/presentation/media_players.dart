import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../../elpian/core/media_file.dart';

String _clock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Play/pause, a seek bar and the time, shared by both players.
class _Transport extends StatelessWidget {
  const _Transport({
    required this.playing,
    required this.position,
    required this.duration,
    required this.onToggle,
    required this.onSeek,
    this.trailing,
    this.color,
  });
  final bool playing;
  final Duration position;
  final Duration duration;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds.toDouble();
    final at = position.inMilliseconds.clamp(0, duration.inMilliseconds);
    final style = TextStyle(
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color,
    );
    return Row(
      children: [
        IconButton(
          tooltip: playing ? 'Pause' : 'Play',
          onPressed: onToggle,
          color: color,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        Text(_clock(position), style: style),
        Expanded(
          child: Slider(
            value: total <= 0 ? 0 : at.toDouble(),
            max: total <= 0 ? 1 : total,
            onChanged: total <= 0
                ? null
                : (v) => onSeek(Duration(milliseconds: v.round())),
          ),
        ),
        Text(_clock(duration), style: style),
        ?trailing,
        const SizedBox(width: 6),
      ],
    );
  }
}

/// A video file, played from its bytes with its own controls.
class FileVideoPlayer extends StatefulWidget {
  const FileVideoPlayer({super.key, required this.bytes, required this.mime});
  final Uint8List bytes;
  final String mime;
  @override
  State<FileVideoPlayer> createState() => _FileVideoPlayerState();
}

class _FileVideoPlayerState extends State<FileVideoPlayer> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final c = await videoControllerForBytes(widget.bytes, widget.mime);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'This video cannot be played here.');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_error != null) return _Unplayable(Icons.movie_outlined, _error!);
    if (c == null) return const Center(child: CircularProgressIndicator());
    final v = c.value;
    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => v.isPlaying ? c.pause() : c.play(),
              child: Center(
                child: AspectRatio(
                  aspectRatio: v.aspectRatio <= 0 ? 16 / 9 : v.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            ),
          ),
          _Transport(
            playing: v.isPlaying,
            position: v.position,
            duration: v.duration,
            color: Colors.white,
            onToggle: () => v.isPlaying ? c.pause() : c.play(),
            onSeek: c.seekTo,
            trailing: IconButton(
              tooltip: v.volume == 0 ? 'Unmute' : 'Mute',
              color: Colors.white,
              onPressed: () => c.setVolume(v.volume == 0 ? 1 : 0),
              icon: Icon(
                v.volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An audio file, played from its bytes: a cover, its name and controls.
class FileAudioPlayer extends StatefulWidget {
  const FileAudioPlayer({
    super.key,
    required this.bytes,
    required this.mime,
    required this.name,
    required this.color,
  });
  final Uint8List bytes;
  final String mime;
  final String name;
  final Color color;
  @override
  State<FileAudioPlayer> createState() => _FileAudioPlayerState();
}

class _FileAudioPlayerState extends State<FileAudioPlayer> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final uri = await mediaUriForBytes(widget.bytes, widget.mime);
      await _player.setAudioSource(AudioSource.uri(uri));
      _subs
        ..add(_player.positionStream.listen((_) => _changed()))
        ..add(_player.playerStateStream.listen((_) => _changed()));
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = 'This audio cannot be played here.');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _Unplayable(Icons.music_off_rounded, _error!);
    final scheme = Theme.of(context).colorScheme;
    final playing = _player.playing;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 148,
                height: 148,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(36),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [widget.color, widget.color.withValues(alpha: .45)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: .35),
                      blurRadius: 32,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Icon(
                  playing ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                  size: 64,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                widget.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              if (!_ready)
                const LinearProgressIndicator()
              else
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: _Transport(
                    playing: playing,
                    position: _player.position,
                    duration: _player.duration ?? Duration.zero,
                    onToggle: () async {
                      if (playing) return _player.pause();
                      if (_player.processingState ==
                          ProcessingState.completed) {
                        await _player.seek(Duration.zero);
                      }
                      unawaited(_player.play());
                    },
                    onSeek: _player.seek,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Unplayable extends StatelessWidget {
  const _Unplayable(this.icon, this.message);
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 10),
        Text(message),
      ],
    ),
  );
}
