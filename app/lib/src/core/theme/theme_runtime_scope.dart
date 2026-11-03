import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../data/services/aseman_service.dart';

/// Provides [AppDependencies] / [AsemanService] to theme Elpian panels so
/// pack-declared UI islands can call the signed-in person's core API.
class ThemeRuntimeScope extends InheritedWidget {
  const ThemeRuntimeScope({
    super.key,
    required this.dependencies,
    required super.child,
  });

  final AppDependencies dependencies;

  AsemanService get service => dependencies.service;

  static ThemeRuntimeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeRuntimeScope>();

  static ThemeRuntimeScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'ThemeRuntimeScope missing above theme panels');
    return scope!;
  }

  static AsemanService? serviceOf(BuildContext context) =>
      maybeOf(context)?.service;

  static AppDependencies? dependenciesOf(BuildContext context) =>
      maybeOf(context)?.dependencies;

  @override
  bool updateShouldNotify(ThemeRuntimeScope oldWidget) =>
      oldWidget.dependencies != dependencies;
}
