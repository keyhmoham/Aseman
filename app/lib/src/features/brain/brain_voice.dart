import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../../data/services/aseman_service.dart';
import '../../elpian/core/media_file.dart';

/// Phase of the live Aseman voice loop.
enum BrainVoiceStatus { idle, listening, thinking, speaking }

/// Snapshot surfaced to the brain sheet.
class BrainVoiceState {
  const BrainVoiceState({
    this.status = BrainVoiceStatus.idle,
    this.heard = '',
    this.reply = '',
    this.error = '',
    this.speechReady = false,
    this.transcriptionReady = false,
    this.configLoaded = false,
  });

  final BrainVoiceStatus status;
  final String heard;
  final String reply;
  final String error;
  final bool speechReady;
  final bool transcriptionReady;
  final bool configLoaded;

  bool get voiceConfigured => speechReady && transcriptionReady;

  BrainVoiceState copyWith({
    BrainVoiceStatus? status,
    String? heard,
    String? reply,
    String? error,
    bool? speechReady,
    bool? transcriptionReady,
    bool? configLoaded,
  }) =>
      BrainVoiceState(
        status: status ?? this.status,
        heard: heard ?? this.heard,
        reply: reply ?? this.reply,
        error: error ?? this.error,
        speechReady: speechReady ?? this.speechReady,
        transcriptionReady: transcriptionReady ?? this.transcriptionReady,
        configLoaded: configLoaded ?? this.configLoaded,
      );
}

/// Mic → `users.voice_turn` → TTS playback loop until [stop] / [dispose].
class BrainVoiceClient extends ChangeNotifier {
  BrainVoiceClient(this.service);

  final AsemanService service;

  static const _rate = 16000;
  static const _silence = Duration(milliseconds: 700);
  static const _minSpeech = Duration(milliseconds: 280);
  static const _rmsGate = 380.0; // 16-bit PCM amplitude floor

  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _pcm = BytesBuilder(copy: false);

  StreamSubscription<Uint8List>? _micSub;
  Timer? _silenceTimer;
  bool _inCall = false;
  bool _speechHeard = false;
  bool _disposed = false;
  int _turn = 0;

  BrainVoiceState state = const BrainVoiceState();

  Future<void> loadConfig() async {
    try {
      final cfg = await service.voiceConfig();
      _set(state.copyWith(
        speechReady: cfg['speech'] == true,
        transcriptionReady: cfg['transcription'] == true,
        configLoaded: true,
        error: '',
      ));
    } catch (e) {
      _set(state.copyWith(
        configLoaded: true,
        speechReady: false,
        transcriptionReady: false,
        error: '$e',
      ));
    }
  }

  /// Starts (or resumes) the listen → turn → speak loop.
  Future<void> startCall() async {
    if (_disposed) return;
    await loadConfig();
    if (!state.voiceConfigured) {
      _set(state.copyWith(
        status: BrainVoiceStatus.idle,
        error: 'Voice is not set up on this node. Ask an admin to enable '
            'speech and transcription under Admin → AI → Voice.',
      ));
      return;
    }
    _inCall = true;
    await _listen();
  }

  /// Ends the call: stops mic and playback.
  Future<void> stop() async {
    _inCall = false;
    _turn++;
    _silenceTimer?.cancel();
    await _stopMic();
    try {
      await _player.stop();
    } catch (_) {}
    _set(state.copyWith(status: BrainVoiceStatus.idle, error: ''));
  }

  /// Interrupt current playback / thinking and return to listening if in call.
  Future<void> interrupt() async {
    _turn++;
    _silenceTimer?.cancel();
    try {
      await _player.stop();
    } catch (_) {}
    if (!_inCall || _disposed) {
      _set(state.copyWith(status: BrainVoiceStatus.idle));
      return;
    }
    await _listen();
  }

  /// End the current utterance early (tap while listening).
  Future<void> finishUtterance() async {
    if (state.status != BrainVoiceStatus.listening) return;
    await _endUtterance();
  }

  Future<void> _listen() async {
    if (!_inCall || _disposed) return;
    final turn = ++_turn;
    _pcm.clear();
    _speechHeard = false;
    _silenceTimer?.cancel();

    try {
      if (!await _recorder.hasPermission()) {
        _set(state.copyWith(
          status: BrainVoiceStatus.idle,
          error: 'Allow the microphone so Aseman can listen.',
        ));
        _inCall = false;
        return;
      }
      await _stopMic();
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _rate,
          numChannels: 1,
        ),
      );
      if (turn != _turn || !_inCall) {
        await _recorder.stop();
        return;
      }
      _set(state.copyWith(
        status: BrainVoiceStatus.listening,
        error: '',
      ));
      _micSub = stream.listen(
        (chunk) {
          if (turn != _turn || !_inCall) return;
          _pcm.add(chunk);
          _onPcm(chunk, turn);
        },
        onError: (Object e) {
          if (turn != _turn) return;
          _set(state.copyWith(
            status: BrainVoiceStatus.idle,
            error: '$e',
          ));
          _inCall = false;
        },
      );
    } catch (e) {
      _set(state.copyWith(
        status: BrainVoiceStatus.idle,
        error: '$e',
      ));
      _inCall = false;
    }
  }

  void _onPcm(Uint8List chunk, int turn) {
    final rms = _rms(chunk);
    if (rms >= _rmsGate) {
      _speechHeard = true;
      _silenceTimer?.cancel();
      _silenceTimer = Timer(_silence, () {
        if (turn == _turn) unawaited(_endUtterance());
      });
    } else if (_speechHeard && _silenceTimer == null) {
      _silenceTimer = Timer(_silence, () {
        if (turn == _turn) unawaited(_endUtterance());
      });
    }
  }

  Future<void> _endUtterance() async {
    if (state.status != BrainVoiceStatus.listening || !_inCall) return;
    final turn = _turn;
    _silenceTimer?.cancel();
    await _stopMic();

    final pcm = _pcm.takeBytes();
    final minBytes = (_rate * 2 * _minSpeech.inMilliseconds / 1000).round();
    if (!_speechHeard || pcm.length < minBytes) {
      if (_inCall && turn == _turn) await _listen();
      return;
    }

    _set(state.copyWith(status: BrainVoiceStatus.thinking, error: ''));
    try {
      final wavBytes = _wav(pcm, _rate);
      final out = await service.voiceTurn(
        audio: wavBytes,
        mime: 'audio/wav',
      );
      if (_disposed || turn != _turn || !_inCall) return;

      final heard = '${out['heard'] ?? out['transcript'] ?? out['text'] ?? ''}'
          .trim();
      final reply =
          '${out['reply'] ?? out['answer'] ?? out['response'] ?? ''}'.trim();
      _set(state.copyWith(heard: heard, reply: reply));

      final audioB64 = '${out['audio'] ?? ''}';
      final mime = '${out['mime'] ?? 'audio/mpeg'}';
      if (audioB64.isNotEmpty) {
        _set(state.copyWith(status: BrainVoiceStatus.speaking));
        final bytes = base64Decode(audioB64);
        await _play(Uint8List.fromList(bytes), mime);
      }
    } catch (e) {
      if (!_disposed && turn == _turn) {
        _set(state.copyWith(
          status: BrainVoiceStatus.idle,
          error: '$e',
        ));
        // Stay in the call when possible — resume listening.
      }
    }

    if (_disposed || turn != _turn) return;
    if (_inCall) {
      await _listen();
    } else {
      _set(state.copyWith(status: BrainVoiceStatus.idle));
    }
  }

  Future<void> _play(Uint8List bytes, String mime) async {
    try {
      final uri = await mediaUriForBytes(bytes, mime);
      await _player.setAudioSource(AudioSource.uri(uri));
      await _player.seek(Duration.zero);
      await _player.play();
      await _player.playerStateStream.firstWhere(
        (s) =>
            s.processingState == ProcessingState.completed ||
            (!s.playing && s.processingState == ProcessingState.ready),
      );
    } catch (e) {
      if (!_disposed) {
        _set(state.copyWith(error: 'Could not play the reply: $e'));
      }
    }
  }

  Future<void> _stopMic() async {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  void _set(BrainVoiceState next) {
    state = next;
    notifyListeners();
  }

  static double _rms(Uint8List pcm) {
    if (pcm.length < 4) return 0;
    final bd = ByteData.sublistView(pcm);
    final samples = pcm.length ~/ 2;
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final s = bd.getInt16(i * 2, Endian.little).toDouble();
      sum += s * s;
    }
    return math.sqrt(sum / samples);
  }

  @override
  void dispose() {
    _disposed = true;
    _inCall = false;
    _turn++;
    _silenceTimer?.cancel();
    final mic = _micSub;
    _micSub = null;
    if (mic != null) unawaited(mic.cancel());
    unawaited(_releaseDevices());
    super.dispose();
  }

  Future<void> _releaseDevices() async {
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    try {
      await _recorder.dispose();
    } catch (_) {}
    try {
      await _player.dispose();
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
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
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
