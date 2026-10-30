import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/app_dependencies.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The app draws its own menus. On the web, keep the browser's right-click
  // menu from opening over any of it.
  if (kIsWeb) {
    unawaited(BrowserContextMenu.disableContextMenu());
  }
  runApp(AsemanApp(dependencies: AppDependencies.create()));
}
