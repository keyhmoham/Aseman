import 'dart:typed_data';

import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/uploaded_file.dart';
import 'package:aseman/src/features/assistant/home_assistant.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/attachment_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_aseman_service.dart';

/// A node with one approval waiting and one task that needs the person.
class _Node extends FakeAsemanService {
  final calls = <String>[];
  bool answered = false;

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
    bool anonymous = false,
  }) async {
    calls.add('$namespace.$action');
    switch ('$namespace.$action') {
      case 'proactive.tasks_list':
        return {
          'tasks': [
            {
              'id': 't1',
              'status': 'needs_input',
              'title': 'Reply to Priya',
              'summary': 'Which price list?',
            },
            {'id': 't2', 'status': 'working', 'title': 'Draft the newsletter'},
          ],
        };
      case 'proactive.brief_today':
        return {'brief': {}};
      case 'governance.approval_list':
        return {
          'approvals': answered
              ? []
              : [
                  {
                    'id': 'a1',
                    'summary': 'Send an email to Marco',
                    'agent_name': 'Ada',
                    'recipients': ['marco@example.com'],
                  },
                ],
        };
      case 'governance.approval_answer':
        answered = body['answer'] == 'once';
        return {
          'approval': {'status': 'approved'},
        };
    }
    return super.invokeAction(namespace, action, body: body, timeout: timeout, anonymous: anonymous);
  }
}

void main() {
  testWidgets(
    'the home feed shows what waits on the person, answered in place',
    (tester) async {
      final node = _Node();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HomeAssistant(
                dependencies: AppDependencies.withService(node),
              ),
            ),
          ),
        ),
      );
      // Working tasks breathe forever; settle with fixed pumps instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Your assistant'), findsOneWidget);
      expect(find.text('1 needs you'), findsOneWidget);
      expect(find.text('Send an email to Marco'), findsOneWidget);
      expect(find.text('Reply to Priya'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('Setup'), findsNothing);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(node.calls, contains('governance.approval_answer'));
      expect(find.text('Send an email to Marco'), findsNothing);
    },
  );

  testWidgets(
    'an attached project folder shows where it is and how it is shared',
    (tester) async {
      final folder = UploadedFile.fromJson({
        'id': 'folder:1',
        'kind': 'folder',
        'name': 'invoices',
        'mime': 'inode/directory',
        'project': 'Shop',
        'path': '/workspace/invoices',
        'access': 'read',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentBubble(
              file: folder,
              mine: true,
              headers: const {},
              fetchBytes: (_) async => Uint8List(0),
            ),
          ),
        ),
      );
      expect(find.text('invoices'), findsOneWidget);
      expect(
        find.text('Shop · /workspace/invoices · read only'),
        findsOneWidget,
      );
    },
  );
}
