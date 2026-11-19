import 'package:flutter/material.dart';

import '../core/theme/app_shape.dart';

/// How a card's state reads: the tone picks the colour of its pill.
enum AgUiTone { info, success, warning, danger, neutral }

/// The words agents use for a tone (`tone`, `kind`, `severity`, `status`).
AgUiTone agUiToneOf(Object? value, {AgUiTone fallback = AgUiTone.info}) {
  switch ('${value ?? ''}'.trim().toLowerCase()) {
    case 'success':
    case 'good':
    case 'ok':
    case 'done':
    case 'tip':
    case 'positive':
      return AgUiTone.success;
    case 'warning':
    case 'warn':
    case 'caution':
    case 'pending':
      return AgUiTone.warning;
    case 'error':
    case 'danger':
    case 'critical':
    case 'important':
    case 'bad':
    case 'failed':
    case 'negative':
      return AgUiTone.danger;
    case 'neutral':
    case 'muted':
    case 'default':
      return AgUiTone.neutral;
    case 'info':
    case 'note':
      return AgUiTone.info;
  }
  return fallback;
}

Color agUiToneColor(BuildContext context, AgUiTone tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    AgUiTone.info => scheme.primary,
    AgUiTone.success => scheme.primary,
    AgUiTone.warning => scheme.tertiary,
    AgUiTone.danger => scheme.error,
    AgUiTone.neutral => scheme.onSurfaceVariant,
  };
}

/// The one frame every card an agent puts in a chat shares: a tinted glyph,
/// the words, the card's state as a pill at the right, then its body. A card
/// that is answered keeps its answer in it.
class AgUiCard extends StatelessWidget {
  const AgUiCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.tone = AgUiTone.info,
    this.status = '',
    this.statusTone = AgUiTone.neutral,
    this.children = const [],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final AgUiTone tone;

  /// A short state ("Needs you", "Allowed"); empty for none.
  final String status;
  final AgUiTone statusTone;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = agUiToneColor(context, tone);
    final statusColor = agUiToneColor(context, statusTone);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: AppShape.borderRadius(context, 16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .14),
                  borderRadius: AppShape.borderRadius(context, 10),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          height: 1.3,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (status.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (children.isNotEmpty) const SizedBox(height: 10),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A line of help or an error under a card's body.
class AgUiNote extends StatelessWidget {
  const AgUiNote(this.text, {super.key, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.35,
        color: error ? scheme.error : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// What a person answered, kept on the card.
class AgUiAnswered extends StatelessWidget {
  const AgUiAnswered({super.key, this.text = '', this.prefix = 'You answered'});
  final String text;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
                children: [
                  TextSpan(text: text.isEmpty ? prefix : '$prefix: '),
                  if (text.isNotEmpty)
                    TextSpan(
                      text: text,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// What stands where a card is still being written: soft bars, never half a
/// JSON tree.
class AgUiSkeleton extends StatefulWidget {
  const AgUiSkeleton({super.key});

  @override
  State<AgUiSkeleton> createState() => _AgUiSkeletonState();
}

class _AgUiSkeletonState extends State<AgUiSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double fraction) => FractionallySizedBox(
      widthFactor: fraction,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 10,
        decoration: BoxDecoration(
          color: scheme.outlineVariant,
          borderRadius: BorderRadius.circular(5),
        ),
      ),
    );
    return Semantics(
      label: 'Building a card',
      liveRegion: true,
      child: FadeTransition(
        opacity: Tween<double>(begin: .45, end: 1).animate(_pulse),
        child: Container(
          width: 260,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .55),
            borderRadius: AppShape.borderRadius(context, 16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              bar(.42),
              const SizedBox(height: 8),
              bar(.88),
              const SizedBox(height: 8),
              bar(.64),
            ],
          ),
        ),
      ),
    );
  }
}
