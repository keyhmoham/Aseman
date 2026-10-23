/// Market components: Quote (a live price row that flashes on change),
/// OrderBook (bids and asks with depth), TickerTape (a scrolling strip of
/// quotes), AllocationBar (a 100% bar of weights) and Trend (a signed,
/// colored change).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../features/tools/ui_kit/kit.dart' as kit;
import '../runtime/format.dart';
import 'item.dart';
import 'style.dart';

Map<String, Schema> _props(Map<String, String> props) => {
      for (final e in props.entries) e.key: P.any(e.value),
    };

const _tabular = [FontFeature.tabularFigures()];

String _money(Object? v, Object? currency, [Object? format]) {
  if (format is String && format.isNotEmpty) return kit.formatValue(v, format);
  final n = toNum(v);
  if (n == null) return stringifyValue(v);
  final decimals = n.abs() >= 1000
      ? 2
      : n.abs() >= 1
          ? 2
          : 4;
  return currency is String && currency.isNotEmpty
      ? specFormatCurrency({'value': n, 'currency': currency, 'decimals': decimals})
      : specFormatNumber({'value': n, 'decimals': decimals});
}

// ---------------------------------------------------------------------------
// Quote
// ---------------------------------------------------------------------------

final quoteItem = asemanItem(
  'Quote',
  description: 'A market quote: symbol, name, price and its change; the price '
      'flashes green / red when it moves. Bind it to live data.',
  properties: {
    ..._props({
      'symbol': 'The ticker (AAPL, BTC-USD).',
      'name': 'The instrument name.',
      'price': 'The last price.',
      'change': 'The change as a fraction (0.0123 → +1.23%).',
      'changeAbs': 'The change in price units.',
      'currency': 'ISO currency of the price (USD).',
      'format': 'Price format (overrides currency).',
      'trend': 'Recent prices for a sparkline.',
      'logo': 'An image URL for the instrument.',
      'caption': 'A small note (exchange, "Delayed 15 min").',
      'size': 'row (default) or large.',
    }),
    'action': P.action('Fired when tapped.'),
  },
  required: ['symbol', 'price'],
  build: (item, p) => _Quote(item: item, props: p),
);

class _Quote extends StatefulWidget {
  const _Quote({required this.item, required this.props});
  final AgUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_Quote> createState() => _QuoteState();
}

class _QuoteState extends State<_Quote> {
  int _flash = 0; // 1 up, -1 down
  int _generation = 0;

  @override
  void didUpdateWidget(_Quote old) {
    super.didUpdateWidget(old);
    final was = toNum(old.props['price']);
    final now = toNum(widget.props['price']);
    if (was != null && now != null && was != now) {
      _flash = now > was ? 1 : -1;
      final generation = ++_generation;
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted && generation == _generation) setState(() => _flash = 0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final scheme = Theme.of(context).colorScheme;
    final palette = kit.VizPalette.of(context);
    final large = p['size'] == 'large';
    final change = toNum(p['change']);
    final changeAbs = toNum(p['changeAbs']);
    final trend = [for (final v in p['trend'] is List ? p['trend'] as List : const <Object?>[]) toNum(v)]
        .whereType<num>()
        .toList();
    final name = stringifyValue(p['name']);
    final caption = stringifyValue(p['caption']);
    final logo = stringifyValue(p['logo']);
    final direction = (change ?? changeAbs ?? 0).sign;
    final flashColor = _flash == 0
        ? Colors.transparent
        : (_flash > 0 ? kit.VizPalette.good : kit.VizPalette.critical)
            .withValues(alpha: .16);
    final price = Text(
      _money(p['price'], p['currency'], p['format']),
      style: agUiTextStyle(context, large ? 'h2' : 'body').copyWith(
          fontWeight: FontWeight.w800, fontFeatures: _tabular),
    );
    final changeText = Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
      if (changeAbs != null)
        kit.TrendText(
            value: changeAbs, format: '+number:2', arrow: change == null),
      if (change != null) kit.TrendText(value: change, format: '+percent:2'),
    ]);
    final identity = Row(children: [
      kit.KitAvatar(
          name: stringifyValue(p['symbol']),
          url: logo.isEmpty ? null : logo,
          size: large ? 40 : 34),
      const SizedBox(width: 12),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(stringifyValue(p['symbol']),
                overflow: TextOverflow.ellipsis,
                style: agUiTextStyle(context, large ? 'h5' : 'body')
                    .copyWith(fontWeight: FontWeight.w800)),
            if (name.isNotEmpty || caption.isNotEmpty)
              Text(
                  [name, caption].where((s) => s.isNotEmpty).join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: agUiTextStyle(context, 'caption')),
          ],
        ),
      ),
    ]);
    final spark = trend.length >= 2
        ? SizedBox(
            width: large ? 140 : 72,
            height: large ? 44 : 28,
            child: kit.Sparkline.fromProps({
              'values': trend,
              'color': direction < 0 ? 'critical' : 'good',
              'height': large ? 44 : 28,
              'area': true,
            }, palette),
          )
        : null;
    final body = large
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 10,
            children: [
              identity,
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [price, changeText])),
                ?spark,
              ]),
            ],
          )
        : Row(children: [
            Expanded(child: identity),
            if (spark != null) ...[spark, const SizedBox(width: 12)],
            Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [price, changeText]),
          ]);
    final action = widget.item.raw['action'];
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppShape.control),
        onTap: action == null ? null : () => widget.item.fire(action),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: EdgeInsets.symmetric(
              horizontal: large ? 4 : 8, vertical: large ? 4 : 8),
          decoration: BoxDecoration(
              color: flashColor,
              borderRadius: BorderRadius.circular(AppShape.control)),
          child: DefaultTextStyle.merge(
              style: TextStyle(color: scheme.onSurface), child: body),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Order book
// ---------------------------------------------------------------------------

final orderBookItem = asemanItem(
  'OrderBook',
  description: 'Bids and asks with depth bars and the spread. Rows are '
      '{price, size} (or [price, size]); best prices first.',
  properties: {
    ..._props({
      'bids': 'Buy orders, highest price first.',
      'asks': 'Sell orders, lowest price first.',
      'levels': 'Rows per side (default 8).',
      'priceFormat': 'Price format (default number:2).',
      'sizeFormat': 'Size format (default compact).',
      'title': 'A title.',
    }),
    'action': P.action('Fired when a row is tapped; its context also gets '
        '{side, price, size}.'),
  },
  required: ['bids', 'asks'],
  build: (item, p) => Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final levels = toNum(p['levels'])?.toInt() ?? 8;
    List<(num, num)> side(Object? rows) => [
          for (final r in rows is List ? rows : const <Object?>[])
            if (r is Map && toNum(r['price']) != null)
              (toNum(r['price'])!, toNum(r['size'] ?? r['amount'] ?? r['qty']) ?? 0)
            else if (r is List && r.length >= 2 && toNum(r[0]) != null)
              (toNum(r[0])!, toNum(r[1]) ?? 0),
        ].take(levels).toList();
    final bids = side(p['bids']);
    final asks = side(p['asks']);
    num cum(List<(num, num)> rows) =>
        rows.fold<num>(0, (s, r) => s + r.$2);
    final depth = math.max(cum(bids), cum(asks));
    final priceFormat =
        p['priceFormat'] is String ? p['priceFormat'] as String : 'number:2';
    final sizeFormat =
        p['sizeFormat'] is String ? p['sizeFormat'] as String : 'compact';
    final spread = bids.isNotEmpty && asks.isNotEmpty
        ? asks.first.$1 - bids.first.$1
        : null;
    final mid =
        spread == null ? null : (asks.first.$1 + bids.first.$1) / 2;
    final action = item.raw['action'];
    final style = agUiTextStyle(context, 'caption').copyWith(
        fontFeatures: _tabular, color: scheme.onSurface, fontSize: 12.5);

    Widget rows(List<(num, num)> rows, bool buy) {
      final color = buy ? kit.VizPalette.good : kit.VizPalette.critical;
      num running = 0;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in rows)
            Builder(builder: (context) {
              running += r.$2;
              final fill = depth == 0 ? 0.0 : (running / depth).toDouble();
              return InkWell(
                onTap: action == null
                    ? null
                    : () => item.fire(action, extra: {
                          'side': buy ? 'bid' : 'ask',
                          'price': r.$1,
                          'size': r.$2,
                        }),
                child: Stack(children: [
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment:
                          buy ? Alignment.centerRight : Alignment.centerLeft,
                      widthFactor: fill.clamp(0.0, 1.0),
                      child: ColoredBox(color: color.withValues(alpha: .13)),
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: buy
                          ? [
                              Expanded(
                                  child: Text(kit.formatValue(r.$2, sizeFormat),
                                      style: style)),
                              Text(kit.formatValue(r.$1, priceFormat),
                                  style: style.copyWith(
                                      color: color,
                                      fontWeight: FontWeight.w700)),
                            ]
                          : [
                              Text(kit.formatValue(r.$1, priceFormat),
                                  style: style.copyWith(
                                      color: color,
                                      fontWeight: FontWeight.w700)),
                              Expanded(
                                  child: Text(kit.formatValue(r.$2, sizeFormat),
                                      textAlign: TextAlign.end, style: style)),
                            ],
                    ),
                  ),
                ]),
              );
            }),
        ],
      );
    }

    final title = stringifyValue(p['title']);
    final header = agUiTextStyle(context, 'caption');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          if (title.isNotEmpty)
            Expanded(
                child: Text(title,
                    style: agUiTextStyle(context, 'h5')))
          else
            const Spacer(),
          if (spread != null)
            Text(
                'Spread ${kit.formatValue(spread, priceFormat)}'
                '${mid == null || mid == 0 ? '' : ' (${kit.formatValue(spread / mid, 'percent:3')})'}',
                style: header),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Expanded(child: Text('Size', style: header)),
                    Text('Bid', style: header),
                  ]))),
          const SizedBox(width: 6),
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Text('Ask', style: header),
                    Expanded(
                        child: Text('Size',
                            textAlign: TextAlign.end, style: header)),
                  ]))),
        ]),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: rows(bids, true)),
          const SizedBox(width: 6),
          Expanded(child: rows(asks, false)),
        ]),
      ],
    );
  }),
);

// ---------------------------------------------------------------------------
// Ticker tape
// ---------------------------------------------------------------------------

final tickerTapeItem = asemanItem(
  'TickerTape',
  description: 'A strip of quotes scrolling sideways: rows of {symbol, '
      'price, change}.',
  properties: _props({
    'data': 'The quotes.',
    'speed': 'Pixels per second (default 40; 0 holds still).',
    'format': 'Price format (default number:2).',
  }),
  required: ['data'],
  build: (item, p) => _TickerTape(
    rows: kit.asRows(p['data']),
    speed: toNum(p['speed'])?.toDouble() ?? 40,
    format: p['format'] is String ? p['format'] as String : 'number:2',
  ),
);

class _TickerTape extends StatefulWidget {
  const _TickerTape(
      {required this.rows, required this.speed, required this.format});
  final List<Map<String, dynamic>> rows;
  final double speed;
  final String format;

  @override
  State<_TickerTape> createState() => _TickerTapeState();
}

class _TickerTapeState extends State<_TickerTape>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  Ticker? _ticker;
  Duration _last = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!still && widget.speed > 0 && _ticker == null) {
      _ticker = createTicker(_tick)..start();
    } else if (still) {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    var next = _scroll.offset + widget.speed * dt;
    // The strip repeats once: jump back by one copy's width.
    if (next >= max / 2 + 1) next -= max / 2 + 1;
    _scroll.jumpTo(next.clamp(0, max));
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(Map<String, dynamic> r) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
            Text(stringifyValue(r['symbol']),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(kit.formatValue(r['price'], widget.format),
                style: const TextStyle(fontFeatures: _tabular)),
            if (toNum(r['change']) != null)
              kit.TrendText(value: toNum(r['change']), format: '+percent:2'),
          ]),
        );
    final once = [for (final r in widget.rows) chip(r)];
    return Container(
      height: 40,
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999)),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        physics: _ticker == null
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        child: Row(children: [...once, if (_ticker != null) ...once]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Allocation and trend
// ---------------------------------------------------------------------------

final allocationBarItem = asemanItem(
  'AllocationBar',
  description: 'Shares of a whole as one 100% bar with a legend (portfolio '
      'allocation, order mix).',
  properties: _props({
    'data': 'The rows.',
    'label': 'The label field (default "label").',
    'value': 'The weight field (default "value").',
    'format': 'How shares are shown (default percent:1).',
    'title': 'A title.',
    'height': 'Bar height (default 14).',
  }),
  required: ['data'],
  build: (item, p) => Builder(builder: (context) {
    final palette = kit.VizPalette.of(context);
    final rows = kit.asRows(p['data']);
    final labelField = p['label'] is String ? p['label'] as String : 'label';
    final valueField = p['value'] is String ? p['value'] as String : 'value';
    final parts = [
      for (final r in rows)
        (
          label: stringifyValue(kit.field(r, labelField)),
          value: math.max(0, toNum(kit.field(r, valueField)) ?? 0),
          color: agUiColor(context, r['color']),
        )
    ].where((x) => x.value > 0).toList();
    final total = parts.fold<num>(0, (s, x) => s + x.value);
    final format = p['format'] is String ? p['format'] as String : 'percent:1';
    final title = stringifyValue(p['title']);
    final height = toNum(p['height'])?.toDouble() ?? 14;
    Color colorOf(int i) => parts[i].color ?? palette.series(i);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 10,
      children: [
        if (title.isNotEmpty) Text(title, style: kit.VizText.title(palette)),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: height,
            child: total == 0
                ? ColoredBox(color: palette.neutral)
                : Row(spacing: 2, children: [
                    for (var i = 0; i < parts.length; i++)
                      Expanded(
                        flex: math.max(1, (parts[i].value / total * 1000).round()),
                        child: Tooltip(
                          message:
                              '${parts[i].label}: ${kit.formatValue(parts[i].value / total, format)}',
                          child: ColoredBox(color: colorOf(i)),
                        ),
                      ),
                  ]),
          ),
        ),
        Wrap(spacing: 14, runSpacing: 6, children: [
          for (var i = 0; i < parts.length; i++)
            Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
              kit.Swatch(color: colorOf(i)),
              Text(parts[i].label, style: kit.VizText.label(palette)),
              Text(
                  total == 0
                      ? ''
                      : kit.formatValue(parts[i].value / total, format),
                  style: kit.VizText.value(palette)),
            ]),
        ]),
      ],
    );
  }),
);

final trendItem = asemanItem(
  'Trend',
  description: 'A signed change in green (good) or red (bad) with an arrow: '
      'inline P&L, price moves.',
  properties: _props({
    'value': 'The change.',
    'format': 'Its format (default +percent:2).',
    'label': 'Text after it ("today").',
    'goodDirection': 'up (default) or down.',
    'size': 'small, medium or large.',
  }),
  required: ['value'],
  build: (item, p) => Builder(builder: (context) {
    final palette = kit.VizPalette.of(context);
    final size = switch (p['size']) {
      'large' => 22.0,
      'small' => 12.0,
      _ => 14.0,
    };
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: kit.TrendText(
        value: toNum(p['value']),
        format: p['format'] is String ? p['format'] as String : '+percent:2',
        goodDown: p['goodDirection'] == 'down',
        suffix: stringifyValue(p['label']).isEmpty
            ? null
            : stringifyValue(p['label']),
        style: kit.VizText.value(palette).copyWith(
            fontSize: size, fontWeight: FontWeight.w700),
      ),
    );
  }),
);

/// The market components.
final List<CatalogItem> marketItems = [
  quoteItem, orderBookItem, tickerTapeItem, allocationBarItem, trendItem,
];
