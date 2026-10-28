import 'package:aseman/src/agui/replies.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the last line offers replies, and is not shown', () {
    final r = parseReplies('Want me to draft it?\n<replies>Yes | Not now | Change the tone of it, please and thank you</replies>\n');
    expect(r.text, 'Want me to draft it?');
    expect(r.replies, ['Yes', 'Not now', 'Change the tone of it, please and thank']);
  });

  test('at most three, and only on the last line', () {
    expect(parseReplies('<replies>a|b|c|d</replies>').replies, ['a', 'b', 'c']);
    final inline = parseReplies('Use <replies>a</replies> like this.');
    expect(inline.replies, isEmpty);
    expect(inline.text, 'Use <replies>a</replies> like this.');
  });
}
