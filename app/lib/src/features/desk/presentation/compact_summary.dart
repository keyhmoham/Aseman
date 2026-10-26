/// A frontend's compact digest — what a phone-board widget shows — and its
/// view. Title, caption, icon, an optional hero metric, and simple metric
/// chips for desk cards.
library;

import 'package:flutter/material.dart';

import 'frontend_presentation.dart';

String _s(Object? v) => v == null ? '' : '$v';
List<Object?> _list(Object? v) => v is List ? v : const [];
Map<Object?, Object?> _map(Object? v) => v is Map ? v : const {};

num? _toNum(Object? value) {
  if (value is num) return value.isFinite ? value : null;
  if (value is String && value.trim().isNotEmpty) {
    final n = num.tryParse(value.trim());
    return n != null && n.isFinite ? n : null;
  }
  return null;
}

IconData? _iconOf(String name) {
  if (name.isEmpty) return null;
  return switch (name) {
    'language' => Icons.language_rounded,
    'computer' => Icons.computer_rounded,
    'apps' || 'app' => Icons.apps_rounded,
    'web' => Icons.public_rounded,
    'file' || 'description' => Icons.description_outlined,
    'dashboard' => Icons.dashboard_customize_outlined,
    'widgets' => Icons.widgets_outlined,
    _ => Icons.widgets_outlined,
  };
}

/// The headline number.
class CompactHero {
  const CompactHero({
    this.label = '',
    this.value,
    this.delta,
    this.progress,
    this.status = '',
  });

  factory CompactHero.fromJson(Map<Object?, Object?> m) {
    final progress = m['progress'];
    num? fraction;
    if (progress is Map) {
      final v = _toNum(progress['value']);
      final min = _toNum(progress['min']) ?? 0;
      final max = _toNum(progress['max']) ?? 1;
      if (v != null && max > min) fraction = (v - min) / (max - min);
    } else {
      fraction = _toNum(progress);
    }
    return CompactHero(
      label: _s(m['label'] ?? m['title']),
      value: m['value'],
      delta: _toNum(m['delta']),
      progress: fraction?.clamp(0, 1),
      status: _s(m['status']),
    );
  }

  final String label;
  final Object? value;
  final num? delta;
  final num? progress;
  final String status;

  bool get hasValue => value != null && _s(value).isNotEmpty;
  String get shown => _s(value);
}

class CompactMetric {
  const CompactMetric({this.label = '', this.value, this.delta});
  final String label;
  final Object? value;
  final num? delta;
}

class CompactChip {
  const CompactChip(this.text, [this.status = '']);
  final String text;
  final String status;
}

/// A frontend's compact digest.
class CompactSummary {
  const CompactSummary({
    this.title = '',
    this.caption = '',
    this.icon = '',
    this.image = '',
    this.hero,
    this.metrics = const [],
    this.chips = const [],
  });

  factory CompactSummary.fromJson(Object? json) {
    final m = _map(json);
    var hero = m['hero'] is Map ? CompactHero.fromJson(m['hero'] as Map) : null;
    if (hero == null &&
        (m.containsKey('value') ||
            m.containsKey('progress') ||
            m.containsKey('trend'))) {
      hero = CompactHero.fromJson({...m, 'label': m['label'] ?? m['title']});
    }
    final metrics = [
      for (final x in _list(m['metrics']))
        if (x is Map && x['value'] != null)
          CompactMetric(
            label: _s(x['label']),
            value: x['value'],
            delta: _toNum(x['delta']),
          ),
    ];
    final chips = [
      for (final c in _list(m['chips']))
        if (c is Map && _s(c['text']).isNotEmpty)
          CompactChip(_s(c['text']), _s(c['status']))
        else if (c is String && c.isNotEmpty)
          CompactChip(c),
      if (_s(m['badge']).isNotEmpty)
        CompactChip(_s(m['badge']), _s(m['status'])),
    ];
    return CompactSummary(
      title: _s(m['title']),
      caption: _s(m['caption']),
      icon: _s(m['icon']),
      image: _s(m['image']),
      hero: hero == null || (!hero.hasValue && hero.progress == null)
          ? null
          : hero,
      metrics: metrics,
      chips: chips,
    );
  }

  final String title;
  final String caption;
  final String icon;
  final String image;
  final CompactHero? hero;
  final List<CompactMetric> metrics;
  final List<CompactChip> chips;

  bool get isEmpty =>
      hero == null &&
      metrics.isEmpty &&
      chips.isEmpty &&
      title.isEmpty &&
      caption.isEmpty &&
      icon.isEmpty;
}

/// A [CompactSummary] laid out for the enclosing [FrontendPresentation].
class CompactSummaryView extends StatelessWidget {
  const CompactSummaryView({super.key, required this.summary});

  final CompactSummary summary;

  @override
  Widget build(BuildContext context) {
    final presentation = FrontendPresentation.maybeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = presentation?.accent ?? scheme.primary;
    final size = presentation?.size ?? 'medium';
    final round =
        presentation?.shape == 'circle' || presentation?.shape == 'pill';
    if (summary.isEmpty) return const SizedBox.shrink();
    if (size == 'small' || presentation?.shape == 'circle') {
      return _Small(summary: summary, accent: accent, centered: round);
    }
    return _Medium(summary: summary, accent: accent);
  }
}

class _Small extends StatelessWidget {
  const _Small(
      {required this.summary, required this.accent, required this.centered});
  final CompactSummary summary;
  final Color accent;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final hero = s.hero;
    final align =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final icon = _iconOf(s.icon);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: align,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) Icon(icon, color: accent, size: 22),
          if (hero != null && hero.hasValue) ...[
            if (icon != null) const SizedBox(height: 4),
            Text(hero.shown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: accent)),
          ] else if (s.title.isNotEmpty)
            Text(s.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _Medium extends StatelessWidget {
  const _Medium({required this.summary, required this.accent});
  final CompactSummary summary;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final scheme = Theme.of(context).colorScheme;
    final icon = _iconOf(s.icon);
    final hero = s.hero;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                s.title.isNotEmpty
                    ? s.title
                    : (hero?.label.isNotEmpty == true ? hero!.label : 'App'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
          ]),
          if (hero != null && hero.hasValue) ...[
            const SizedBox(height: 8),
            Text(hero.shown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: accent,
                    height: 1.1)),
            if (hero.delta != null)
              Text(
                hero.delta! >= 0 ? '+${hero.delta}' : '${hero.delta}',
                style: TextStyle(
                    fontSize: 12,
                    color: hero.delta! >= 0
                        ? scheme.primary
                        : scheme.error,
                    fontWeight: FontWeight.w600),
              ),
          ],
          if (s.caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(s.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3)),
          ],
          if (s.metrics.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final m in s.metrics.take(4))
                  Text('${m.label}: ${_s(m.value)}',
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ],
          if (s.chips.isNotEmpty) ...[
            const Spacer(),
            Wrap(
              spacing: 6,
              children: [
                for (final c in s.chips.take(3))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(c.text, style: const TextStyle(fontSize: 11)),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
