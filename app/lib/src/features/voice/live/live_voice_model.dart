/// Live voice with Decillion as pure logic (the loop itself is
/// `LiveVoiceController`): what you say becomes a note, its answer is spoken a
/// sentence at a time as it is written, and you are listened to again after.
/// The same models answer as in the text chat; only the ears and mouth are the
/// device's. A port of Decillion's `liveVoiceModel.ts`.
library;

/// Where a live voice chat is.
enum LiveState { starting, listening, thinking, speaking, paused, error }

/// What the chat says under the avatar for each [LiveState].
const liveCaptions = <LiveState, String>{
  LiveState.starting: 'Getting ready…',
  LiveState.listening: 'Listening…',
  LiveState.thinking: 'Thinking…',
  LiveState.speaking: 'Tap to interrupt',
  LiveState.paused: 'Tap to talk',
  LiveState.error: 'Couldn’t listen',
};

/// Something that stops a live voice chat, in words for the person.
class LiveVoiceException implements Exception {
  const LiveVoiceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What Decillion has answered a note so far.
class LiveAnswer {
  const LiveAnswer(this.text, {required this.done});

  final String text;

  /// The answer is complete (stored), not still being written.
  final bool done;
}

/// What Decillion proposed to do and waits for a tap on.
class LiveProposal {
  const LiveProposal({required this.id, this.steps = const []});

  /// The message that carries the proposal (`users.brain_confirm`'s `message`).
  final String id;
  final List<String> steps;
}

/// One look at the conversation while a note is being answered.
class LiveSnapshot {
  const LiveSnapshot({this.answer, this.proposal});

  /// The answer to the note: null while it has not begun.
  final LiveAnswer? answer;

  /// The latest answer's pending proposal, if there is one.
  final LiveProposal? proposal;
}

/// The note's answer (and any pending proposal) from a `users.dm_list` reply.
///
/// An answer is a message replying to the note that is not the person's own
/// (an agent's reply in a direct chat) or is written by their Decillion into
/// their own notes (`agent_id`). Until it is stored, what is being written
/// shows in `agents_working` (a note still being decided on shows nothing). A
/// note Decillion kept without answering is acknowledged.
LiveSnapshot parseLiveSnapshot(
  Map<String, dynamic> json, {
  required String noteId,
  required String me,
}) {
  final messages = [
    for (final m in json['messages'] as List? ?? const [])
      if (m is Map) m.cast<String, dynamic>(),
  ];
  bool answers(Map<String, dynamic> m) =>
      m['reply_to'] == noteId &&
      m['deleted'] != true &&
      m['kind'] != 'log' && // an agent's working notes are shown, not said
      m['kind'] != 'ui' &&
      ('${m['agent_id'] ?? ''}'.isNotEmpty || m['from_id'] != me);

  LiveProposal? proposal;
  for (final m in messages.reversed) {
    final p = m['proposal'];
    if ('${m['agent_id'] ?? ''}'.isEmpty || p is! Map) continue;
    if (p['status'] == 'pending') {
      proposal = LiveProposal(
        id: '${m['id'] ?? ''}',
        steps: [for (final s in p['steps'] as List? ?? const []) '$s'],
      );
    }
    break;
  }

  final answer = messages.where(answers).firstOrNull;
  if (answer != null) {
    return LiveSnapshot(
      answer: LiveAnswer('${answer['body'] ?? ''}', done: true),
      proposal: proposal,
    );
  }
  final note = messages.where((m) => m['id'] == noteId).firstOrNull;
  if (note != null && note['brain'] == 'saved') {
    return LiveSnapshot(
      answer: const LiveAnswer('Noted.', done: true),
      proposal: proposal,
    );
  }
  final writing = [
    for (final w in json['agents_working'] as List? ?? const [])
      if (w is Map && w['message_id'] == noteId && w['deciding'] != true)
        w.cast<String, dynamic>(),
  ].firstOrNull;
  return LiveSnapshot(
    answer: writing == null
        ? null
        : LiveAnswer('${writing['text'] ?? ''}', done: false),
    proposal: proposal,
  );
}

final _sentenceStop = RegExp(r'''[.!?؟…]+["”')\]]*(\s|$)|\n+''');
final _softStop = RegExp(r'[,;:،]\s');

/// Where in [text] the next piece to speak ends, past [from]; -1 while nothing
/// is ready yet. A sentence is spoken when complete. The first piece of an
/// answer is [eager]: it starts at a comma, or after a few words, so the voice
/// begins while the rest is still being written.
int sentenceEnd(String text, int from, bool isFinal, {bool eager = false}) {
  final rest = text.substring(from);
  final m = _sentenceStop.firstMatch(rest);
  if (m != null) {
    final end = m.start + m[0]!.length;
    if (end < rest.length || RegExp(r'\s$').hasMatch(m[0]!) || isFinal) {
      return from + end;
    }
  }
  if (eager) {
    final comma = rest.indexOf(_softStop);
    if (comma >= 14) return from + comma + 2;
    if (rest.length > 55) {
      final cut = rest.lastIndexOf(' ', 55);
      if (cut > 25) return from + cut + 1;
    }
  }
  // A long run with no stop is spoken at a comma or a space, so a streamed
  // answer never waits on one sentence.
  if (rest.length > 160) {
    final cut = [rest.lastIndexOf(', ', 160), rest.lastIndexOf(' ', 160)]
        .reduce((a, b) => a > b ? a : b);
    if (cut > 40) return from + cut + 1;
  }
  return isFinal && rest.trim().isNotEmpty ? text.length : -1;
}

/// What is said aloud for a piece of an answer: its markup, links and symbols
/// left out.
String spokenText(String piece) => piece
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
    .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'https?://\S+'), '')
    .replaceAll(RegExp(r'[*_#>~|]+'), '')
    .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
    .replaceAll(RegExp(r'[✓✗→]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

final _bareYesNo = RegExp(
  r'^\s*(yes|yep|yeah|y|ok|okay|sure|confirm(ed)?|do it|go ahead|go|please do|'
  r"no|nope|n|cancel|don'?t|stop|بله|آره|باشه|انجام بده|نه|لغو|نکن)\s*[.!]*\s*$",
  caseSensitive: false,
);

/// A bare yes or no: said aloud, it must not confirm what Decillion proposed
/// (that stays a tap on the screen).
bool isBareYesNo(String text) => _bareYesNo.hasMatch(text);

/// What the person said is worth sending: not just a sound or two.
bool worthSending(String text) =>
    text.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '').length >= 2;
