/// App building blocks drawn natively: tabs, a month calendar, a kanban
/// board, a carousel, a stepper, a chat thread, a countdown, a clock, an
/// empty state, avatar groups, pagination and breadcrumbs.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:aseman/src/elpian/core/lenient.dart';
import 'package:flutter/material.dart';

import 'charts/viz_canvas.dart';
import 'data_widgets.dart';
import 'palette.dart';
import 'text_views.dart';
import 'values.dart';

/// The emitter of a node's [event], or null when the node declares no
/// handler for it (as the kit's builders receive it).
typedef KitOn = void Function(String event, Map<String, dynamic> data)? Function(String event);

void _fire(KitOn on, String event, Map<String, dynamic> data) => on(event)?.call(event, data);

List<Map<String, dynamic>> _items(Object? v, String key) => [
      for (final x in asList(v))
        if (x is Map) asMap(x) else {key: asText(x)}
    ];

// ── Tabs ────────────────────────────────────────────────────────────────────

/// Tabs: an M3 tab bar over panels (the children, one per tab). Uncontrolled
/// by default; `selected` sets the tab from the program. `change` `{value}`.
class KitTabs extends StatefulWidget {
  const KitTabs({super.key, required this.props, required this.children, required this.on});
  final Map<String, dynamic> props;
  final List<Widget> children;
  final KitOn on;

  @override
  State<KitTabs> createState() => _KitTabsState();
}

class _KitTabsState extends State<KitTabs> with TickerProviderStateMixin {
  TabController? _controller;
  late int _index = asInt(widget.props['selected'], 0);

  List<Map<String, dynamic>> get _tabs => _items(widget.props['tabs'] ?? widget.props['items'], 'label');

  void _sync() {
    final n = math.max(1, _tabs.length);
    _index = _index.clamp(0, n - 1);
    if (_controller?.length != n) {
      _controller?.dispose();
      _controller = TabController(length: n, vsync: this, initialIndex: _index)
        ..addListener(() {
          final c = _controller!;
          // Report the new tab as soon as it is chosen, not when it finishes animating.
          if (c.index == _index) return;
          setState(() => _index = c.index);
          _fire(widget.on, 'change', {'value': c.index, 'label': _tabs.length > c.index ? asText(_tabs[c.index]['label']) : ''});
        });
    }
  }

  @override
  void didUpdateWidget(KitTabs old) {
    super.didUpdateWidget(old);
    final sel = widget.props['selected'];
    if (sel != null && sel != old.props['selected']) {
      _index = asInt(sel, _index);
      _sync();
      _controller!.animateTo(_index.clamp(0, _controller!.length - 1));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    // No tabs to show: draw the first panel rather than a bar out of step
    // with its controller.
    if (tabs.isEmpty) return widget.children.isEmpty ? const SizedBox.shrink() : widget.children.first;
    _sync();
    final secondary = widget.props['variant'] == 'secondary';
    return LayoutBuilder(builder: (context, box) {
      final scrollable = !box.maxWidth.isFinite || tabs.length > 4 || asBool(widget.props['scrollable']);
      final bar = TabBar(
        controller: _controller,
        isScrollable: scrollable,
        tabAlignment: scrollable ? TabAlignment.start : null,
        dividerColor: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .5),
        indicatorSize: secondary ? TabBarIndicatorSize.tab : TabBarIndicatorSize.label,
        tabs: [
          for (final t in tabs)
            Tab(
              height: t['icon'] != null && !secondary ? 64 : 48,
              icon: iconFor(t['icon']) == null
                  ? null
                  : (t['badge'] != null ? Badge(label: Text(asText(t['badge'])), child: Icon(iconFor(t['icon']))) : Icon(iconFor(t['icon']))),
              iconMargin: const EdgeInsets.only(bottom: 4),
              text: asText(t['label']),
            ),
        ],
      );
      final panel = _index < widget.children.length ? widget.children[_index] : const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (box.maxWidth.isFinite) bar else SizedBox(width: 360, child: bar),
        SizedBox(height: asSize(widget.props['gap'], 16)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(a), child: child),
          ),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, if (current != null) current]),
          child: KeyedSubtree(key: ValueKey(_index), child: panel),
        ),
      ]);
    });
  }
}

// ── Calendar ────────────────────────────────────────────────────────────────

/// A month calendar: days with event dots, today ringed, the selected day
/// filled, prev/next month; the selected day's events listed below.
/// Events: `select` `{date, events}`, `change` `{month}`.
class KitCalendar extends StatefulWidget {
  const KitCalendar({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  State<KitCalendar> createState() => _KitCalendarState();
}

class _KitCalendarState extends State<KitCalendar> {
  late DateTime _month;
  DateTime? _selected;

  @override
  void initState() {
    super.initState();
    _fromProps();
  }

  void _fromProps() {
    _selected = asTime(widget.props['selected']);
    final m = asTime(widget.props['month'] is String && '${widget.props['month']}'.length == 7 ? '${widget.props['month']}-01' : widget.props['month']);
    final base = m ?? _selected ?? DateTime.now();
    _month = DateTime(base.year, base.month);
  }

  @override
  void didUpdateWidget(KitCalendar old) {
    super.didUpdateWidget(old);
    if (old.props['selected'] != widget.props['selected'] || old.props['month'] != widget.props['month']) _fromProps();
  }

  void _go(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
    _fire(widget.on, 'change', {'month': dayKey(_month).substring(0, 7)});
  }

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final events = <String, List<Map<String, dynamic>>>{};
    for (final e in asRows(widget.props['events'])) {
      final d = asTime(e['date'] ?? e['start']);
      if (d != null) (events[dayKey(d)] ??= []).add(e);
    }
    final sundayFirst = widget.props['firstDay'] == 'sunday';
    final first = _month;
    final lead = sundayFirst ? first.weekday % 7 : first.weekday - 1;
    final days = DateTime(first.year, first.month + 1, 0).day;
    final cells = ((lead + days) / 7).ceil() * 7;
    final today = DateTime.now();
    final names = sundayFirst ? ['S', 'M', 'T', 'W', 'T', 'F', 'S'] : ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final selKey = _selected == null ? null : dayKey(_selected!);
    final listed = selKey == null ? const <Map<String, dynamic>>[] : (events[selKey] ?? const []);
    Color colorOf(Map<String, dynamic> e) => p.parse(e['color'] ?? e['status']) ?? p.accent;

    final grid = LayoutBuilder(builder: (context, box) {
      final w = widthIn(box, 336);
      final cell = math.min(56.0, w / 7);
      return SizedBox(
        width: cell * 7,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            for (final n in names) SizedBox(width: cell, height: 28, child: Center(child: Text(n, style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant)))),
          ]),
          for (var r = 0; r < cells / 7; r++)
            Row(children: [
              for (var c = 0; c < 7; c++)
                () {
                  final day = r * 7 + c - lead + 1;
                  if (day < 1 || day > days) return SizedBox(width: cell, height: cell);
                  final d = DateTime(first.year, first.month, day);
                  final k = dayKey(d);
                  final sel = k == selKey;
                  final isToday = k == dayKey(today);
                  final evs = events[k] ?? const [];
                  return SizedBox(
                    width: cell,
                    height: cell,
                    child: Center(
                      child: InkResponse(
                        radius: cell / 2,
                        onTap: () {
                          setState(() => _selected = d);
                          _fire(widget.on, 'select', {'date': k, 'events': evs});
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          width: cell - 6,
                          height: cell - 6,
                          decoration: BoxDecoration(
                            color: sel ? s.primary : Colors.transparent,
                            borderRadius: BorderRadius.circular(sel ? (cell - 6) * 0.32 : cell),
                            border: isToday && !sel ? Border.all(color: s.primary, width: 1.5) : null,
                          ),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('$day',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: sel || isToday ? FontWeight.w700 : FontWeight.w400,
                                    color: sel ? s.onPrimary : (isToday ? s.primary : s.onSurface))),
                            if (evs.isNotEmpty)
                              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                for (final e in evs.take(3))
                                  Container(
                                    width: 5,
                                    height: 5,
                                    margin: const EdgeInsets.only(top: 3, left: 1, right: 1),
                                    decoration: BoxDecoration(color: sel ? s.onPrimary : colorOf(e), shape: BoxShape.circle),
                                  ),
                              ]),
                          ]),
                        ),
                      ),
                    ),
                  );
                }(),
            ]),
        ]),
      );
    });

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text('${monthNames[_month.month - 1]} ${_month.year}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 12),
        IconButton.filledTonal(onPressed: () => _go(-1), icon: const Icon(Icons.chevron_left_rounded), tooltip: 'Previous month'),
        const SizedBox(width: 4),
        IconButton.filledTonal(onPressed: () => _go(1), icon: const Icon(Icons.chevron_right_rounded), tooltip: 'Next month'),
      ]),
      const SizedBox(height: 8),
      grid,
      if (asBool(widget.props['showEvents'], true) && listed.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final e in listed)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 4, height: 32, decoration: BoxDecoration(color: colorOf(e), borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 12),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(asText(e['title'] ?? e['label']), style: theme.textTheme.titleSmall),
                  if (e['time'] != null || e['subtitle'] != null)
                    Text(asText(e['time'] ?? e['subtitle']), style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
      ],
    ]);
  }
}

// ── Kanban ──────────────────────────────────────────────────────────────────

class _CardRef {
  const _CardRef(this.column, this.index, this.card);
  final int column, index;
  final Map<String, dynamic> card;
}

/// A kanban board: columns of cards; a long press drags a card to another
/// column (`move` `{card, from, to, index}` — the program moves it).
/// `select` `{column, index, card}` on a tap.
class KitKanban extends StatefulWidget {
  const KitKanban({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  State<KitKanban> createState() => _KitKanbanState();
}

class _KitKanbanState extends State<KitKanban> {
  int? _over;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final columns = asRows(widget.props['columns']);
    final colW = asDouble(widget.props['columnWidth'], 280);
    final canMove = widget.on('move') != null && asBool(widget.props['draggable'], true);

    Widget card(int c, int i, Map<String, dynamic> m, {bool feedback = false}) {
      final tags = _items(m['tags'], 'text');
      final color = p.parse(m['color'] ?? m['status'] ?? m['priority']);
      final body = Container(
        width: colW - 24,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(16),
          border: color == null ? null : Border(left: BorderSide(color: color, width: 4)),
          boxShadow: feedback ? const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(asText(m['title'] ?? m['label']), style: theme.textTheme.titleSmall),
          if (m['subtitle'] != null || m['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(asText(m['subtitle'] ?? m['description']), maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
            ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in tags) Pill(text: asText(t['text'] ?? t['label']), color: p.parse(t['color'] ?? t['status']) ?? p.accent, dot: t['status'] != null),
            ]),
          ],
          if (m['assignee'] != null || m['due'] != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              if (m['due'] != null) ...[
                Icon(Icons.schedule_rounded, size: 14, color: s.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(asText(m['due']), style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant)),
              ],
              const Spacer(),
              if (m['assignee'] != null) KitAvatar(name: asText(m['assignee']), url: looseStr(m['avatar']), size: 24),
            ]),
          ],
        ]),
      );
      if (feedback) return Material(type: MaterialType.transparency, child: body);
      final tappable = Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _fire(widget.on, 'select', {'column': c, 'index': i, 'card': m, 'columnId': columns[c]['id'] ?? columns[c]['title']}),
          child: body,
        ),
      );
      if (!canMove) return tappable;
      return LongPressDraggable<_CardRef>(
        data: _CardRef(c, i, m),
        feedback: Transform.rotate(angle: -0.03, child: card(c, i, m, feedback: true)),
        childWhenDragging: Opacity(opacity: 0.35, child: body),
        child: tappable,
      );
    }

    Widget column(int c) {
      final col = columns[c];
      final cards = asRows(col['cards'] ?? col['items']);
      final color = p.parse(col['color']) ?? p.series(c % VizPalette.maxSeries);
      final content = AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: colW,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _over == c ? s.secondaryContainer : s.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(asText(col['title'] ?? col['label']), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
              child: Text('${cards.length}', style: theme.textTheme.labelMedium),
            ),
          ]),
          const SizedBox(height: 10),
          for (var i = 0; i < cards.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: card(c, i, cards[i])),
          if (cards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(child: Text(asText(widget.props['emptyText'] ?? 'No cards'), style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant))),
            ),
        ]),
      );
      if (!canMove) return content;
      return DragTarget<_CardRef>(
        onWillAcceptWithDetails: (d) {
          setState(() => _over = c);
          return d.data.column != c;
        },
        onLeave: (_) => setState(() => _over = null),
        onAcceptWithDetails: (d) {
          setState(() => _over = null);
          _fire(widget.on, 'move', {
            'card': d.data.card,
            'from': d.data.column,
            'to': c,
            'index': cards.length,
            'fromId': columns[d.data.column]['id'] ?? columns[d.data.column]['title'],
            'toId': col['id'] ?? col['title'],
          });
        },
        builder: (context, _, __) => content,
      );
    }

    final row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var c = 0; c < columns.length; c++) ...[if (c > 0) const SizedBox(width: 12), column(c)],
    ]);
    return LayoutBuilder(
        builder: (context, box) => box.maxWidth.isFinite ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: row) : row);
  }
}

// ── Carousel ────────────────────────────────────────────────────────────────

/// A carousel: slides (the children, or `items: [{image, title, subtitle}]`)
/// that swipe, peek at their neighbours, autoplay and show dots.
/// `change` `{value}`.
class KitCarousel extends StatefulWidget {
  const KitCarousel({super.key, required this.props, required this.children, required this.on});
  final Map<String, dynamic> props;
  final List<Widget> children;
  final KitOn on;

  @override
  State<KitCarousel> createState() => _KitCarouselState();
}

class _KitCarouselState extends State<KitCarousel> {
  late final PageController _pc = PageController(viewportFraction: asDouble(widget.props['viewportFraction'], 0.88).clamp(0.3, 1.0));
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    final ms = asInt(widget.props['autoplay'], 0);
    if (ms >= 1000) {
      _timer = Timer.periodic(Duration(milliseconds: ms), (_) {
        if (!mounted || !_pc.hasClients || _count == 0) return;
        _pc.animateToPage((_page + 1) % _count, duration: const Duration(milliseconds: 500), curve: Curves.easeInOutCubicEmphasized);
      });
    }
  }

  int get _count => widget.children.isNotEmpty ? widget.children.length : asList(widget.props['items'] ?? widget.props['images']).length;

  @override
  void dispose() {
    _timer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  Widget _item(BuildContext context, Map<String, dynamic> m) {
    final s = Theme.of(context).colorScheme;
    final img = asText(m['image'] ?? m['src'] ?? m['url']);
    return Stack(fit: StackFit.expand, children: [
      if (img.isNotEmpty)
        Image.network(img, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: s.surfaceContainerHighest))
      else
        Container(color: s.primaryContainer),
      if (m['title'] != null || m['subtitle'] != null)
        Align(
          alignment: Alignment.bottomLeft,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 40, 20, 18),
            decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xB0000000)])),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (m['title'] != null) Text(asText(m['title']), style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
              if (m['subtitle'] != null) Text(asText(m['subtitle']), style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70)),
            ]),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final height = asSize(widget.props['height'], 200);
    final items = _items(widget.props['items'] ?? widget.props['images'], 'image');
    final n = _count;
    if (n == 0) return SizedBox(height: height);
    return LayoutBuilder(builder: (context, box) {
      final w = widthIn(box, 340);
      return SizedBox(
        width: w,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: height,
            child: PageView.builder(
              controller: _pc,
              itemCount: n,
              padEnds: _pc.viewportFraction >= 0.95,
              onPageChanged: (i) {
                setState(() => _page = i);
                _fire(widget.on, 'change', {'value': i});
              },
              itemBuilder: (context, i) => AnimatedPadding(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: i == _page ? 0 : 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: widget.children.isNotEmpty ? widget.children[i] : _item(context, items[i]),
                ),
              ),
            ),
          ),
          if (asBool(widget.props['dots'], true) && n > 1) ...[
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < n; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  width: i == _page ? 20 : 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(color: i == _page ? s.primary : s.outlineVariant, borderRadius: BorderRadius.circular(4)),
                ),
            ]),
          ],
        ]),
      );
    });
  }
}

// ── Stepper ─────────────────────────────────────────────────────────────────

/// Progress through steps: done (check), current (filled), error, to do;
/// vertical (with subtitles) or horizontal. `select` `{index}`.
class KitStepper extends StatelessWidget {
  const KitStepper({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final steps = _items(props['steps'] ?? props['items'], 'title');
    final current = asInt(props['current'], -1);
    String state(int i) {
      final st = steps[i]['state'] ?? steps[i]['status'];
      if (st is String) return st;
      if (current < 0) return 'todo';
      return i < current ? 'done' : (i == current ? 'current' : 'todo');
    }

    Widget dot(int i, double size) {
      final st = state(i);
      final (Color bg, Color fg, Widget child) = switch (st) {
        'done' || 'complete' || 'completed' => (s.primary, s.onPrimary, Icon(Icons.check_rounded, size: size * 0.6, color: s.onPrimary)),
        'current' || 'active' => (s.primary, s.onPrimary, Text('${i + 1}', style: TextStyle(color: s.onPrimary, fontWeight: FontWeight.w700))),
        'error' || 'failed' => (s.error, s.onError, Icon(Icons.priority_high_rounded, size: size * 0.6, color: s.onError)),
        _ => (s.surfaceContainerHighest, s.onSurfaceVariant, Text('${i + 1}', style: TextStyle(color: s.onSurfaceVariant, fontWeight: FontWeight.w600))),
      };
      return InkResponse(
        onTap: on('select') == null ? null : () => _fire(on, 'select', {'index': i, 'step': steps[i]}),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(st == 'current' || st == 'active' ? size * 0.32 : size / 2),
            boxShadow: st == 'current' || st == 'active' ? [BoxShadow(color: s.primary.withValues(alpha: .35), blurRadius: 0, spreadRadius: 4)] : null,
          ),
          child: DefaultTextStyle.merge(style: TextStyle(color: fg), child: child),
        ),
      );
    }

    bool doneAt(int i) => ['done', 'complete', 'completed'].contains(state(i));
    return LayoutBuilder(builder: (context, box) {
      final horizontal = props['orientation'] == 'horizontal' || (props['orientation'] == null && box.maxWidth.isFinite && box.maxWidth > 520 && steps.length <= 6);
      if (horizontal && box.maxWidth.isFinite) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Column(children: [
                Row(children: [
                  Expanded(child: i == 0 ? const SizedBox() : Container(height: 3, color: doneAt(i - 1) ? s.primary : s.outlineVariant)),
                  dot(i, 32),
                  Expanded(child: i == steps.length - 1 ? const SizedBox() : Container(height: 3, color: doneAt(i) ? s.primary : s.outlineVariant)),
                ]),
                const SizedBox(height: 8),
                Text(asText(steps[i]['title'] ?? steps[i]['label']), textAlign: TextAlign.center, style: theme.textTheme.labelLarge?.copyWith(fontWeight: state(i) == 'current' ? FontWeight.w700 : FontWeight.w500)),
                if (steps[i]['subtitle'] != null)
                  Text(asText(steps[i]['subtitle']), textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
              ]),
            ),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Column(children: [
                dot(i, 32),
                if (i < steps.length - 1)
                  Expanded(child: Container(width: 3, margin: const EdgeInsets.symmetric(vertical: 4), decoration: BoxDecoration(color: doneAt(i) ? s.primary : s.outlineVariant, borderRadius: BorderRadius.circular(2)))),
              ]),
              const SizedBox(width: 14),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5, bottom: 18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(asText(steps[i]['title'] ?? steps[i]['label']), style: theme.textTheme.titleSmall?.copyWith(fontWeight: state(i) == 'current' ? FontWeight.w700 : FontWeight.w500)),
                    if (steps[i]['subtitle'] != null || steps[i]['description'] != null)
                      Text(asText(steps[i]['subtitle'] ?? steps[i]['description']), style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                  ]),
                ),
              ),
            ]),
          ),
      ]);
    });
  }
}

// ── Chat ────────────────────────────────────────────────────────────────────

/// A chat thread: the person's messages on the right (primary container),
/// others on the left with avatars, consecutive messages grouped, system
/// notes centered, light markdown, a typing indicator and suggestion chips
/// (`select` `{text}`).
class KitChat extends StatelessWidget {
  const KitChat({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final p = VizPalette.of(context);
    final msgs = asRows(props['messages']);
    final me = {'user', 'me', 'self', asText(props['me'])};
    final avatars = asBool(props['showAvatars'], true);
    return LayoutBuilder(builder: (context, box) {
      final w = widthIn(box, 360);
      final maxBubble = w * 0.78;
      return SizedBox(
        width: w,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < msgs.length; i++)
            () {
              final m = msgs[i];
              final role = asText(m['role'] ?? m['from'] ?? 'assistant');
              final mine = me.contains(role);
              if (role == 'system') {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: Text(asText(m['text']), style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant))),
                );
              }
              final prevSame = i > 0 && asText(msgs[i - 1]['role'] ?? msgs[i - 1]['from'] ?? 'assistant') == role;
              final nextSame = i < msgs.length - 1 && asText(msgs[i + 1]['role'] ?? msgs[i + 1]['from'] ?? 'assistant') == role;
              const big = Radius.circular(20), small = Radius.circular(6);
              final bubble = Container(
                constraints: BoxConstraints(maxWidth: maxBubble),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: mine ? s.primaryContainer : s.surfaceContainerHigh,
                  borderRadius: BorderRadius.only(
                    topLeft: !mine && prevSame ? small : big,
                    bottomLeft: !mine && nextSame ? small : (mine ? big : small),
                    topRight: mine && prevSame ? small : big,
                    bottomRight: mine && nextSame ? small : (mine ? small : big),
                  ),
                ),
                child: Text.rich(
                  TextSpan(children: inlineSpans(asText(m['text']), theme.textTheme.bodyMedium!.copyWith(color: mine ? s.onPrimaryContainer : s.onSurface, height: 1.4), p)),
                ),
              );
              final meta = (!nextSame && (m['time'] != null || (!mine && m['name'] != null)))
                  ? Padding(
                      padding: EdgeInsets.only(top: 3, left: mine ? 0 : (avatars ? 40 : 4), right: 4),
                      child: Text([if (!mine && m['name'] != null) asText(m['name']), if (m['time'] != null) asText(m['time'])].join(' · '),
                          style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant)),
                    )
                  : null;
              return Padding(
                padding: EdgeInsets.only(top: prevSame ? 2 : 10),
                child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (!mine && avatars) ...[
                      nextSame ? const SizedBox(width: 32) : KitAvatar(name: asText(m['name'] ?? role), url: looseStr(m['avatar']), size: 32),
                      const SizedBox(width: 8),
                    ],
                    bubble,
                  ]),
                  ?meta,
                ]),
              );
            }(),
          if (asBool(props['typing']))
            Padding(
              padding: EdgeInsets.only(top: 10, left: avatars ? 40 : 0),
              child: Align(alignment: Alignment.centerLeft, child: _Typing(color: s.onSurfaceVariant, bg: s.surfaceContainerHigh)),
            ),
          if (asList(props['suggestions']).isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
              for (final t in asList(props['suggestions']))
                ActionChip(label: Text(asText(t)), avatar: const Icon(Icons.auto_awesome_rounded, size: 16), onPressed: () => _fire(on, 'select', {'text': asText(t)})),
            ]),
          ],
        ]),
      );
    });
  }
}

class _Typing extends StatefulWidget {
  const _Typing({required this.color, required this.bg});
  final Color color, bg;

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: widget.bg, borderRadius: BorderRadius.circular(20)),
        child: AnimatedBuilder(
          animation: _a,
          builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.35 + 0.65 * (0.5 + 0.5 * math.sin((_a.value - i * 0.18) * 2 * math.pi)).clamp(0, 1)),
                  shape: BoxShape.circle,
                ),
              ),
          ]),
        ),
      );
}

// ── Countdown and clock ─────────────────────────────────────────────────────

/// A live countdown to `to` (a date/time) or for `seconds`: days, hours,
/// minutes and seconds on tonal tiles. `done` fires when it reaches zero.
class KitCountdown extends StatefulWidget {
  const KitCountdown({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  State<KitCountdown> createState() => _KitCountdownState();
}

class _KitCountdownState extends State<KitCountdown> {
  late DateTime _target;
  Timer? _timer;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _setTarget();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!_fired && !_target.isAfter(DateTime.now())) {
        _fired = true;
        _fire(widget.on, 'done', {});
      }
    });
  }

  void _setTarget() {
    final to = asTime(widget.props['to'] ?? widget.props['until']);
    _target = to ?? DateTime.now().add(Duration(seconds: asInt(widget.props['seconds'], 0)));
  }

  @override
  void didUpdateWidget(KitCountdown old) {
    super.didUpdateWidget(old);
    if (old.props['to'] != widget.props['to'] || old.props['seconds'] != widget.props['seconds']) {
      _setTarget();
      _fired = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    var left = _target.difference(DateTime.now());
    if (left.isNegative) left = Duration.zero;
    final size = '${widget.props['size'] ?? 'default'}';
    final hero = size == 'hero', compact = size == 'compact';
    final parts = <(int, String)>[
      if (left.inDays > 0 || widget.props['showDays'] == true) (left.inDays, 'days'),
      (left.inHours % 24, 'hours'),
      (left.inMinutes % 60, 'min'),
      if (widget.props['showSeconds'] != false) (left.inSeconds % 60, 'sec'),
    ];
    final numStyle = (hero ? theme.textTheme.displayMedium : (compact ? theme.textTheme.titleLarge : theme.textTheme.headlineMedium))!
        .copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()], color: s.onPrimaryContainer);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (widget.props['label'] != null) ...[
        Text(asText(widget.props['label']), style: theme.textTheme.labelLarge?.copyWith(color: s.onSurfaceVariant)),
        const SizedBox(height: 6),
      ],
      Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (i, part) in parts.indexed) ...[
          if (i > 0) SizedBox(width: compact ? 6 : 8),
          Container(
            constraints: BoxConstraints(minWidth: hero ? 96 : (compact ? 48 : 68)),
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 6 : 10),
            decoration: BoxDecoration(color: s.primaryContainer, borderRadius: BorderRadius.circular(compact ? 12 : 20)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(part.$1.toString().padLeft(2, '0'), style: numStyle),
              Text(part.$2, style: theme.textTheme.labelSmall?.copyWith(color: s.onPrimaryContainer.withValues(alpha: .8))),
            ]),
          ),
        ],
      ]),
    ]);
  }
}

/// A live clock: analog (default) or digital, in a time zone (`utcOffset`
/// hours), with an optional label (a city).
class KitClock extends StatefulWidget {
  const KitClock({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<KitClock> createState() => _KitClockState();
}

class _KitClockState extends State<KitClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final offset = asNum(widget.props['utcOffset'])?.toDouble();
    final now = offset == null ? DateTime.now() : DateTime.now().toUtc().add(Duration(minutes: (offset * 60).round()));
    final label = widget.props['label'] == null ? null : asText(widget.props['label']);
    final seconds = asBool(widget.props['seconds'], true);
    String two(int n) => n.toString().padLeft(2, '0');
    if (widget.props['mode'] == 'digital') {
      final h24 = asBool(widget.props['hour24'], true);
      final h = h24 ? now.hour : (now.hour % 12 == 0 ? 12 : now.hour % 12);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: '${two(h)}:${two(now.minute)}', style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
          if (seconds) TextSpan(text: ':${two(now.second)}', style: theme.textTheme.headlineSmall?.copyWith(color: s.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
          if (!h24) TextSpan(text: now.hour < 12 ? ' AM' : ' PM', style: theme.textTheme.titleMedium?.copyWith(color: s.onSurfaceVariant)),
        ])),
        Text([?label, formatValue(now.toIso8601String(), 'date')].join(' · '), style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
      ]);
    }
    final size = asDouble(widget.props['size'], 160).clamp(64, 480).toDouble();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.square(dimension: size, child: CustomPaint(painter: _ClockPainter(now, s, seconds))),
      if (label != null) ...[
        const SizedBox(height: 8),
        Text(label, style: theme.textTheme.titleSmall),
        Text('${two(now.hour)}:${two(now.minute)}', style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
      ],
    ]);
  }
}

class _ClockPainter extends CustomPainter {
  _ClockPainter(this.now, this.s, this.seconds);
  final DateTime now;
  final ColorScheme s;
  final bool seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = s.surfaceContainerHigh);
    for (var i = 0; i < 12; i++) {
      final a = i / 12 * 2 * math.pi;
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(c + dir * r * (i % 3 == 0 ? .74 : .8), c + dir * r * .86,
          Paint()..color = i % 3 == 0 ? s.onSurface : s.outline..strokeWidth = i % 3 == 0 ? 3 : 1.5..strokeCap = StrokeCap.round);
    }
    void hand(double turns, double len, double w, Color color) {
      final a = turns * 2 * math.pi;
      canvas.drawLine(c - Offset(math.sin(a), -math.cos(a)) * r * .1, c + Offset(math.sin(a), -math.cos(a)) * r * len,
          Paint()..color = color..strokeWidth = w..strokeCap = StrokeCap.round);
    }

    final sec = now.second + now.millisecond / 1000;
    hand((now.hour % 12 + now.minute / 60) / 12, .5, r * .08, s.onSurface);
    hand((now.minute + sec / 60) / 60, .72, r * .055, s.onSurface);
    if (seconds) hand(sec / 60, .8, r * .025, s.primary);
    canvas.drawCircle(c, r * .05, Paint()..color = s.primary);
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.now != now || old.s != s;
}

// ── Small pieces ────────────────────────────────────────────────────────────

/// An empty state: an icon on a tonal rounded square, a title, one line
/// and the action that fills it (`action` event).
class KitEmptyState extends StatelessWidget {
  const KitEmptyState({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final compact = props['size'] == 'compact';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 12 : 32, horizontal: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: compact ? 56 : 80,
          height: compact ? 56 : 80,
          decoration: BoxDecoration(color: s.secondaryContainer, borderRadius: BorderRadius.circular(compact ? 20 : 28)),
          child: Icon(iconFor(props['icon']) ?? Icons.inbox_rounded, size: compact ? 28 : 38, color: s.onSecondaryContainer),
        ),
        SizedBox(height: compact ? 10 : 16),
        Text(asText(props['title'] ?? 'Nothing here yet'), textAlign: TextAlign.center, style: (compact ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)?.copyWith(fontWeight: FontWeight.w700)),
        if (props['text'] != null) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(asText(props['text']), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
          ),
        ],
        if (props['action'] != null) ...[
          SizedBox(height: compact ? 12 : 20),
          FilledButton.tonalIcon(
            onPressed: on('action') == null ? null : () => _fire(on, 'action', {}),
            icon: Icon(iconFor(props['actionIcon']) ?? Icons.add_rounded),
            label: Text(asText(props['action'])),
          ),
        ],
      ]),
    );
  }
}

/// Overlapping avatars (`names` or `items: [{name, url}]`), past `max` a
/// "+N" chip.
class KitAvatarGroup extends StatelessWidget {
  const KitAvatarGroup({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final items = _items(props['items'] ?? props['names'] ?? props['people'], 'name');
    final size = asSize(props['size'], 32);
    final max = asCount(props['max'], 4);
    final shown = items.take(max).toList();
    final more = items.length - shown.length;
    final step = size * 0.68;
    final n = shown.length + (more > 0 ? 1 : 0);
    if (n == 0) return const SizedBox.shrink();
    Widget ring(Widget child) => Container(padding: const EdgeInsets.all(2), decoration: BoxDecoration(color: s.surface, shape: BoxShape.circle), child: child);
    return SizedBox(
      width: step * (n - 1) + size + 4,
      height: size + 4,
      child: Stack(children: [
        for (var i = 0; i < shown.length; i++)
          Positioned(left: step * i, child: ring(KitAvatar(name: asText(shown[i]['name'] ?? shown[i]['label']), url: looseStr(shown[i]['url']) ?? looseStr(shown[i]['image']), size: size))),
        if (more > 0)
          Positioned(
            left: step * shown.length,
            child: ring(Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: s.surfaceContainerHighest, shape: BoxShape.circle),
              child: Text('+$more', style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w700, color: s.onSurfaceVariant)),
            )),
          ),
      ]),
    );
  }
}

/// Page numbers with prev/next; `change` `{value}` (1-based).
class KitPagination extends StatelessWidget {
  const KitPagination({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final pages = math.max(1, asInt(props['pages'] ?? props['total'], 1));
    final page = asInt(props['page'] ?? props['value'], 1).clamp(1, pages);
    final sib = asInt(props['siblings'], 1);
    void go(int n) => _fire(on, 'change', {'value': n});
    final nums = <int?>[];
    for (var n = 1; n <= pages; n++) {
      if (n == 1 || n == pages || (n - page).abs() <= sib) {
        nums.add(n);
      } else if (nums.isNotEmpty && nums.last != null) {
        nums.add(null);
      }
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton.filledTonal(onPressed: page > 1 ? () => go(page - 1) : null, icon: const Icon(Icons.chevron_left_rounded), tooltip: 'Previous'),
      const SizedBox(width: 4),
      for (final n in nums)
        n == null
            ? Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('…', style: theme.textTheme.titleMedium?.copyWith(color: s.onSurfaceVariant)))
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: InkResponse(
                  onTap: n == page ? null : () => go(n),
                  radius: 22,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: n == page ? s.primary : Colors.transparent, borderRadius: BorderRadius.circular(n == page ? 14 : 20)),
                    child: Text('$n', style: theme.textTheme.labelLarge?.copyWith(color: n == page ? s.onPrimary : s.onSurface, fontWeight: n == page ? FontWeight.w700 : FontWeight.w500)),
                  ),
                ),
              ),
      const SizedBox(width: 4),
      IconButton.filledTonal(onPressed: page < pages ? () => go(page + 1) : null, icon: const Icon(Icons.chevron_right_rounded), tooltip: 'Next'),
    ]);
  }
}

/// Breadcrumbs: where the person is; earlier crumbs are tappable
/// (`select` `{index, label}`).
class KitBreadcrumbs extends StatelessWidget {
  const KitBreadcrumbs({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final items = _items(props['items'], 'label');
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 2, runSpacing: 4, children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) Icon(Icons.chevron_right_rounded, size: 18, color: s.onSurfaceVariant),
        i == items.length - 1
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(asText(items[i]['label']), style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
              )
            : InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _fire(on, 'select', {'index': i, 'label': asText(items[i]['label'])}),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (iconFor(items[i]['icon']) != null) ...[Icon(iconFor(items[i]['icon']), size: 16, color: s.primary), const SizedBox(width: 4)],
                    Text(asText(items[i]['label']), style: theme.textTheme.labelLarge?.copyWith(color: s.primary)),
                  ]),
                ),
              ),
      ],
    ]);
  }
}
