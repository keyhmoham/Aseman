import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../../../shared/widgets/audio_waveform.dart';

/// An inline playable audio/voice bubble using just_audio: a round play
/// button, the clip's waveform filling up as it plays (tap or drag it to
/// seek) and its time. Falls back to a passive card when the current
/// platform cannot play network audio.
class AudioBubble extends StatefulWidget {
  const AudioBubble({
    super.key,
    required this.url,
    required this.headers,
    required this.mime,
    required this.durationLabel,
    this.mine = false,
    this.voice = true,
    this.seed,
    this.waveform,
    this.width = 190,
  });

  final String url;
  final Map<String, String> headers;
  final String mime;
  final String durationLabel;
  final bool mine;

  /// A voice note (a mic beside the time) rather than a music track.
  final bool voice;

  /// What the waveform is drawn from (defaults to [url]).
  final String? seed;

  /// Real loudness bars from the upload when present.
  final List<int>? waveform;

  /// The waveform's width.
  final double width;

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
          _playing =
              st.playing && st.processingState != ProcessingState.completed;
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
    if (_playing) {
      await p.pause();
      return;
    }
    if (p.processingState == ProcessingState.completed) {
      await p.seek(Duration.zero);
    }
    unawaited(p.play());
  }

  double get _progress {
    final p = _player;
    final total = p?.duration ?? Duration.zero;
    if (p == null || total.inMilliseconds <= 0) return 0;
    return (p.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  void _seek(double fraction) {
    final p = _player;
    final total = p?.duration;
    if (p == null || total == null || total.inMilliseconds <= 0) return;
    p.seek(Duration(milliseconds: (total.inMilliseconds * fraction).round()));
  }

  /// The time played while it plays, else the clip's length.
  String get _time {
    final p = _player;
    final total = p?.duration ?? Duration.zero;
    final pos = p?.position ?? Duration.zero;
    if (total.inSeconds <= 0 && pos.inSeconds <= 0) return widget.durationLabel;
    return _fmt(_playing || pos.inSeconds > 0 ? pos : total);
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
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
    final tint = widget.mine ? scheme.onPrimaryContainer : scheme.primary;
    final muted = widget.mine
        ? scheme.onPrimaryContainer.withValues(alpha: .7)
        : scheme.onSurfaceVariant;
    final ready = !_failed && _player != null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: ready ? tint : tint.withValues(alpha: .35),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: ready && !_loading ? _toggle : null,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: _loading || (!ready && !_failed)
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.mine
                              ? scheme.primaryContainer
                              : scheme.onPrimary))
                  : Icon(
                      _failed
                          ? Icons.music_off_rounded
                          : _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                      size: 26,
                      color: widget.mine
                          ? scheme.primaryContainer
                          : scheme.onPrimary),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: widget.width,
            child: AudioWaveform(
              seed: widget.seed ?? widget.url,
              bars: widget.waveform,
              progress: _progress,
              onSeek: ready ? _seek : null,
              activeColor: tint,
              height: 28,
            ),
          ),
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_failed ? 'Cannot play here' : _time,
                style: TextStyle(
                    fontSize: 11,
                    color: muted,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            if (widget.voice) ...[
              const SizedBox(width: 4),
              Icon(Icons.mic_rounded, size: 12, color: muted),
            ],
          ]),
        ],
      ),
    ]);
  }
}
