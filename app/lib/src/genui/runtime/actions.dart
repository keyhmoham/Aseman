/// A2UI actions fired by Aseman's components.
///
/// An action is either `{"event": {"name", "context"}}` — sent to whoever
/// hosts the surface (a tool's backend, an agent), its context resolved in
/// the data scope the component stands in (a tapped table row's scope for a
/// row action) — or `{"functionCall": {"call", "args"}}`, run on the device
/// (`setValue`, `toggle`, `openUrl`, `showToast`…; `closeModal` closes the
/// dialog it stands in).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'dynamic_values.dart';

/// Fires [action] for the component of [item]. [scope] overrides the data
/// scope its context resolves in; [extra] is merged into the event context
/// (what an input carries, e.g. the submitted text).
Future<void> fireAction(
  CatalogItemContext item,
  Object? action, {
  DataContext? scope,
  Map<String, Object?> extra = const {},
}) async {
  if (action is! Map) return;
  final context = scope ?? item.dataContext;
  // `{"event": {…}}`, or v1.0's shorthand `{"name", "context"}`.
  final event = action['event'] is Map
      ? action['event'] as Map
      : action['name'] is String && action['functionCall'] == null
          ? action
          : null;
  if (event != null) {
    final name = event['name'];
    if (name is! String || name.isEmpty) return;
    final definition = event['context'];
    final resolved = <String, Object?>{};
    if (definition is Map) {
      for (final e in definition.entries) {
        resolved['${e.key}'] = await resolveOnce(context, e.value);
      }
    }
    final userMessage = event['userMessage'];
    item.dispatchEvent(UserActionEvent.fromMap({
      'name': name,
      'sourceComponentId': item.id,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'context': {...resolved, ...extra},
      if (userMessage is String) 'userMessage': userMessage,
    }));
    return;
  }
  final call = action['functionCall'];
  if (call is Map && call['call'] is String) {
    await runFunctionCall(item, call.cast<String, Object?>(), scope: context);
  }
}

/// Runs a client-side function call (an action's `functionCall`).
Future<void> runFunctionCall(
  CatalogItemContext item,
  Map<String, Object?> call, {
  DataContext? scope,
}) async {
  final name = call['call'] as String;
  if (name == 'closeModal') {
    final navigator = Navigator.maybeOf(item.buildContext);
    if (navigator != null && navigator.canPop()) navigator.pop();
    return;
  }
  final context = scope ?? item.dataContext;
  if (name == 'showToast') {
    final args = call['args'];
    final message = await context
        .resolve(args is Map ? args['message'] : null)
        .first
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    final messenger = item.buildContext.mounted
        ? ScaffoldMessenger.maybeOf(item.buildContext)
        : null;
    messenger?.showSnackBar(
        SnackBar(content: Text(message == null ? '' : '$message')));
    return;
  }
  final iterator = StreamIterator<Object?>(context.resolve({
    'call': name,
    'args': call['args'] ?? const <String, Object?>{},
  }));
  try {
    await iterator.moveNext().timeout(const Duration(seconds: 10));
  } catch (e, stack) {
    item.reportError(
        A2uiFunctionException('Function "$name" failed: $e',
            functionName: name, cause: e),
        stack);
  } finally {
    await iterator.cancel();
  }
}

/// [value] with every binding and call in it evaluated once (literal maps
/// that merely have a "path" or "call" key stay literal).
Future<Object?> resolveOnce(DataContext context, Object? value) async {
  if (!containsDynamic(value)) return value;
  final done = Completer<Object?>();
  late DynamicResolver resolver;
  var pending = true;
  resolver = DynamicResolver(context, value, () {
    if (pending && !_hasPendingCall(resolver)) {
      pending = false;
      done.complete(resolver.value);
    }
  });
  if (!_hasPendingCall(resolver)) {
    pending = false;
    done.complete(resolver.value);
  }
  try {
    return await done.future
        .timeout(const Duration(seconds: 5), onTimeout: () => resolver.value);
  } finally {
    resolver.dispose();
  }
}

bool _hasPendingCall(DynamicResolver r) => r.pendingCalls > 0;
