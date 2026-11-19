/// The tappable answers an agent offers at the end of a message: a last line
/// `<replies>first | second | third</replies>`. The line itself is not shown;
/// the latest agent message shows them as chips (as the node's Slack and
/// Teams channels show buttons).
library;

/// How many replies are shown, and how long each may be.
const maxReplies = 3;
const maxReplyLength = 40;

final _line = RegExp(r'\n?[ \t]*<replies>([\s\S]*?)</replies>[ \t]*$');

final _partial = RegExp(
  r'\n?[ \t]*<re(?:p(?:l(?:i(?:e(?:s(?:>[^<]*)?)?)?)?)?)?$',
);

/// Splits a message into what it says and the replies it offers.
({String text, List<String> replies}) parseReplies(String body) {
  final trimmed = body.trimRight();
  final m = _line.firstMatch(trimmed);
  if (m == null) {
    // Still being written: the half-open line is not shown either.
    final open = _partial.firstMatch(trimmed);
    return open == null
        ? (text: body, replies: const <String>[])
        : (
            text: trimmed.substring(0, open.start).trimRight(),
            replies: const <String>[],
          );
  }
  final out = <String>[];
  for (var r in m.group(1)!.split('|')) {
    r = r.trim();
    if (r.isEmpty || out.length == maxReplies) continue;
    final runes = r.runes.toList();
    if (runes.length > maxReplyLength) {
      r = String.fromCharCodes(runes.take(maxReplyLength)).trim();
    }
    out.add(r);
  }
  return (text: trimmed.substring(0, m.start).trimRight(), replies: out);
}
