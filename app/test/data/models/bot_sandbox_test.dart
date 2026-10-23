import 'package:aseman/src/data/models/bot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Bot bot({
    required String name,
    String kind = 'tool',
    String vmType = 'container',
  }) =>
      Bot(
        id: '1',
        ownerId: 'o',
        accountId: 'a',
        name: name,
        kind: kind,
        vmType: vmType,
        status: 'running',
      );

  test('space sandboxes are not apps', () {
    expect(bot(name: 'sbx-space1').isSandbox, isTrue);
    expect(bot(name: 'sbx-space1', vmType: 'modal').isSandbox, isTrue);
    expect(bot(name: 'sbx-space1', vmType: 'docker').isSandbox, isTrue);
    expect(bot(name: 'Weather').isSandbox, isFalse);
    expect(bot(name: 'sbx-space1', kind: 'agent').isSandbox, isFalse);
    expect(bot(name: 'sbx-space1', vmType: 'mcp').isSandbox, isFalse);
  });

  test('unified tools exclude sandboxes', () {
    expect(bot(name: 'Notes', vmType: 'mcp').isUnifiedTool, isTrue);
    expect(bot(name: 'sbx-space1', vmType: 'docker').isUnifiedTool, isFalse);
  });
}
