import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/navigation/domain/app_destination.dart';
import 'package:tradera/src/features/navigation/presentation/navigation_view_model.dart';

void main() {
  test('changes the selected destination and notifies listeners', () {
    final model = NavigationViewModel();
    var notifications = 0;
    model.addListener(() => notifications++);

    model.select(AppDestination.wallet);

    expect(model.selected, AppDestination.wallet);
    expect(notifications, 1);
  });
}
