import 'package:aseman/src/core/settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists theme mode and accent in the local cache', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AppSettingsController();
    await first.restore();
    expect(first.themeMode, ThemeMode.system);
    expect(first.accent, AppSettingsController.defaultAccent);

    first.setThemeMode(ThemeMode.dark);
    first.setAccent(const Color(0xFF00BCD4));
    await first.flush();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppSettingsController.storageKey), isNotNull);

    final second = AppSettingsController();
    await second.restore();
    expect(second.themeMode, ThemeMode.dark);
    expect(second.accent.toARGB32(), const Color(0xFF00BCD4).toARGB32());
  });

  test('keeps defaults when the cached theme is unreadable', () async {
    SharedPreferences.setMockInitialValues({
      AppSettingsController.storageKey: '{not json',
    });
    final settings = AppSettingsController();
    await settings.restore();
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.accent, AppSettingsController.defaultAccent);
  });

  test('accepts a 6-digit accent and an unknown mode as a no-op', () async {
    SharedPreferences.setMockInitialValues({
      AppSettingsController.storageKey: '{"mode":"sepia","accent":"00bcd4"}',
    });
    final settings = AppSettingsController();
    await settings.restore();
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.accent.toARGB32(), const Color(0xFF00BCD4).toARGB32());
  });
}
