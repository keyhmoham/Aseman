import 'dart:collection';

/// The chunks of one live voice turn, sent off for transcription as soon as
/// each closes while listening keeps going, and folded into one note in the
/// order they were spoken — even if a later chunk's request happens to come
/// back before an earlier one's. A request is fired the moment a chunk is
/// ready; only the results are consumed strictly in the order they were pushed.
///
/// It only ever sees a `Future<String>` the caller already started, never the
/// chunk's bytes or the network call, so it stays testable on its own.
class TranscribeQueue {
  final _queue = Queue<Future<String>>();
  bool _busy = false;
  int _epoch = 0;
  String _text = '';

  /// Push a just-closed chunk's transcription, already under way; its text,
  /// once it resolves, is appended to the note in chunk order. A failed
  /// request counts as nothing said, so one bad chunk never breaks the turn.
  void enqueue(Future<String> text) {
    _queue.add(text);
    _pump();
  }

  /// Whether every pushed chunk has come back and been folded into the note.
  bool get drained => _queue.isEmpty && !_busy;

  /// The note so far this turn.
  String get accumulated => _text;

  /// Start a new turn. Call it once [drained]: it cancels nothing in flight.
  void reset() => _text = '';

  /// The person interrupted mid-turn: drop everything queued and in flight.
  void cancel() {
    _epoch++;
    _queue.clear();
    _busy = false;
    _text = '';
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    final mine = _epoch;
    try {
      while (mine == _epoch && _queue.isNotEmpty) {
        String text;
        try {
          text = await _queue.removeFirst(); // the head: submission order
        } catch (_) {
          text = '';
        }
        if (mine != _epoch) return; // cancelled while this one was in flight
        if (text.isNotEmpty) _text = _text.isEmpty ? text : '$_text $text';
      }
    } finally {
      if (mine == _epoch) _busy = false;
    }
  }
}
