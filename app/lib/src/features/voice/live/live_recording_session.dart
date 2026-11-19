import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import '../../assistant/dictation_button.dart' show wav;
import '../voice_model.dart' show levelFromPcm16;
import 'live_voice_model.dart';

/// The microphone for a live voice chat turn, as one continuous session cut
/// into chunks on demand (rather than one recording per clip): the microphone
/// is asked for once, loudness is read for as long as the session lasts
/// (feeding the VAD that decides when a chunk, and the whole turn, end), and
/// each [cutChunk] closes one small audio file for transcription while the
/// next one is already recording.
abstract class LiveRecordingSession {
  /// Loudness 0..1: the loudest the microphone has been since the last call.
  double level();

  /// The audio since the last cut as a WAV file; a new chunk starts at once.
  /// Throws a [StateError] when nothing was captured.
  Future<Uint8List> cutChunk();

  /// Forget everything but the last [keep] of audio: while nothing has been
  /// said, a wait never piles up, yet speech's first syllable is not clipped.
  void trimTo(Duration keep);

  /// End the session and discard everything since the last cut.
  Future<void> close();
}

/// Opens a [LiveRecordingSession]; tests pass their own.
typedef LiveSessionOpener = Future<LiveRecordingSession> Function();

/// The device microphone, as 16 kHz mono PCM (what the node's transcription
/// model takes best), through the `record` package on every platform.
class RecordLiveSession implements LiveRecordingSession {
  RecordLiveSession._(this._recorder, Stream<Uint8List> pcm) {
    _sub = pcm.listen(_onPcm);
  }

  static const sampleRate = 16000;
  static const _bytesPerSecond = sampleRate * 2;

  /// Ask for the microphone once and keep it open for a whole live voice turn.
  static Future<LiveRecordingSession> open() async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        throw const LiveVoiceException('Allow microphone access to talk.');
      }
      final pcm = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      return RecordLiveSession._(recorder, pcm);
    } catch (_) {
      await recorder.dispose();
      rethrow;
    }
  }

  final AudioRecorder _recorder;
  late final StreamSubscription<Uint8List> _sub;
  final _pcm = BytesBuilder(copy: false);
  double _peak = 0;

  void _onPcm(Uint8List packet) {
    _pcm.add(packet);
    _peak = math.max(_peak, levelFromPcm16(packet));
  }

  @override
  double level() {
    final out = _peak;
    _peak = 0;
    return out;
  }

  @override
  Future<Uint8List> cutChunk() async {
    final pcm = _pcm.takeBytes();
    if (pcm.isEmpty) throw StateError('Nothing was recorded.');
    return wav(pcm, sampleRate);
  }

  @override
  void trimTo(Duration keep) {
    final keepBytes = (keep.inMilliseconds * _bytesPerSecond ~/ 1000) & ~1;
    if (_pcm.length <= keepBytes) return;
    final all = _pcm.takeBytes();
    _pcm.add(Uint8List.sublistView(all, all.length - keepBytes));
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {
      // Already stopped.
    }
    await _recorder.dispose();
  }
}
