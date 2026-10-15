/// An A2UI surface as a compact phone-board tile: its `compact` component
/// when the surface brings one (the agent's own summary, rendered with the
/// same data model and catalog as the full surface), else a summary derived
/// from its components — the first Quote, Stat, Gauge or Progress, a chart's
/// trend, its heading.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../runtime/dynamic_values.dart';
import '../runtime/presentation.dart';
import '../runtime/surfaces.dart';
import 'compact_summary.dart';
import 'surface_view.dart';

/// The id of the component a surface shows as its compact widget.
const String compactRootId = 'compact';

/// Renders component [rootId] of a surface as a root — what genui's
/// `Surface` does for `root`.
class GenUiComponentView extends StatelessWidget {
  const GenUiComponentView({
    super.key,
    required this.surfaces,
    required this.surfaceId,
    required this.rootId,
    this.onAction,
  });

  final GenUiSurfaces surfaces;
  final String surfaceId;
  final String rootId;
  final void Function(GenUiAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final surface = surfaces.contextFor(surfaceId);
    return ValueListenableBuilder<SurfaceDefinition?>(
      valueListenable: surface.definition,
      builder: (context, definition, _) {
        final catalog = surface.catalog;
        if (definition == null ||
            catalog == null ||
            !definition.components.containsKey(rootId)) {
          return const SizedBox.shrink();
        }
        final root = DataContext(
          surface.dataModel,
          DataPath.root,
          functions: catalog.functions,
        );
        void dispatch(UiEvent event) {
          if (!event.isUserAction) return;
          onAction?.call(
            GenUiAction.fromEvent(
              UserActionEvent.fromMap(event.toMap()),
              surfaceId,
            ),
          );
        }

        Widget build(String id, DataContext data, int depth) {
          final component = definition.components[id];
          if (component == null || depth > 64) return const SizedBox.shrink();
          try {
            return catalog.buildWidget(
              CatalogItemContext(
                id: id,
                data: component.properties,
                type: component.type,
                buildChild: (childId, [childData]) =>
                    build(childId, childData ?? data, depth + 1),
                dispatchEvent: dispatch,
                buildContext: context,
                dataContext: data,
                getComponent: (id) => definition.components[id],
                getCatalogItem: (type) =>
                    catalog.items.firstWhereOrNull((i) => i.name == type),
                surfaceId: surfaceId,
                reportError: surface.reportError,
              ),
            );
          } catch (e, stack) {
            surface.reportError(e, stack);
            return FallbackWidget(error: e, stackTrace: stack);
          }
        }

        return build(rootId, root, 0);
      },
    );
  }
}

/// A surface in its compact form (see the library comment).
class GenUiCompactView extends StatelessWidget {
  const GenUiCompactView({
    super.key,
    required this.surfaces,
    required this.surfaceId,
    this.onAction,
  });

  final GenUiSurfaces surfaces;
  final String surfaceId;
  final void Function(GenUiAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final surface = surfaces.contextFor(surfaceId);
    return ValueListenableBuilder<SurfaceDefinition?>(
      valueListenable: surface.definition,
      builder: (context, definition, _) {
        if (definition == null) return const SizedBox.shrink();
        final hint = CompactHint.fromJson(definition.theme);
        if (!hint.isEmpty) {
          final report = FrontendPresentation.maybeOf(context)?.onHint;
          if (report != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => report(hint));
          }
        }
        if (definition.components.containsKey(compactRootId)) {
          return GenUiComponentView(
            surfaces: surfaces,
            surfaceId: surfaceId,
            rootId: compactRootId,
            onAction: onAction,
          );
        }
        final spec = deriveCompactSpec(definition);
        final catalog = surface.catalog;
        return Resolved(
          context: DataContext(
            surface.dataModel,
            DataPath.root,
            functions: catalog?.functions ?? const [],
          ),
          value: spec,
          builder: (context, resolved) =>
              CompactSummaryView(summary: CompactSummary.fromJson(resolved)),
        );
      },
    );
  }
}

/// A compact summary spec of a surface, its values as the components hold
/// them (literals, bindings, calls — resolved where it is shown). Walks the
/// components from `root` in order, through explicit children only (a
/// template's components stand in an item's scope).
Map<String, Object?> deriveCompactSpec(SurfaceDefinition definition) {
  final components = definition.components;
  final order = <Component>[];
  final seen = <String>{};
  void walk(String id, int depth) {
    final c = components[id];
    if (c == null || depth > 64 || !seen.add(id)) return;
    order.add(c);
    final p = c.properties;
    for (final key in ['child', 'trigger', 'fallback']) {
      if (p[key] is String) walk(p[key] as String, depth + 1);
    }
    if (p['children'] is List) {
      for (final child in p['children'] as List) {
        if (child is String) walk(child, depth + 1);
      }
    }
    for (final listKey in ['tabs', 'items']) {
      if (p[listKey] is List) {
        for (final t in p[listKey] as List) {
          if (t is Map && t['child'] is String) {
            walk(t['child'] as String, depth + 1);
          }
        }
      }
    }
  }

  walk('root', 0);
  Component? first(Set<String> types) =>
      order.firstWhereOrNull((c) => types.contains(c.type));
  final spec = <String, Object?>{};
  final metrics = <Map<String, Object?>>[];

  final quote = first({'Quote'});
  final stats = order.where((c) => c.type == 'Stat').toList();
  final gauge = first({'Gauge', 'Progress'});
  final chart = order.firstWhereOrNull(
    (c) =>
        (c.type == 'Chart' &&
            !const {
              'pie',
              'donut',
              'radar',
              'heatmap',
              'treemap',
            }.contains(c.properties['type'])) ||
        c.type == 'Sparkline',
  );
  if (quote != null) {
    final p = quote.properties;
    spec
      ..['title'] = p['name'] ?? p['symbol']
      ..['value'] = p['price']
      ..['format'] = p['format'] ??
          (p['currency'] is String ? 'currency:${p['currency']}' : null)
      ..['delta'] = p['change']
      ..['deltaFormat'] = '+percent:2'
      ..['trend'] = p['trend'];
  } else if (stats.isNotEmpty) {
    final p = stats.first.properties;
    spec
      ..['title'] = p['label']
      ..['value'] = p['value']
      ..['format'] = p['format']
      ..['delta'] = p['delta']
      ..['deltaFormat'] = p['deltaFormat']
      ..['deltaLabel'] = p['deltaLabel']
      ..['goodDirection'] = p['goodDirection']
      ..['trend'] = p['trend']
      ..['icon'] = p['icon']
      ..['status'] = p['status'];
  } else if (gauge != null) {
    final p = gauge.properties;
    spec
      ..['title'] = p['label']
      ..['value'] = p['value']
      ..['format'] = p['format']
      ..['progress'] = {
        'value': p['value'],
        'min': p['min'] ?? 0,
        'max': p['max'] ?? (gauge.type == 'Gauge' ? 100 : 1),
      };
  }
  for (final s in stats.skip(quote == null ? 1 : 0).take(4)) {
    final p = s.properties;
    metrics.add({
      'label': p['label'],
      'value': p['value'],
      'format': p['format'],
      'delta': p['delta'],
      'deltaFormat': p['deltaFormat'],
    });
  }
  if (spec['trend'] == null && chart != null) {
    final p = chart.properties;
    if (chart.type == 'Sparkline') {
      spec['trend'] = p['values'] ?? {'rows': p['data'], 'field': p['field']};
    } else {
      final series = p['series'];
      final field = p['y'] ??
          (series is List && series.isNotEmpty
              ? (series.first is Map
                  ? (series.first as Map)['field']
                  : series.first)
              : null) ??
          (p['type'] == 'candlestick' ? (p['close'] ?? 'close') : null);
      spec['trend'] = {'rows': p['data'], 'field': field};
    }
    spec['title'] ??= p['title'];
  }
  // A heading names it; the first body text says what it is.
  final heading = order.firstWhereOrNull(
    (c) =>
        c.type == 'Text' &&
        const {'h1', 'h2', 'h3', 'h4', 'h5'}.contains(c.properties['variant']),
  );
  spec['title'] ??= heading?.properties['text'];
  final hasValue = spec['value'] != null || metrics.isNotEmpty;
  if (!hasValue) {
    final text = order.firstWhereOrNull(
      (c) =>
          c.type == 'Text' &&
          c != heading &&
          !const {
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
          }.contains(c.properties['variant']),
    );
    spec['caption'] = text?.properties['text'];
    final badge = first({'Badge'});
    if (badge != null) spec['badge'] = badge.properties['text'];
  }
  if (metrics.isNotEmpty) spec['metrics'] = metrics;
  spec.removeWhere((_, v) => v == null);
  return spec;
}
