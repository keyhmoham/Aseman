import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_shape.dart';
import '../../shared/widgets/audio_waveform.dart';
import 'voice_model.dart';
import 'voice_recorder.dart';

/// Composer replacement while a voice message is made (Decillion's
/// `VoiceRecorderBar`): discard, live/preview wave, stop-to-listen, send.
class VoiceRecorderBar extends StatefulWidget {
  const VoiceRecorderBar({
    super.key,
    required this.phase,
    required this.startedAt,
    required this.level,
    this.file,
    required this.onStop,
    required this.onCancel,
    required this.onSend,
    required this.onLimit,
  });

  /// `recording` or `stopped` (preview before send).
  final String phase;
  final DateTime startedAt;

  /// Current loudness 0..1 while recording.
  final double Function() level;
  final VoiceNote? file;
  final VoidCallback onStop;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  final VoidCallback onLimit;

  @override
  State<VoiceRecorderBar> createState() => _VoiceRecorderBarState();
}

class _VoiceRecorderBarState extends State<VoiceRecorderBar> {
  static const _red = Color(0xFFE5484D);
  Timer? _tick;
  final _heard = <double>[];
  DateTime _now = DateTime.now();
  AudioPlayer? _player;
  bool _playing = false;

  bool get _recording => widget.phase == 'recording';

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (_recording) {
        final elapsed =
            DateTime.now().difference(widget.startedAt).inMilliseconds;
        if (elapsed >= maxVoiceMs) {
          widget.onLimit();
          return;
        }
        setState(() {
          _now = DateTime.now();
          _heard.add(widget.level().clamp(0.0, 1.0));
          if (_heard.length > 240) {
            _heard.removeRange(0, _heard.length - 240);
          }
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant VoiceRecorderBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file != widget.file) {
      unawaited(_releasePlayer());
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_releasePlayer());
    super.dispose();
  }

  Future<void> _releasePlayer() async {
    final p = _player;
    _player = null;
    _playing = false;
    if (p != null) {
      try {
        await p.dispose();
      } catch (_) {}
    }
  }

  Future<void> _togglePreview() async {
    final file = widget.file;
    if (file == null) return;
    try {
      var player = _player;
      if (player == null) {
        player = AudioPlayer();
        _player = player;
        await player.setAudioSource(
          AudioSource.uri(
            Uri.dataFromBytes(file.bytes, mimeType: file.mime),
          ),
        );
        player.playerStateStream.listen((s) {
          if (!mounted) return;
          if (s.processingState == ProcessingState.completed) {
            setState(() => _playing = false);
          }
        });
      }
      if (_playing) {
        await player.pause();
        setState(() => _playing = false);
      } else {
        if (player.processingState == ProcessingState.completed) {
          await player.seek(Duration.zero);
        }
        await player.play();
        setState(() => _playing = true);
      }
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = _now.difference(widget.startedAt).inMilliseconds;
    final file = widget.file;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Discard voice message',
            onPressed: widget.onCancel,
            icon: const Icon(Icons.delete_outline_rounded, color: _red),
          ),
          Expanded(
            child: _recording
                ? Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: _red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatVoiceClock(elapsed),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AudioWaveform(
                          seed: 'live',
                          progress: 1,
                          height: 26,
                          activeColor: _red,
                          inactiveColor: _red.withValues(alpha: .35),
                          bars: [
                            for (final l in _heard) (l * 100).round().clamp(0, 100),
                          ],
                        ),
                      ),
                    ],
                  )
                : file == null
                    ? const SizedBox.shrink()
                    : Row(
                        children: [
                          IconButton(
                            tooltip: _playing ? 'Pause' : 'Play',
                            onPressed: _togglePreview,
                            icon: Icon(
                              _playing
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_filled_rounded,
                              color: scheme.primary,
                            ),
                          ),
                          Expanded(
                            child: AudioWaveform(
                              seed: file.name,
                              progress: 0,
                              height: 26,
                              bars: file.waveform.isEmpty
                                  ? null
                                  : file.waveform,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatVoiceClock(file.durationMs),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
          ),
          if (_recording)
            IconButton(
              tooltip: 'Stop and listen before sending',
              onPressed: widget.onStop,
              icon: const Icon(Icons.stop_circle_rounded, color: _red),
            ),
          IconButton.filled(
            tooltip: 'Send voice message',
            onPressed: widget.onSend,
            style: IconButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: AppShape.borderRadius(context, 20),
              ),
            ),
            icon: const Icon(Icons.send_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

