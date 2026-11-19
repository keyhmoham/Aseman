import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'live_recording_session.dart';
import 'live_speaker.dart';
import 'live_vad.dart';
import 'live_voice_backend.dart';
import 'live_voice_model.dart';
import 'transcribe_queue.dart';

/// How a live voice chat paces itself. The defaults are the app's; tests pass
/// shorter ones.
class LiveVoiceTiming {
  const LiveVoiceTiming({
    this.vad = const VadConfig(),
    this.listenTick = const Duration(milliseconds: 100),
    this.pollTick = const Duration(milliseconds: 300),
    this.drainPoll = const Duration(milliseconds: 100),
    this.giveUp = const Duration(seconds: 90),
    this.preRoll = const Duration(seconds: 1),
    this.silentRestarts = 5,
  });

  final VadConfig vad;

  /// How often the microphone's loudness is checked against the VAD.
  final Duration listenTick;

  /// How often the conversation is looked at again while an answer is awaited.
  final Duration pollTick;

  /// Once the turn is over, how often to check that every chunk sent for
  /// transcription has come back.
  final Duration drainPoll;

  /// How long to wait for an answer to begin before giving up.
  final Duration giveUp;

  /// Audio kept from before speech is first heard, so its first syllable is
  /// never clipped.
  final Duration preRoll;

  /// Turns that heard nothing, listened through again before waiting for a tap.
  final int silentRestarts;
}

/// Shown where voice cannot be used because the node has no voice models on.
const liveVoiceSetupMessage = 'Voice is not set up on this node. Ask an admin '
    'to enable speech and transcription under Admin → AI → Voice.';

/// Talking with Decillion: it listens, what you say goes to your Decillion
/// (or an agent) as a note — so its brain, memory, tools and your credits work
/// exactly as when you type — its answer is spoken a sentence at a time while
/// it is still being written, and it listens again. Tap to interrupt it. A
/// bare spoken "yes" never confirms what it proposed: that stays a tap on the
/// screen. A port of Decillion's `useLiveVoice`.
///
/// Listening is driven entirely by the microphone's loudness ([Vad]), never by
/// what the words are: a chunk closes on a short silence and is sent off for
/// transcription while the next one is already being recorded
/// ([TranscribeQueue]), and the whole turn ends only once a longer silence
/// holds and every chunk sent has come back. This needs no declared language
/// to listen in and no device speech recognizer: a silence is a silence in any
/// language.
class LiveVoiceController extends ChangeNotifier {
  LiveVoiceController({
    required this.backend,
    LiveSessionOpener? openSession,
    ClipPlayer? player,
    this.timing = const LiveVoiceTiming(),
    DateTime Function()? now,
  })  : _openSession = openSession ?? RecordLiveSession.open,
        _now = now ?? DateTime.now,
        _vad = Vad(timing.vad, now: now) {
    _speaker = LiveSpeaker(
      fetch: backend.speak,
      player: player ?? JustAudioClipPlayer(),
      onFailure: (_) => _notify(
        notice: 'Couldn’t play the spoken answer. Its text is on screen.',
      ),
    );
  }

  final LiveVoiceBackend backend;
  final LiveVoiceTiming timing;
  final LiveSessionOpener _openSession;
  final DateTime Function() _now;
  final Vad _vad;
  final _queue = TranscribeQueue();
  late final LiveSpeaker _speaker;

  LiveState _state = LiveState.paused;
  String _heard = '';
  String _said = '';
  String _notice = '';
  LiveProposal? _proposal;
  bool _confirming = false;
  LiveVoiceConfig? _config;

  /// Whether a live voice chat is running (it ends only on [end]).
  bool _active = false;
  bool _disposed = false;

  /// Whether a turn is being wound down: further VAD ticks and taps are ignored.
  bool _endingTurn = false;
  int _turn = 0; // bumped whenever a listen begins or the chat ends
  int _silent = 0;
  LiveRecordingSession? _session;
  String? _note;
  int _spoken = 0;
  int _pieces = 0;
  DateTime _since = DateTime.fromMillisecondsSinceEpoch(0);
  bool _polling = false;
  Timer? _listenTimer;
  Timer? _pollTimer;

  LiveState get state => _state;

  /// What was last heard, as the note that was sent.
  String get heard => _heard;

  /// What Decillion is saying (the answer so far).
  String get said => _said;

  /// Something for the person to know: a hint, or why it stopped.
  String get notice => _notice;

  /// What Decillion proposed and waits on: it takes a tap, never a spoken yes.
  LiveProposal? get proposal => _proposal;

  /// A confirm or cancel is going to the node.
  bool get confirming => _confirming;

  bool get active => _active;

  /// The node's voice models have been looked up.
  bool get configLoaded => _config != null;

  /// Both voice models are on, so live voice can work.
  bool get ready => _config?.ready ?? false;

  /// The node has no voice models on (and has said so).
  bool get setupNeeded => configLoaded && !ready;

  /// Ask the node which voice models it serves.
  Future<void> loadConfig() async {
    try {
      _config = await backend.config();
    } catch (_) {
      _config = const LiveVoiceConfig();
    }
    _notify();
  }

  /// Start talking: listen at once.
  Future<void> start() async {
    if (_disposed) return;
    await loadConfig();
    if (_disposed) return;
    if (!ready) {
      _notify(state: LiveState.paused, notice: liveVoiceSetupMessage);
      return;
    }
    _active = true;
    _silent = 0;
    _startTimers();
    _notify(state: LiveState.starting, notice: '');
    await _listen();
  }

  /// End the chat: stop the microphone and the voice.
  Future<void> end() async {
    if (!_disposed) await _halt();
  }

  Future<void> _halt() async {
    _active = false;
    _endingTurn = false;
    _note = null;
    _turn++;
    _stopTimers();
    _queue.cancel();
    final session = _session;
    _session = null;
    _notify(state: LiveState.paused, notice: '');
    await Future.wait([
      _speaker.stop(),
      if (session != null) _closeQuietly(session),
    ]);
  }

  /// Tap: cut Decillion off and talk, say you are done now instead of waiting
  /// out the silence, or start listening again after a pause or an error.
  Future<void> tap() async {
    switch (_state) {
      case LiveState.speaking:
      case LiveState.thinking:
        _pieces = 0;
        _active = true;
        _startTimers();
        await _speaker.stop();
        await _listen();
      case LiveState.paused:
      case LiveState.error:
        if (!ready) {
          await start();
          return;
        }
        _active = true;
        _silent = 0;
        _startTimers();
        await _listen();
      case LiveState.listening:
        final session = _session;
        if (session != null && !_endingTurn) {
          // Said what you meant: end the turn now, keeping what is still being said.
          _session = null;
          await _finishTurn(session, flush: true);
        }
      case LiveState.starting:
        break;
    }
  }

  /// Confirm or cancel what Decillion proposed.
  Future<void> confirm({required bool approve}) async {
    final proposal = _proposal;
    if (proposal == null || _confirming) return;
    _notify(confirming: true);
    try {
      await backend.confirm(proposal.id, approve: approve);
      _proposal = null;
      _notify(confirming: false, notice: '');
    } catch (_) {
      _notify(
        confirming: false,
        notice: 'Couldn’t ${approve ? 'confirm' : 'cancel'} that. Try again.',
      );
    }
  }

  Future<void> _listen() async {
    if (!_active || _disposed) return;
    final turn = ++_turn;
    final stale = _session;
    _session = null;
    if (stale != null) unawaited(_closeQuietly(stale));
    _note = null;
    _queue.reset();
    _vad.reset();
    _endingTurn = false;
    _notify(state: LiveState.listening, heard: '');
    try {
      final session = await _openSession();
      if (turn != _turn || !_active) {
        await _closeQuietly(session); // ended while the microphone was opening
        return;
      }
      _session = session;
    } catch (e) {
      if (turn != _turn) return;
      _fail(e is LiveVoiceException ? e.message : 'Couldn’t start listening.');
    }
  }

  /// Ends the listening turn: closes the session and waits for everything
  /// already queued to come back before deciding what (if anything) was said.
  ///
  /// The segment still open when a turn ends by silence is never sent: a
  /// chunk boundary always closes (and sends) anything actually said before
  /// the longer silence that ends the turn, so what's left open is only that
  /// silence — and a silent clip is exactly what a general model tends to
  /// hallucinate text for. A turn the person ends by tapping is different:
  /// they may be mid-sentence, so [flush] sends what has been said since.
  Future<void> _finishTurn(
    LiveRecordingSession session, {
    bool flush = false,
  }) async {
    final turn = _turn;
    _endingTurn = true;
    if (flush && _vad.pendingSpeech) {
      try {
        _queue.enqueue(_transcribe(await session.cutChunk()));
      } catch (_) {
        // Nothing captured between two ticks: nothing to send.
      }
    }
    await _closeQuietly(session);
    while (!_queue.drained) {
      await Future<void>.delayed(timing.drainPoll);
      if (turn != _turn) return; // ended or interrupted meanwhile
    }
    if (turn != _turn || !_active) return;
    _endingTurn = false;
    final text = _queue.accumulated.trim();
    if (worthSending(text)) {
      _silent = 0;
      await _handle(text);
      return;
    }
    // Nothing said: listen again, a few times, then wait to be tapped.
    if (++_silent > timing.silentRestarts) {
      _silent = 0;
      _notify(state: LiveState.paused);
      return;
    }
    await _listen();
  }

  Future<void> _handle(String text) async {
    if (_proposal != null && isBareYesNo(text)) {
      _notify(notice: 'Tap Confirm on the screen to go ahead.');
      await _listen();
      return;
    }
    final turn = _turn;
    _spoken = 0;
    _pieces = 0;
    _since = _now();
    _note = null;
    _notify(state: LiveState.thinking, heard: text, said: '', notice: '');
    try {
      final note = await backend.sendNote(text);
      if (turn == _turn && _active) _note = note;
    } catch (_) {
      if (turn == _turn) _fail('Couldn’t send that. Tap to try again.');
    }
  }

  Future<String> _transcribe(Uint8List wav) async {
    try {
      return await backend.transcribeChunk(wav);
    } catch (_) {
      // A failed or silent chunk contributes nothing rather than breaking the turn.
      return '';
    }
  }

  void _listenTick() {
    final session = _session;
    if (_state != LiveState.listening || session == null || _endingTurn) {
      return;
    }
    // Until something is said, only the last moment is kept.
    if (!_vad.pendingSpeech) session.trimTo(timing.preRoll);
    final event = _vad.tick(session.level(), queueDrained: _queue.drained);
    switch (event) {
      case null:
      case VadEvent.speaking:
        return;
      case VadEvent.chunkBoundary:
        unawaited(
          session.cutChunk().then(
                (chunk) => _queue.enqueue(_transcribe(chunk)),
                onError: (_) {}, // nothing captured between two ticks
              ),
        );
      case VadEvent.turnOver:
        _session = null;
        unawaited(_finishTurn(session));
    }
  }

  void _pollTick() {
    final note = _note;
    if ((_state != LiveState.thinking && _state != LiveState.speaking) ||
        !_active ||
        note == null ||
        _polling) {
      return;
    }
    _polling = true;
    unawaited(_poll(note));
  }

  Future<void> _poll(String note) async {
    try {
      _consume(note, await backend.snapshot(note));
    } catch (_) {
      // The next look will do: only an answer that never comes ends the wait.
      _giveUpIfLate();
    } finally {
      _polling = false;
    }
  }

  void _giveUpIfLate() {
    if (_now().difference(_since) > timing.giveUp) {
      _fail('No answer came. Tap to try again.');
    }
  }

  /// Waiting for and speaking the answer, a sentence at a time as it is written.
  void _consume(String note, LiveSnapshot snapshot) {
    if (note != _note ||
        !_active ||
        (_state != LiveState.thinking && _state != LiveState.speaking)) {
      return;
    }
    if (snapshot.proposal?.id != _proposal?.id) {
      _proposal = snapshot.proposal;
      _notify();
    }
    final answer = snapshot.answer;
    if (answer == null) {
      _giveUpIfLate();
      return;
    }
    final text = answer.text;
    _spoken = math.min(_spoken, text.length); // the answer may be rewritten shorter
    _notify(said: text);
    var end = sentenceEnd(text, _spoken, answer.done, eager: _spoken == 0);
    while (end >= 0) {
      final piece = spokenText(text.substring(_spoken, end));
      _spoken = end;
      if (piece.isNotEmpty) {
        _pieces++;
        _notify(state: LiveState.speaking);
        _speaker.speak(piece, () => _pieces = math.max(0, _pieces - 1));
      }
      end = sentenceEnd(text, _spoken, answer.done, eager: _spoken == 0);
    }
    if (answer.done && _spoken >= text.length && _pieces == 0) {
      unawaited(_listen());
    }
  }

  void _fail(String message) {
    _note = null;
    _notify(state: LiveState.error, notice: message);
  }

  void _startTimers() {
    _listenTimer ??= Timer.periodic(timing.listenTick, (_) => _listenTick());
    _pollTimer ??= Timer.periodic(timing.pollTick, (_) => _pollTick());
  }

  void _stopTimers() {
    _listenTimer?.cancel();
    _pollTimer?.cancel();
    _listenTimer = _pollTimer = null;
  }

  Future<void> _closeQuietly(LiveRecordingSession session) async {
    try {
      await session.close();
    } catch (_) {
      // Already closed.
    }
  }

  void _notify({
    LiveState? state,
    String? heard,
    String? said,
    String? notice,
    bool? confirming,
  }) {
    _state = state ?? _state;
    _heard = heard ?? _heard;
    _said = said ?? _said;
    _notice = notice ?? _notice;
    _confirming = confirming ?? _confirming;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_halt().whenComplete(_speaker.dispose));
    super.dispose();
  }
}
