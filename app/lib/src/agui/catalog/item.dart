/// The scaffolding every Aseman catalog item is built on: a component's
/// props resolved reactively (bindings and calls at any depth), its
/// children (ids or a `{componentId, path}` template, in every container),
/// two-way binding, actions, and `accessibility` semantics.
library;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../runtime/actions.dart';
import '../runtime/dynamic_values.dart';

/// Keys a component holds that are structure, not data: never resolved.
const Set<String> structuralKeys = {
  'id', 'component', 'type', 'weight', 'accessibility', 'action', 'selection', //
  'children', 'child', 'checks',
};

/// One component of a surface, as its widget builder sees it.
class AgUiItem {
  AgUiItem(this.context);

  final CatalogItemContext context;

  /// The component's props as written (bindings unresolved).
  Map<String, Object?> get raw => (context.data as Map).cast<String, Object?>();

  String get id => context.id;
  DataContext get dataContext => context.dataContext;
  BuildContext get buildContext => context.buildContext;

  /// Builds the child component [id] (in [scope], default this one's).
  Widget child(Object? id, [DataContext? scope]) => id is String
      ? context.buildChild(id, scope ?? dataContext)
      : const SizedBox.shrink();

  /// The child ids of a ChildList spec (an id list; empty for a template).
  List<String> childIds(Object? spec) =>
      spec is List ? [for (final c in spec) '$c'] : const [];

  /// Builds a ChildList: explicit ids, or a template repeated for every item
  /// of the bound list (or map), each item in its own data scope. [layout]
  /// arranges them; [wrap] decorates each child (weights, sizing).
  Widget children(
    Object? spec,
    Widget Function(List<Widget> children) layout, {
    Widget Function(String componentId, Widget child)? wrap,
  }) {
    Widget one(String id, DataContext scope, Key? key) {
      final w = wrap == null
          ? child(id, scope)
          : wrap(id, child(id, scope));
      return key == null ? w : KeyedSubtree(key: key, child: w);
    }

    if (spec is List) {
      return layout([for (final id in childIds(spec)) one(id, dataContext, null)]);
    }
    if (spec is Map && spec['componentId'] is String && spec['path'] is String) {
      final template = spec['componentId'] as String;
      final path = spec['path'] as String;
      return Resolved(
        context: dataContext,
        value: {'path': path},
        builder: (context, items) {
          final keys = items is List
              ? [for (var i = 0; i < items.length; i++) '$i']
              : items is Map
                  ? [for (final k in items.keys) '$k']
                  : const <String>[];
          return layout([
            for (final k in keys)
              one(template, dataContext.nested(DataPath('$path/$k')),
                  ValueKey('$template@$k')),
          ]);
        },
      );
    }
    return layout(const []);
  }

  /// The data scope of item [key] of the list bound by [binding] (null when
  /// [binding] is not a binding): where row actions resolve their context.
  DataContext? itemScope(Object? binding, Object key) {
    if (!isBinding(binding)) return null;
    final path = (binding as Map)['path'] as String;
    return dataContext.nested(DataPath(path == '/' ? '/$key' : '$path/$key'));
  }

  /// Two-way binding: writes [value] where [binding] points.
  void write(Object? binding, Object? value) =>
      writeBinding(dataContext, binding, value);

  /// Fires an AG-UI Surface action (see [fireAction]).
  Future<void> fire(Object? action,
          {DataContext? scope, Map<String, Object?> extra = const {}}) =>
      fireAction(context, action, scope: scope, extra: extra);

  /// The type of child component [id] (null when it has not arrived).
  String? typeOf(String id) => context.getComponent(id)?.type;

  /// A prop of child component [id] as written.
  Object? propOf(String id, String prop) =>
      context.getComponent(id)?.properties[prop];
}

typedef AgUiBuilder = Widget Function(
    AgUiItem item, Map<String, dynamic> props);

/// A catalog item whose props (all but [raw] and [structuralKeys]) arrive
/// at [build] resolved and current.
CatalogItem asemanItem(
  String name, {
  required String description,
  Map<String, Schema> properties = const {},
  List<String> required = const [],
  Set<String> raw = const {},
  bool implicitlyFlexible = false,
  List<String> examples = const [],
  required AgUiBuilder build,
}) =>
    CatalogItem(
      name: name,
      dataSchema: S.object(
        description: description,
        properties: {
          ...properties,
          'accessibility': S.object(
              description: 'Assistive-technology text: {label, description}.',
              additionalProperties: true),
          'weight': S.number(
              description: 'Share of the space in a Row or Column.'),
        },
        required: required,
      ),
      isImplicitlyFlexible: implicitlyFlexible,
      exampleData: [for (final e in examples) () => e],
      widgetBuilder: (context) {
        final item = AgUiItem(context);
        final data = item.raw;
        final dynamicProps = <String, Object?>{
          for (final e in data.entries)
            if (!structuralKeys.contains(e.key) && !raw.contains(e.key))
              e.key: e.value,
          if (data['accessibility'] != null)
            '\$a11y': data['accessibility'],
        };
        return Resolved(
          context: context.dataContext,
          value: dynamicProps,
          builder: (_, resolved) {
            final props = Map<String, dynamic>.of(
                resolved is Map ? resolved.cast<String, dynamic>() : const {});
            final a11y = props.remove('\$a11y');
            Widget out = build(item, props);
            if (a11y is Map) {
              final label = a11y['label'];
              final hint = a11y['description'];
              if (label is String && label.isNotEmpty ||
                  hint is String && hint.isNotEmpty) {
                out = Semantics(
                  label: label is String && label.isNotEmpty ? label : null,
                  hint: hint is String && hint.isNotEmpty ? hint : null,
                  child: out,
                );
              }
            }
            return out;
          },
        );
      },
    );

// ---------------------------------------------------------------------------
// Schemas: the props are described for agents and checked loosely (any
// value may be a binding or a function call).
// ---------------------------------------------------------------------------

abstract final class P {
  /// A value of any kind, or a binding / call producing it.
  static Schema any(String description) => S.any(description: description);

  static Schema str(String description, [List<String>? values]) =>
      values == null
          ? S.any(description: description)
          : S.string(description: description, enumValues: values);

  static Schema child([String description = 'The id of a child component.']) =>
      A2uiSchemas.componentReference(description: description);

  static Schema children([String? description]) =>
      A2uiSchemas.componentArrayReference(
          description: description ??
              'Child component ids, or {componentId, path} to repeat a '
                  'template for every item of a bound list.');

  static Schema action([String? description]) => S.object(
      description: description ??
          'What a tap does: {event: {name, context}} goes to the backend; '
              '{functionCall: {call, args}} runs on the device.',
      additionalProperties: true);

  static Schema checks() => A2uiSchemas.checkable();

  static Schema selection() => S.object(
      description: 'A {"path"} binding the tapped item is written to.',
      additionalProperties: true);
}
