import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/deferred/deferred_loader.dart';
import 'workspace_screen.dart' deferred as workspace;

/// The way into the workspace library from the feed and the shell: the
/// workspace desk, its tools and Elpian stack stay off the initial bundle
/// until someone opens a space, Explore or a profile. Every entry goes
/// through one loader, so after the first the library opens at once.
final _workspace = DeferredLoader(() => workspace.loadLibrary());

/// Loads the workspace library (instant once loaded).
Future<void> loadWorkspace() async => _workspace.ensure();

/// Explore from the feed: a search across Aseman with no space scope.
Future<void> showExplore(
  BuildContext context,
  AppDependencies dependencies, {
  String query = '',
  ValueChanged<String>? onOpenSpace,
}) async {
  await _workspace.ensure();
  if (!context.mounted) return;
  return workspace.showExplore(
    context,
    dependencies,
    query: query,
    onOpenSpace: onOpenSpace,
  );
}

/// A person's profile, wherever a post names them.
Future<void> showAccountProfile(
  BuildContext context,
  AppDependencies dependencies, {
  required String accountId,
  String handle = '',
}) async {
  await _workspace.ensure();
  if (!context.mounted) return;
  workspace.showAccountProfile(
    context,
    dependencies,
    accountId: accountId,
    handle: handle,
  );
}

/// The workspace desk for [initialWorkspace]. Call [loadWorkspace] first.
Widget workspaceScreen({
  Key? key,
  required AppDependencies dependencies,
  required String initialWorkspace,
  String? initialRoom,
  String? initialRoomId,
  VoidCallback? onBackToFeed,
  ValueChanged<String>? onWorkspaceChanged,
}) => workspace.WorkspaceScreen(
  key: key,
  dependencies: dependencies,
  initialWorkspace: initialWorkspace,
  initialRoom: initialRoom,
  initialRoomId: initialRoomId,
  onBackToFeed: onBackToFeed,
  onWorkspaceChanged: onWorkspaceChanged,
);
