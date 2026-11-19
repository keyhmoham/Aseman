import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../../../elpian/core/media_file.dart';

/// Speech from the node's speech model (`users.voice_speak`): audio to play.
class SpeechClip {
  const SpeechClip(this.audio, this.mime);

  final Uint8List audio;
  final String mime;
}

/// Plays one clip to its end, or until stopped.
abstract class ClipPlayer {
  Future<void> play(SpeechClip clip);
  Future<void> stop();
  Future<void> dispose();
}

/// Decillion's voice, from the node's speech model (Admin → AI → Voice). A
/// piece is asked for as soon as it is known, while the one before it is still
/// playing, so there is no gap between sentences; they play in order. A piece
/// the node cannot speak is skipped (and reported), never left to stall the
/// ones after it. A port of Decillion's `remoteSpeech.ts`.
class LiveSpeaker {
  LiveSpeaker({
    required this.fetch,
    required ClipPlayer player,
    this.onFailure,
  }) : _player = player;

  /// Asks the node to say [text]; throws when it cannot.
  final Future<SpeechClip> Function(String text) fetch;

  /// A piece could not be spoken.
  final void Function(Object error)? onFailure;

  final ClipPlayer _player;
  final _queue = Queue<_Piece>();
  bool _busy = false;
  int _epoch = 0;

  /// Say a piece; [onDone] runs when it has been said (or was cut off, or
  /// could not be said).
  void speak(String text, void Function() onDone) {
    _queue.add(_Piece(onDone, _fetch(text)));
    unawaited(_pump());
  }

  /// Cut off what is playing and drop what is waiting.
  Future<void> stop() async {
    _epoch++;
    final dropped = _queue.toList();
    _queue.clear();
    for (final piece in dropped) {
      piece.onDone();
    }
    await _player.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }

  Future<SpeechClip?> _fetch(String text) async {
    try {
      return await fetch(text);
    } catch (e) {
      onFailure?.call(e);
      return null;
    }
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final piece = _queue.removeFirst();
        final mine = _epoch;
        final clip = await piece.clip;
        // stop() ran the onDone of what was still waiting; this piece had
        // already left the queue, so its own is run here either way.
        if (clip != null && mine == _epoch) {
          try {
            await _player.play(clip);
          } catch (e) {
            onFailure?.call(e);
          }
        }
        piece.onDone();
      }
    } finally {
      _busy = false;
    }
  }
}

class _Piece {
  _Piece(this.onDone, this.clip);

  final void Function() onDone;
  final Future<SpeechClip?> clip;
}

/// Plays clips with `just_audio`: from a temporary file on devices, a `data:`
/// URI on the web.
class JustAudioClipPlayer implements ClipPlayer {
  final _player = AudioPlayer();
  int _generation = 0;

  @override
  Future<void> play(SpeechClip clip) async {
    final mine = _generation;
    try {
      final uri = await mediaUriForBytes(clip.audio, clip.mime);
      if (mine != _generation) return;
      await _player.setAudioSource(AudioSource.uri(uri));
      if (mine != _generation) return;
      await _player.play(); // returns once it has played to its end (or stopped)
    } on PlayerInterruptedException {
      // stop() cut it off.
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _player.stop();
  }

  @override
  Future<void> dispose() => _player.dispose();
}
