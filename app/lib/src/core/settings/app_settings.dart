import 'package:flutter/material.dart';

class AppSettingsController extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  Color accent = const Color(0xFF8B7BFF);

  void setThemeMode(ThemeMode value) {
    if (themeMode == value) return;
    themeMode = value;
    notifyListeners();
  }

  void setAccent(Color value) {
    if (accent == value) return;
    accent = value;
    notifyListeners();
  }
}

class AppSettingsScope extends InheritedNotifier<AppSettingsController> {
  const AppSettingsScope(
      {super.key,
      required AppSettingsController controller,
      required super.child})
      : super(notifier: controller);

  static AppSettingsController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    assert(scope != null, 'No AppSettingsScope found');
    return scope!.notifier!;
  }
}
