import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/features/gadgets/presentation/gadgets_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_aseman_service.dart';

void main() {
  test('the newest surface decides the space; closing it hands it back', () {
    final controller = GadgetsController(
      AppDependencies.withService(FakeAsemanService()),
    );
    addTearDown(controller.dispose);

    final workspace = controller.lease('atlas');
    expect(controller.spaceId, 'atlas');
    final chat = controller.lease('direct');
    expect(controller.spaceId, 'direct');

    // The chat over the workspace closes: the workspace has it back.
    chat.release();
    expect(controller.spaceId, 'atlas');
    chat.release(); // once only
    expect(controller.spaceId, 'atlas');

    workspace.release();
    expect(controller.spaceId, '');
  });

  test('releasing a surface under the current one changes nothing', () {
    final controller = GadgetsController(
      AppDependencies.withService(FakeAsemanService()),
    );
    addTearDown(controller.dispose);
    final under = controller.lease('atlas');
    controller.lease('direct');
    under.release();
    expect(controller.spaceId, 'direct');
  });
}
