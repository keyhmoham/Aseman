import 'package:aseman/src/features/brain/brain_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BrainAvatarPrefs.viewerId = '';
    BrainAvatarPrefs.clearLive();
  });

  test('save publishes live snapshot and bumps revision', () async {
    final before = BrainAvatarPrefs.revision.value;
    const prefs = BrainAvatarPrefs(
      skin: 4,
      hair: 2,
      agentId: 'bot-1',
      userId: 'user-1',
    );
    await prefs.save();

    expect(BrainAvatarPrefs.revision.value, before + 1);
    expect(BrainAvatarPrefs.liveFor('bot-1', 'user-1')?.skin, 4);
    expect(BrainAvatarPrefs.liveFor('bot-1', 'user-1')?.hair, 2);
  });

  test('load prefers live snapshot over disk', () async {
    SharedPreferences.setMockInitialValues({
      'aseman.agent.bot-1.by.user-1.avatar.skin': 1,
      'aseman.agent.bot-1.by.user-1.avatar.hair': 0,
    });
    await const BrainAvatarPrefs(
      skin: 5,
      hair: 3,
      agentId: 'bot-1',
      userId: 'user-1',
    ).save();

    final loaded = await BrainAvatarPrefs.load(
      agentId: 'bot-1',
      userId: 'user-1',
    );
    expect(loaded.skin, 5);
    expect(loaded.hair, 3);
  });

  test('resolveUserId falls back to viewerId', () {
    BrainAvatarPrefs.viewerId = 'viewer-9';
    expect(BrainAvatarPrefs.resolveUserId(''), 'viewer-9');
    expect(BrainAvatarPrefs.resolveUserId('explicit'), 'explicit');
  });

  testWidgets('AgentHumanoidAvatar refreshes when prefs save elsewhere',
      (tester) async {
    var heard = 0;
    void onRev() => heard++;
    BrainAvatarPrefs.revision.addListener(onRev);
    addTearDown(() => BrainAvatarPrefs.revision.removeListener(onRev));

    BrainAvatarPrefs.viewerId = 'user-1';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentHumanoidAvatar(
            agentId: 'bot-1',
            userId: 'user-1',
            radius: 20,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = heard;
    await const BrainAvatarPrefs(
      skin: 5,
      hair: 4,
      agentId: 'bot-1',
      userId: 'user-1',
    ).save();
    await tester.pumpAndSettle();

    expect(heard, greaterThan(before));
    expect(BrainAvatarPrefs.liveFor('bot-1', 'user-1')?.skin, 5);
    expect(find.byType(AgentHumanoidAvatar), findsOneWidget);
  });
}
