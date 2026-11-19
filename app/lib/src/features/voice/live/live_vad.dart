/// Decides when to close a chunk and when a live voice turn is over, from the
/// microphone's loudness alone — never from what the words are. A chunk closes
/// on a short silence (so it can be sent off for transcription while listening
/// continues); the whole turn ends only once a longer silence holds *and* the
/// caller reports every chunk already sent has come back (so the last few
/// words are never dropped from the note). A port of Decillion's `liveVad.ts`.
library;

enum VadEvent {
  /// Speech began in a chunk that had none so far.
  speaking,

  /// Close the current chunk now and keep listening.
  chunkBoundary,

  /// The person has finished: stop listening and send what was said.
  turnOver,
}

class VadConfig {
  const VadConfig({
    this.speechThreshold = 0.15,
    this.chunkSilence = const Duration(milliseconds: 600),
    this.turnSilence = const Duration(milliseconds: 1300),
    this.maxChunk = const Duration(seconds: 20),
  });

  /// A loudness reading at or above this counts as speech.
  final double speechThreshold;

  /// Silence held this long (after speech) closes the current chunk.
  final Duration chunkSilence;

  /// Silence held this long, with the transcription queue drained, ends the turn.
  final Duration turnSilence;

  /// Longest a chunk may run while someone keeps talking without a pause, so
  /// it stays small enough for the node to transcribe.
  final Duration maxChunk;
}

class Vad {
  Vad(this.config, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    reset();
  }

  final VadConfig config;
  final DateTime Function() _now;

  late DateTime _lastSpeechAt;
  DateTime? _chunkSpeechAt;
  bool _everSpoken = false;

  /// Speech has been heard since the last chunk boundary and not yet sent off.
  bool get pendingSpeech => _chunkSpeechAt != null;

  /// Feed one loudness reading (and whether the transcription queue is
  /// drained); returns what just happened, if anything.
  VadEvent? tick(double level, {required bool queueDrained}) {
    final t = _now();
    if (level >= config.speechThreshold) {
      _lastSpeechAt = t;
      _everSpoken = true;
      final since = _chunkSpeechAt;
      if (since == null) {
        _chunkSpeechAt = t;
        return VadEvent.speaking;
      }
      if (t.difference(since) >= config.maxChunk) {
        _chunkSpeechAt = null;
        return VadEvent.chunkBoundary;
      }
      return null;
    }
    final silentFor = t.difference(_lastSpeechAt);
    if (silentFor >= config.turnSilence && queueDrained && _everSpoken) {
      return VadEvent.turnOver;
    }
    if (silentFor >= config.chunkSilence && pendingSpeech) {
      _chunkSpeechAt = null;
      return VadEvent.chunkBoundary;
    }
    return null;
  }

  /// Start over for a new turn (or a fresh listen after one ended).
  void reset() {
    _lastSpeechAt = _now();
    _chunkSpeechAt = null;
    _everSpoken = false;
  }
}
