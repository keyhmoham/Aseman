import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/app_dependencies.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(TraderaApp(dependencies: AppDependencies.create()));
}
