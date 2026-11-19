import 'package:aseman/src/features/voice/live/live_voice_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sentenceEnd', () {
    test('waits for a sentence to be complete', () {
      expect(sentenceEnd('Hello there', 0, false), -1);
      // A stop at the very end may be mid-number or mid-link: wait for more.
      expect(sentenceEnd('It is 3.', 0, false), -1);
      expect(sentenceEnd('It is done. And', 0, false), 'It is done. '.length);
      expect(sentenceEnd('It is done.', 0, true), 'It is done.'.length);
    });

    test('speaks what is left once the answer is final', () {
      expect(sentenceEnd('no stop here', 0, true), 'no stop here'.length);
      expect(sentenceEnd('   ', 0, true), -1);
    });

    test('an eager first piece starts at a comma or after a few words', () {
      expect(sentenceEnd('Well, that depends on what you mean', 0, false), -1);
      // A comma too early in the piece is not worth starting on.
      expect(sentenceEnd('Sure, here is what I found', 0, false, eager: true), -1);
      expect(
        sentenceEnd('I have looked at that, and found', 0, false, eager: true),
        'I have looked at that, '.length,
      );
      const long = 'one two three four five six seven eight nine ten eleven twelve';
      final end = sentenceEnd(long, 0, false, eager: true);
      expect(end, greaterThan(25));
      expect(long[end - 1], ' ');
    });

    test('a long run with no stop is cut at a space', () {
      final text = List.filled(60, 'word').join(' ');
      final end = sentenceEnd(text, 0, false);
      expect(end, greaterThan(40));
      expect(end, lessThanOrEqualTo(161));
    });

    test('reads Persian sentence ends and works from an offset', () {
      expect(sentenceEnd('سلام؟ خوبی', 0, false), 'سلام؟ '.length);
      expect(sentenceEnd('One. Two. Three', 5, false), 'One. Two. '.length);
    });
  });

  test('spokenText leaves out markup, links and symbols', () {
    expect(spokenText('**Done** — see [the docs](https://x.y/z) now.'),
        'Done — see the docs now.');
    expect(spokenText('Run `ls -la` first'), 'Run ls -la first');
    expect(spokenText('Before\n```\nrm -rf /\n```\nafter'), 'Before after');
    expect(spokenText('- one\n- two ✓'), 'one two');
    expect(spokenText('See https://example.com/a?b=c ok'), 'See ok');
  });

  test('a bare yes or no is never taken as a confirmation', () {
    for (final said in ['yes', 'Yes.', 'okay!', 'go ahead', 'No', "don't", 'بله']) {
      expect(isBareYesNo(said), isTrue, reason: said);
    }
    for (final said in ['yes please send it to Sam', 'what is yes', 'hello']) {
      expect(isBareYesNo(said), isFalse, reason: said);
    }
  });

  test('worthSending needs a couple of real characters', () {
    expect(worthSending(''), isFalse);
    expect(worthSending('  . '), isFalse);
    expect(worthSending('a'), isFalse);
    expect(worthSending('hi'), isTrue);
    expect(worthSending('سلام'), isTrue);
  });

  group('parseLiveSnapshot', () {
    const me = 'me';

    Map<String, dynamic> thread(List<Map<String, dynamic>> messages,
            [List<Map<String, dynamic>> working = const []]) =>
        {'messages': messages, 'agents_working': working};

    test('is empty until an answer begins', () {
      final s = parseLiveSnapshot(
        thread([
          {'id': 'n1', 'from_id': me, 'body': 'hi'},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.answer, isNull);
      expect(s.proposal, isNull);
    });

    test('shows what is being written, but not a note still being decided on',
        () {
      final working = parseLiveSnapshot(
        thread(const [], [
          {'message_id': 'n1', 'text': 'Let me'},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(working.answer?.text, 'Let me');
      expect(working.answer?.done, isFalse);

      final deciding = parseLiveSnapshot(
        thread(const [], [
          {'message_id': 'n1', 'deciding': true},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(deciding.answer, isNull);
    });

    test("takes your Decillion's answer in your own notes", () {
      final s = parseLiveSnapshot(
        thread([
          {'id': 'a1', 'from_id': me, 'agent_id': 'bot', 'reply_to': 'n1', 'body': 'Done.'},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.answer?.text, 'Done.');
      expect(s.answer?.done, isTrue);
    });

    test("takes an agent's reply in a direct chat, not your own message", () {
      final s = parseLiveSnapshot(
        thread([
          {'id': 'x', 'from_id': me, 'reply_to': 'n1', 'body': 'a follow-up'},
          {'id': 'a1', 'from_id': 'agent', 'reply_to': 'n1', 'body': 'On it.'},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.answer?.text, 'On it.');
    });

    test("does not read out an agent's working notes", () {
      final s = parseLiveSnapshot(
        thread([
          {'id': 'l1', 'from_id': 'agent', 'reply_to': 'n1', 'kind': 'log', 'body': 'ran ls'},
          {'id': 'a1', 'from_id': 'agent', 'reply_to': 'n1', 'body': 'All done.'},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.answer?.text, 'All done.');
    });

    test('ignores an answer that was taken back', () {
      final s = parseLiveSnapshot(
        thread([
          {'id': 'a1', 'from_id': 'agent', 'reply_to': 'n1', 'deleted': true},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.answer, isNull);
    });

    test('acknowledges a note that was only kept', () {
      final s = parseLiveSnapshot(
        thread([
          {'id': 'n1', 'from_id': me, 'brain': 'saved'},
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.answer?.text, 'Noted.');
      expect(s.answer?.done, isTrue);
    });

    test('finds what the latest answer proposes and waits on', () {
      final s = parseLiveSnapshot(
        thread([
          {
            'id': 'a1',
            'from_id': me,
            'agent_id': 'bot',
            'reply_to': 'n1',
            'body': 'Shall I?',
            'proposal': {'status': 'pending', 'steps': ['Send the email', 'Archive it']},
          },
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.proposal?.id, 'a1');
      expect(s.proposal?.steps, ['Send the email', 'Archive it']);
    });

    test('a proposal already settled is not offered again', () {
      final s = parseLiveSnapshot(
        thread([
          {
            'id': 'a1',
            'from_id': me,
            'agent_id': 'bot',
            'reply_to': 'n1',
            'body': 'Done.',
            'proposal': {'status': 'approved', 'steps': ['x']},
          },
        ]),
        noteId: 'n1',
        me: me,
      );
      expect(s.proposal, isNull);
    });
  });
}
