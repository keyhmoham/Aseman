/// Dynamic values of AG-UI Surface components, resolved reactively against a agui
/// [DataContext]: a `{"path"}` binding reads the data model, a
/// `{"call", "args"}` function call runs, and either may stand at any depth
/// of a literal map or list (a Chart's `series`, a Table's `columns`, an
/// Elpian node's props). The resolved value updates whenever a binding's
/// data or a function's result changes.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:genui/genui.dart';

/// `{"path": "…"}` and nothing else (a data row may hold a `path` field).
bool isBinding(Object? v) =>
    v is Map && v['path'] is String && v.keys.every((k) => k == 'path');

/// `{"call": "…", "args"?: {…}, "returnType"?: "…"}`.
bool isFunctionCall(Object? v) =>
    v is Map &&
    v['call'] is String &&
    v.keys.every((k) => k == 'call' || k == 'args' || k == 'returnType');

bool isDynamic(Object? v) => isBinding(v) || isFunctionCall(v);

/// Whether [v] holds a binding or call anywhere inside it.
bool containsDynamic(Object? v) {
  if (isDynamic(v)) return true;
  if (v is Map) return v.values.any(containsDynamic);
  if (v is List) return v.any(containsDynamic);
  return false;
}

/// The absolute data path a `{"path"}` binding points at in [context].
String? bindingPath(DataContext context, Object? binding) {
  if (!isBinding(binding)) return null;
  return context.resolvePath(DataPath((binding as Map)['path'] as String))
      .toString();
}

/// Writes [value] where [binding] points (no-op for literals).
void writeBinding(DataContext context, Object? binding, Object? value) {
  if (!isBinding(binding)) return;
  try {
    context.update(DataPath((binding as Map)['path'] as String), value);
  } catch (e) {
    debugPrint('AgUi: could not write $binding: $e');
  }
}

/// Reads a binding's current value once (null for anything else).
Object? readBinding(DataContext context, Object? binding) {
  if (!isBinding(binding)) return null;
  try {
    return context
        .getValue<Object?>(DataPath((binding as Map)['path'] as String));
  } catch (_) {
    return null;
  }
}

/// Resolves every binding and call inside a value tree and keeps the
/// result current, calling [onChange] when it changes.
///
/// Bindings resolve synchronously (their current data is known at once);
/// function calls report their first result as soon as it is produced.
class DynamicResolver {
  DynamicResolver(this.context, this.spec, this.onChange) {
    _value = _build(spec);
  }

  final DataContext context;
  final Object? spec;
  final VoidCallback onChange;

  final List<VoidCallback> _disposers = [];
  late Object? Function() _value;
  bool _disposed = false;

  /// Function calls that have not produced a value yet.
  int pendingCalls = 0;

  /// The value with every binding and call replaced by its current result.
  Object? get value => _value();

  Object? Function() _build(Object? v) {
    if (isBinding(v)) {
      final path = DataPath((v as Map)['path'] as String);
      final ValueListenable<Object?> notifier;
      try {
        notifier = context.subscribe<Object?>(path);
      } catch (e) {
        return () => null;
      }
      void listener() => _changed();
      notifier.addListener(listener);
      _disposers.add(() {
        notifier.removeListener(listener);
        if (notifier is ChangeNotifier) (notifier as ChangeNotifier).dispose();
      });
      return () => notifier.value;
    }
    if (isFunctionCall(v)) {
      Object? latest;
      var first = true;
      pendingCalls++;
      StreamSubscription<Object?>? sub;
      try {
        sub = context.resolve(v).listen((value) {
          latest = value;
          if (first) {
            first = false;
            pendingCalls--;
          }
          _changed();
        }, onError: (Object e) => debugPrint('AgUi: ${v?.toString()}: $e'));
      } catch (e) {
        debugPrint('AgUi: $v: $e');
      }
      _disposers.add(() => sub?.cancel());
      return () => latest;
    }
    if (v is Map && containsDynamic(v)) {
      final parts = <String, Object? Function()>{
        for (final e in v.entries) '${e.key}': _build(e.value),
      };
      return () => <String, dynamic>{
            for (final e in parts.entries) e.key: e.value(),
          };
    }
    if (v is List && containsDynamic(v)) {
      final parts = [for (final x in v) _build(x)];
      return () => [for (final p in parts) p()];
    }
    return () => v;
  }

  void _changed() {
    if (!_disposed) onChange();
  }

  void dispose() {
    _disposed = true;
    for (final d in _disposers) {
      d();
    }
    _disposers.clear();
  }
}

/// Builds [builder] with [value] resolved in [context] (see
/// [DynamicResolver]); rebuilds when anything it reads changes.
class Resolved extends StatefulWidget {
  const Resolved({
    super.key,
    required this.context,
    required this.value,
    required this.builder,
  });

  final DataContext context;
  final Object? value;
  final Widget Function(BuildContext context, Object? resolved) builder;

  @override
  State<Resolved> createState() => _ResolvedState();
}

class _ResolvedState extends State<Resolved> {
  DynamicResolver? _resolver;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  void _setUp() {
    _resolver?.dispose();
    _resolver = containsDynamic(widget.value)
        ? DynamicResolver(widget.context, widget.value, _onChange)
        : null;
  }

  void _onChange() {
    if (!mounted || _scheduled) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      _scheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(Resolved old) {
    super.didUpdateWidget(old);
    if (!sameContext(old.context, widget.context) ||
        !const DeepCollectionEquality().equals(old.value, widget.value)) {
      _setUp();
    }
  }

  @override
  void dispose() {
    _resolver?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(
      context, _resolver != null ? _resolver!.value : widget.value);
}

/// Data contexts are rebuilt on every frame; two stand for the same scope
/// when they share the data model and the path.
bool sameContext(DataContext a, DataContext b) =>
    identical(a, b) || (identical(a.dataModel, b.dataModel) && a.path == b.path);
