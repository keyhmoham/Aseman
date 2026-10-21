import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/data/services/backend_capabilities.dart';

/// The admin console sends its calls through AsemanService.invokeAction,
/// which refuses any action missing from the client contract before it
/// reaches the node. Every action the console names must be listed.
void main() {
  test('every admin console action is in the client contract', () {
    final dir = Directory('lib/src/features/admin');
    final call = RegExp(r"""_Call\(\s*'(\w+)',\s*'(\w+)'""");
    final invoke = RegExp(r"""invokeAction\(\s*'(\w+)',\s*'(\w+)'""");
    final calls = <String>{};
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final m in [
        ...call.allMatches(source),
        ...invoke.allMatches(source)
      ]) {
        calls.add('${m[1]}.${m[2]}');
      }
    }
    expect(calls, contains('spaces.admins_space_get'));
    final missing = calls.where((c) {
      final [namespace, action] = c.split('.');
      return !BackendCapabilities.contains(namespace, action);
    }).toList();
    expect(missing, isEmpty, reason: 'not in BackendCapabilities.actions');
  });
}
