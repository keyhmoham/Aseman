import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import 'workspace_screen.dart' deferred as workspace;

/// Feed-side entry to Explore that keeps the workspace desk library off the
/// initial search-feed bundle until the user opens Explore.
Future<void> showExplore(
  BuildContext context,
  AppDependencies dependencies, {
  String query = '',
  ValueChanged<String>? onOpenSpace,
}) async {
  await workspace.loadLibrary();
  return workspace.showExplore(
    context,
    dependencies,
    query: query,
    onOpenSpace: onOpenSpace,
  );
}
