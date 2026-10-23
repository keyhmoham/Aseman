/// An AG-UI Surface surface as a compact phone-board widget: its `compact` component
/// when the surface brings one (the agent's own, rendered with the same data
/// model and catalog as the full surface), else a digest derived from all
/// its components and its data (see [deriveCompactSpec]).
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

/// Renders component [rootId] of a surface as a root — what agui's
/// `Surface` does for `root`.
class AgUiComponentView extends StatelessWidget {
  const AgUiComponentView({
    super.key,
    required this.surfaces,
    required this.surfaceId,
    required this.rootId,
    this.onAction,
  });

  final AgUiSurfaces surfaces;
  final String surfaceId;
  final String rootId;
  final void Function(AgUiAction action)? onAction;

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
            AgUiAction.fromEvent(
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
class AgUiCompactView extends StatelessWidget {
  const AgUiCompactView({
    super.key,
    required this.surfaces,
    required this.surfaceId,
    this.onAction,
  });

  final AgUiSurfaces surfaces;
  final String surfaceId;
  final void Function(AgUiAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final surface = surfaces.contextFor(surfaceId);
    return ValueListenableBuilder<SurfaceDefinition?>(
      valueListenable: surface.definition,
      builder: (context, definition, _) {
        if (definition == null) return const SizedBox.shrink();
        final report = FrontendPresentation.maybeOf(context)?.onHint;
        void hintOnce(CompactHint hint) {
          if (report == null || hint.isEmpty) return;
          WidgetsBinding.instance.addPostFrameCallback((_) => report(hint));
        }

        final hint = CompactHint.fromJson(definition.theme);
        hintOnce(hint);
        if (definition.components.containsKey(compactRootId)) {
          return AgUiComponentView(
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
          builder: (context, resolved) {
            final summary = CompactSummary.fromJson(resolved);
            // A digest with a chart and a list wants room: a large widget,
            // unless the surface or the person chose otherwise.
            if (hint.isEmpty && summary.richness >= 3) {
              hintOnce(const CompactHint(size: 'large'));
            }
            return CompactSummaryView(summary: summary);
          },
        );
      },
    );
  }
}

/// A compact digest spec of a surface (see [CompactSummary.fromJson]), its
/// values as the components hold them (literals, bindings, calls — resolved
/// where it is shown). Every kind of component contributes:
///
/// * the hero: the first Quote, Stat, Gauge, Progress or Trend;
/// * metrics: further Stats, KeyValue items, Ratings, Trends;
/// * the chart: the first Chart, Sparkline, AllocationBar or Treemap;
/// * the list: the first Table, Timeline, TickerTape, OrderBook, or a
///   template repeated over a list (List, Grid, Wrap, Carousel…), its fields
///   read from the template's components;
/// * chips: Badges; the image: the first Image; the title and caption:
///   headings and text;
/// * the data model, for what the components leave unsaid.
///
/// Components are walked from `root` in order; a template's components stand
/// in an item's scope, so they shape the list, not the hero.
Map<String, Object?> deriveCompactSpec(SurfaceDefinition definition) {
  final components = definition.components;
  final order = <Component>[];
  final templates = <(Component owner, String template, String path)>[];
  final seen = <String>{};
  void walk(String id, int depth) {
    final c = components[id];
    if (c == null || depth > 64 || !seen.add(id)) return;
    order.add(c);
    final p = c.properties;
    for (final key in ['child', 'trigger', 'fallback']) {
      if (p[key] is String) walk(p[key] as String, depth + 1);
    }
    final children = p['children'];
    if (children is List) {
      for (final child in children) {
        if (child is String) walk(child, depth + 1);
      }
    } else if (children is Map &&
        children['componentId'] is String &&
        children['path'] is String) {
      templates.add(
          (c, children['componentId'] as String, children['path'] as String));
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
  Iterable<Component> all(Set<String> types) =>
      order.where((c) => types.contains(c.type));
  Component? first(Set<String> types) => all(types).firstOrNull;

  final spec = <String, Object?>{'data': {'path': '/'}};
  final metrics = <Object?>[];

  // The hero.
  final quote = first({'Quote'});
  final stats = all({'Stat'}).toList();
  final gauge = first({'Gauge', 'Progress'});
  final trend = first({'Trend'});
  Component? heroOf;
  if (quote != null) {
    heroOf = quote;
    final p = quote.properties;
    spec['hero'] = {
      'label': p['symbol'] ?? p['name'],
      'value': p['price'],
      'format': p['format'] ??
          (p['currency'] is String ? 'currency:${p['currency']}' : null),
      'delta': p['change'],
      'deltaFormat': '+percent:2',
      'deltaLabel': p['name'],
      'trend': p['trend'],
    };
  } else if (stats.isNotEmpty) {
    heroOf = stats.first;
    final p = stats.first.properties;
    spec['hero'] = {
      'label': p['label'],
      'value': p['value'],
      'format': p['format'],
      'delta': p['delta'],
      'deltaFormat': p['deltaFormat'],
      'deltaLabel': p['deltaLabel'],
      'goodDirection': p['goodDirection'],
      'trend': p['trend'],
      'status': p['status'],
    };
    spec['icon'] = p['icon'];
  } else if (gauge != null) {
    heroOf = gauge;
    final p = gauge.properties;
    spec['hero'] = {
      'label': p['label'],
      'value': p['value'],
      'format': p['format'],
      'progress': {
        'value': p['value'],
        'min': p['min'] ?? 0,
        'max': p['max'] ?? (gauge.type == 'Gauge' ? 100 : 1),
      },
    };
  } else if (trend != null) {
    heroOf = trend;
    final p = trend.properties;
    spec['hero'] = {
      'label': p['label'],
      'value': p['value'],
      'format': p['format'] ?? '+percent:2',
    };
  }

  // Metrics.
  for (final s in stats) {
    if (s == heroOf || metrics.length >= 4) continue;
    final p = s.properties;
    metrics.add({
      'label': p['label'],
      'value': p['value'],
      'format': p['format'],
      'delta': p['delta'],
      'deltaFormat': p['deltaFormat'],
    });
  }
  for (final kv in all({'KeyValue'})) {
    final p = kv.properties;
    if (p['items'] is List) {
      for (final item in p['items'] as List) {
        if (item is Map && metrics.length < 6) {
          metrics.add({
            'label': item['label'],
            'value': item['value'],
            'format': item['format'],
          });
        }
      }
    } else if (p['data'] != null) {
      spec['kv'] ??= p['data'];
    }
  }
  for (final c in all({'Rating', 'Trend', 'Countdown'})) {
    if (c == heroOf || metrics.length >= 6) continue;
    final p = c.properties;
    metrics.add(switch (c.type) {
      'Rating' => {
          'label': p['label'] ?? 'Rating',
          'value': p['value'],
          'format': 'number:1',
        },
      'Trend' => {
          'label': p['label'] ?? 'Change',
          'value': p['value'],
          'format': p['format'] ?? '+percent:2',
        },
      _ => {'label': p['label'] ?? 'Ends', 'value': p['target'], 'format': 'datetime'},
    });
  }
  if (metrics.isNotEmpty) spec['metrics'] = metrics;

  // The chart.
  final chart = order.firstWhereOrNull((c) =>
      (c.type == 'Chart' &&
          !const {'heatmap', 'radar'}.contains(c.properties['type'])) ||
      const {'Sparkline', 'AllocationBar', 'Treemap'}.contains(c.type));
  if (chart != null) {
    final p = chart.properties;
    switch (chart.type) {
      case 'Sparkline':
        spec['chart'] = p['values'] != null
            ? {'kind': p['type'] == 'bar' ? 'bar' : 'area', 'values': p['values']}
            : {'kind': 'area', 'rows': p['data'], 'field': p['field']};
      case 'AllocationBar' || 'Treemap':
        spec['chart'] = {
          'kind': 'donut',
          'rows': p['data'],
          'field': p['value'] ?? 'value',
          'labelField': p['label'] ?? 'label',
        };
      default:
        final type = '${p['type'] ?? 'line'}';
        final series = p['series'];
        final field = type == 'pie' || type == 'donut'
            ? (p['value'] ?? 'value')
            : type == 'candlestick'
                ? (p['close'] ?? 'close')
                : p['y'] ??
                    (series is List && series.isNotEmpty
                        ? (series.first is Map
                            ? (series.first as Map)['field']
                            : series.first)
                        : null) ??
                    p['field'];
        spec['chart'] = {
          'kind': type,
          'rows': p['data'],
          'field': field,
          'labelField': type == 'pie' || type == 'donut'
              ? (p['label'] ?? 'label')
              : p['x'],
          'format': p['yFormat'] ?? p['format'],
        };
        spec['title'] ??= p['title'];
    }
  }

  // The list.
  final table = first({'Table', 'Timeline', 'TickerTape'});
  final book = first({'OrderBook'});
  if (table != null) {
    final p = table.properties;
    switch (table.type) {
      case 'Table':
        spec['list'] = {
          'rows': p['data'],
          'label': p['title'],
          ..._tableFields(p['columns']),
        };
      case 'Timeline':
        spec['list'] = {
          'rows': p['data'],
          'title': p['titleField'] ?? 'title',
          'subtitle': p['descriptionField'] ?? p['timeField'] ?? 'time',
          'status': 'status',
        };
      default:
        spec['list'] = {
          'rows': p['data'],
          'title': 'symbol',
          'value': 'price',
          'delta': 'change',
        };
    }
  } else if (templates.isNotEmpty) {
    final (owner, template, path) = templates.first;
    spec['list'] = {
      'rows': {'path': path},
      ..._templateFields(components, template),
      if (owner.properties['title'] != null) 'label': owner.properties['title'],
    };
  }
  if (book != null) {
    spec['orderBook'] = {
      'bids': book.properties['bids'],
      'asks': book.properties['asks'],
    };
  }

  // Chips, image, words.
  final badges = all({'Badge'}).take(4).toList();
  if (badges.isNotEmpty) {
    spec['chips'] = [
      for (final b in badges)
        {'text': b.properties['text'], 'status': b.properties['status']}
    ];
  }
  final image = order.firstWhereOrNull(
      (c) => c.type == 'Image' && c.properties['variant'] != 'icon');
  if (image != null) spec['image'] = image.properties['url'];
  const headings = {'h1', 'h2', 'h3', 'h4', 'h5'};
  final heading = order.firstWhereOrNull((c) =>
      c.type == 'Text' && headings.contains(c.properties['variant']));
  spec['title'] ??= heading?.properties['text'];
  final text = order.firstWhereOrNull((c) =>
      (c.type == 'Text' || c.type == 'Markdown') &&
      c != heading &&
      !headings.contains(c.properties['variant']));
  spec['caption'] = text?.properties['text'];
  spec.removeWhere((_, v) => v == null);
  return spec;
}

/// A Table's columns as list fields: the first text column titles a row,
/// the next one subtitles it, the first number is its value, the first trend
/// its change, the first image its picture.
Map<String, Object?> _tableFields(Object? columns) {
  if (columns is! List) return const {};
  final out = <String, Object?>{};
  for (final c in columns) {
    final field = c is Map ? c['field'] : c;
    if (field is! String) continue;
    final type = c is Map ? '${c['type'] ?? ''}' : '';
    final format = c is Map ? c['format'] : null;
    switch (type) {
      case 'trend':
        out['delta'] ??= field;
        out['deltaFormat'] ??= format;
      case 'number' || 'progress':
        if (out['value'] == null) {
          out['value'] = field;
          out['valueFormat'] = format;
        }
      case 'image' || 'avatar':
        out['image'] ??= field;
      case 'badge':
        out['status'] ??= field;
        out['subtitle'] ??= field;
      case 'sparkline' || 'boolean' || 'link':
        break;
      default:
        if (format is String && out['value'] == null) {
          out['value'] = field;
          out['valueFormat'] = format;
        } else if (out['title'] == null) {
          out['title'] = field;
        } else {
          out['subtitle'] ??= field;
        }
    }
  }
  return out;
}

/// The fields a list template shows, read from its components' relative
/// bindings: its first heading (or text) titles a row, the next text
/// subtitles it, a Stat's or Quote's value is its value, an image its
/// picture.
Map<String, Object?> _templateFields(
    Map<String, Component> components, String template) {
  final out = <String, Object?>{};
  String? rel(Object? v) {
    if (v is Map && v['path'] is String) {
      final path = v['path'] as String;
      if (!path.startsWith('/')) return path.isEmpty ? null : path;
    }
    return null;
  }

  final seen = <String>{};
  void visit(String id, int depth) {
    final c = components[id];
    if (c == null || depth > 32 || !seen.add(id)) return;
    final p = c.properties;
    switch (c.type) {
      case 'Text':
        final f = rel(p['text']);
        if (f != null) {
          if (out['title'] == null) {
            out['title'] = f;
          } else {
            out['subtitle'] ??= f;
          }
        }
      case 'Stat':
        out['value'] ??= rel(p['value']);
        out['valueFormat'] ??= p['format'];
        out['delta'] ??= rel(p['delta']);
        out['title'] ??= rel(p['label']);
      case 'Quote':
        out['title'] ??= rel(p['symbol']);
        out['subtitle'] ??= rel(p['name']);
        out['value'] ??= rel(p['price']);
        out['valueFormat'] ??= p['format'] ??
            (p['currency'] is String ? 'currency:${p['currency']}' : null);
        out['delta'] ??= rel(p['change']);
      case 'Trend':
        out['delta'] ??= rel(p['value']);
      case 'Image' || 'Avatar':
        out['image'] ??= rel(p['url']);
        out['title'] ??= rel(p['name']);
      case 'Badge':
        out['status'] ??= rel(p['status']);
        out['subtitle'] ??= rel(p['text']);
    }
    for (final key in ['child', 'trigger']) {
      if (p[key] is String) visit(p[key] as String, depth + 1);
    }
    if (p['children'] is List) {
      for (final child in p['children'] as List) {
        if (child is String) visit(child, depth + 1);
      }
    }
  }

  visit(template, 0);
  out.removeWhere((_, v) => v == null);
  return out;
}
