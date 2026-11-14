import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'voice_model.dart';

/// A finished voice note ready for `users.dm_file_upload` (`voice: true`).
class VoiceNote {
  const VoiceNote({
    required this.bytes,
    required this.name,
    required this.mime,
    required this.durationMs,
    required this.waveform,
  });

  final Uint8List bytes;
  final String name;
  final String mime;
  final int durationMs;
  final List<int> waveform;
}

/// In-app voice-message recorder: 24 kHz mono PCM → WAV, with a live level
/// meter folded into Decillion-style waveform bars on stop.
class VoiceMessageRecorder {
  VoiceMessageRecorder();

  static const sampleRate = 24000;

  final _recorder = AudioRecorder();
  final _pcm = BytesBuilder(copy: false);
  final _levels = <double>[];
  StreamSubscription<Uint8List>? _stream;
  DateTime? _startedAt;
  bool _active = false;

  /// Latest loudness 0..1 while recording (for the live wave).
  double level = 0;

  bool get isRecording => _active;

  DateTime get startedAt => _startedAt ?? DateTime.now();

  Future<void> start() async {
    if (_active) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('Allow microphone access to record a voice message.');
    }
    _pcm.clear();
    _levels.clear();
    level = 0;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _startedAt = DateTime.now();
    _active = true;
    _stream = stream.listen((chunk) {
      if (!_active) return;
      _pcm.add(chunk);
      final next = levelFromPcm16(chunk);
      level = next;
      _levels.add(next);
      // Cap memory for very long takes (meter is sampled per chunk).
      if (_levels.length > 3000) {
        _levels.removeRange(0, _levels.length - 2400);
      }
    });
  }

  /// Stop and build the voice note. Throws if nothing was captured.
  Future<VoiceNote> stop() async {
    if (!_active) {
      throw StateError('Nothing was recorded.');
    }
    _active = false;
    final started = _startedAt ?? DateTime.now();
    try {
      await _recorder.stop();
    } catch (_) {}
    await _stream?.cancel();
    _stream = null;
    final pcm = _pcm.takeBytes();
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    final fromSamples =
        pcm.length < 2 ? 0 : (pcm.length ~/ 2) * 1000 ~/ sampleRate;
    final durationMs =
        (fromSamples > 0 ? fromSamples : elapsed).clamp(0, maxVoiceMs);
    if (pcm.isEmpty) {
      throw StateError('Nothing was recorded.');
    }
    final stamp = started
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return VoiceNote(
      bytes: _wav(pcm, sampleRate),
      name: 'voice-$stamp.wav',
      mime: 'audio/wav',
      durationMs: durationMs,
      waveform: levelsToWaveBars(List<double>.from(_levels)),
    );
  }

  /// Discard the in-progress recording.
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    try {
      await _recorder.cancel();
    } catch (_) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    await _stream?.cancel();
    _stream = null;
    _pcm.clear();
    _levels.clear();
    level = 0;
  }

  Future<void> dispose() async {
    await cancel();
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}

/// WAV container for 16-bit little-endian mono [pcm] at [rate] Hz.
Uint8List _wav(Uint8List pcm, int rate) {
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
