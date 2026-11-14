import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';

/// The composer's microphone. It records 16 kHz mono PCM, sends it as WAV to developer.dictate
/// (the node's transcription model, billed to the person) and hands the text
/// to [onText] to put in the composer, never sending it by itself.
class DictationButton extends StatefulWidget {
  const DictationButton({
    super.key,
    required this.dependencies,
    required this.onText,
    this.style,
  });
  final AppDependencies dependencies;
  final ValueChanged<String> onText;
  /// Optional chrome so the composer can match attach / send geometry.
  final ButtonStyle? style;

  @override
  State<DictationButton> createState() => _DictationButtonState();
}

enum _State { idle, recording, writing }

class _DictationButtonState extends State<DictationButton> {
  static const _rate = 16000;
  static const _limit = Duration(minutes: 2);

  final _recorder = AudioRecorder();
  final _pcm = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _stream;
  Timer? _cap;
  _State state = _State.idle;

  @override
  void dispose() {
    _cap?.cancel();
    _stream?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (!await _recorder.hasPermission()) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('Allow the microphone for Aseman to dictate.'),
          ),
        );
        return;
      }
      _pcm.clear();
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _rate,
          numChannels: 1,
        ),
      );
      _stream = stream.listen(_pcm.add);
      _cap = Timer(_limit, _stop);
      setState(() => state = _State.recording);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  Future<void> _stop() async {
    _cap?.cancel();
    if (state != _State.recording) return;
    setState(() => state = _State.writing);
    try {
      await _recorder.stop();
      await _stream?.cancel();
      _stream = null;
      final pcm = _pcm.takeBytes();
      if (pcm.length < _rate) {
        // Under half a second: nothing said.
        if (mounted) setState(() => state = _State.idle);
        return;
      }
      if (!mounted) return;
      final out = await runAction(
        context,
        widget.dependencies,
        'developer',
        'dictate',
        {'audio': base64Encode(wav(pcm, _rate)), 'media_type': 'audio/wav'},
      );
      final text = '${out?['text'] ?? ''}'.trim();
      if (text.isNotEmpty) widget.onText(text);
    } finally {
      if (mounted) setState(() => state = _State.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = widget.style;
    return switch (state) {
      _State.idle => IconButton(
        tooltip: 'Dictate',
        style: style,
        onPressed: _start,
        icon: const Icon(Icons.mic_none_rounded, size: 20),
      ),
      _State.recording => IconButton(
        tooltip: 'Stop and write it down',
        style: style,
        onPressed: _stop,
        icon: Icon(Icons.stop_circle_rounded, size: 20, color: scheme.error),
      ),
      _State.writing => const SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    };
  }
}

/// A WAV file of 16-bit little-endian mono [pcm] at [rate] Hz.
Uint8List wav(Uint8List pcm, int rate) {
  final header = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}
