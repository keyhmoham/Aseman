/// The tappable answers an agent offers at the end of a message: a last line
/// `<replies>first | second | third</replies>`. The line itself is not shown;
/// the latest agent message shows them as chips (as the node's Slack and
/// Teams channels show buttons).
library;

/// How many replies are shown, and how long each may be.
const maxReplies = 3;
const maxReplyLength = 40;

final _line = RegExp(r'\n?[ \t]*<replies>([\s\S]*?)</replies>[ \t]*$');

/// Splits a message into what it says and the replies it offers.
({String text, List<String> replies}) parseReplies(String body) {
  final trimmed = body.trimRight();
  final m = _line.firstMatch(trimmed);
  if (m == null) return (text: body, replies: const []);
  final out = <String>[];
  for (var r in m.group(1)!.split('|')) {
    r = r.trim();
    if (r.isEmpty || out.length == maxReplies) continue;
    final runes = r.runes.toList();
    if (runes.length > maxReplyLength) {
      r = String.fromCharCodes(runes.take(maxReplyLength));
    }
    out.add(r);
  }
  return (text: trimmed.substring(0, m.start).trimRight(), replies: out);
}
