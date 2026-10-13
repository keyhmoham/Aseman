import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// An inline playable audio/voice bubble using just_audio. Falls back to a
/// passive card when the current platform cannot play network audio.
class AudioBubble extends StatefulWidget {
  const AudioBubble({
    super.key,
    required this.url,
    required this.headers,
    required this.mime,
    required this.durationLabel,
    this.mine = false,
  });

  final String url;
  final Map<String, String> headers;
  final String mime;
  final String durationLabel;
  final bool mine;

  @override
  State<AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<AudioBubble> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _loading = false;
  bool _failed = false;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final player = AudioPlayer();
      await player.setAudioSource(
        AudioSource.uri(
          Uri.parse(widget.url),
          headers: widget.headers,
        ),
      );
      if (!mounted) {
        await player.dispose();
        return;
      }
      _player = player;
      _posSub = player.positionStream.listen((_) {
        if (mounted) setState(() {});
      });
      _stateSub = player.playerStateStream.listen((st) {
        if (!mounted) return;
        setState(() {
          _playing = st.playing;
          _loading = st.processingState == ProcessingState.loading;
        });
      });
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _toggle() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await p.pause();
    } else {
      await p.play();
    }
  }

  String get _position {
    final p = _player;
    final pos = p?.position ?? Duration.zero;
    final total = p?.duration ?? Duration.zero;
    if (pos.inSeconds <= 0 && total.inSeconds <= 0) return widget.durationLabel;
    final totalSec = total.inSeconds > 0 ? total.inSeconds : pos.inSeconds;
    final pct =
        total.inSeconds > 0 ? pos.inMilliseconds / total.inMilliseconds : 0.0;
    _pct = pct.clamp(0.0, 1.0);
    return '${_fmt(pos.inSeconds)} / ${_fmt(totalSec)}';
  }

  double _pct = 0.0;

  static String _fmt(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_failed || _player == null) {
      // Passive card: audio cannot be played in-app on this platform.
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.mic_none_rounded,
            color: widget.mine ? scheme.onPrimary : scheme.primary, size: 18),
        const SizedBox(width: 8),
        Text('Voice note', style: TextStyle(color: scheme.onSurfaceVariant)),
      ]);
    }
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              onPressed: _loading ? null : _toggle,
              visualDensity: VisualDensity.compact,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(
                      _playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill_rounded,
                      color: widget.mine ? scheme.onPrimary : scheme.primary,
                      size: 34),
            ),
            const SizedBox(width: 6),
            Text(_position,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
          SizedBox(
            width: 150,
            child: LinearProgressIndicator(
              value: _pct,
              minHeight: 3,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ]);
  }
}
