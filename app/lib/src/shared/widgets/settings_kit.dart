import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import 'app_inputs.dart' show AppChoice;
import 'overlay_panels.dart';
import 'sky_ui.dart';

/// The settings vocabulary: captioned groups of rows, picker rows that open
/// a sheet, key/value rows, empty and error states, and one pull-to-refresh
/// hook. Every settings page and embedded panel is built from these so they
/// read as one system.

/// An account id the way people can read it: `0000…0001`, never the full
/// 32 characters running off the card.
String shortAccountId(String id) =>
    id.length <= 14 ? id : '${id.substring(0, 6)}…${id.substring(id.length - 4)}';

/// Small uppercase label above a group, with an optional trailing widget.
class SettingsCaption extends StatelessWidget {
  const SettingsCaption(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.xs,
      0,
      AppSpacing.xs,
      AppSpacing.xs,
    ),
    child: Row(
      children: [
        Expanded(
          child: EyebrowLabel(
            text,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

/// Quiet explanation under a group.
class SettingsFooter extends StatelessWidget {
  const SettingsFooter(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.sm,
      AppSpacing.xs,
      AppSpacing.sm,
      0,
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.35,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// A captioned card of rows with hairline dividers between them.
///
/// [dividerIndent] defaults to the text column of an icon row; pass a
/// smaller value for rows without an icon.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.children,
    this.caption,
    this.captionTrailing,
    this.footer,
    this.dividerIndent = AppSpacing.sm + 2 + 34 + AppSpacing.sm,
  });
  final List<Widget> children;
  final String? caption;
  final Widget? captionTrailing;
  final String? footer;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (caption != null)
            SettingsCaption(caption!, trailing: captionTrailing),
          SoftCard(
            radius: AppShape.card,
            showOrb: false,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: dividerIndent,
                      endIndent: AppSpacing.sm + 2,
                      color: scheme.outlineVariant.withValues(alpha: .5),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null) SettingsFooter(footer!),
        ],
      ),
    );
  }
}

/// A captioned card around free content (controls, text, chips).
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.child,
    this.caption,
    this.captionTrailing,
    this.footer,
    this.padding = const EdgeInsets.all(AppSpacing.md),
  });
  final Widget child;
  final String? caption;
  final Widget? captionTrailing;
  final String? footer;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption != null)
          SettingsCaption(caption!, trailing: captionTrailing),
        SoftCard(
          radius: AppShape.card,
          showOrb: false,
          padding: padding,
          child: child,
        ),
        if (footer != null) SettingsFooter(footer!),
      ],
    ),
  );
}

/// A row that shows a fact: label on the left, value on the right.
class SettingsInfoRow extends StatelessWidget {
  const SettingsInfoRow({
    super.key,
    required this.label,
    this.value,
    this.trailing,
  });
  final String label;
  final String? value;

  /// Replaces [value] with a widget such as a status chip.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child:
                trailing != null
                    ? Align(alignment: Alignment.centerRight, child: trailing)
                    : Text(
                        value == null || value!.isEmpty ? '—' : value!,
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// A row showing the current value of a choice; tapping opens a sheet that
/// lists every option. Replaces wrapping chips for pickers.
class SettingsChoiceRow<T> extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.icon,
    required this.label,
    required this.choices,
    required this.value,
    required this.onChanged,
    this.hint,
  });
  final IconData icon;
  final String label;
  final String? hint;
  final List<AppChoice<T>> choices;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = choices.where((c) => c.value == value).firstOrNull;
    return QuietTile(
      icon: icon,
      label: label,
      onTap: () async {
        final picked = await showSettingsChoice<T>(
          context,
          title: label,
          hint: hint,
          choices: choices,
          value: value,
        );
        if (picked != null && picked != value) onChanged(picked);
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              current?.label ?? '${value ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.unfold_more_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// Lists [choices] with the current one checked; resolves to the tapped
/// value, or null when dismissed.
///
/// Phones get a bottom sheet. Wider windows get a floating panel pinned to
/// the row that opened it, never a sheet.
Future<T?> showSettingsChoice<T>(
  BuildContext context, {
  required String title,
  required List<AppChoice<T>> choices,
  required T value,
  String? hint,
}) => showAppPicker<T>(
  context: context,
  anchor: context,
  maxWidth: 360,
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text(
                hint,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          for (final c in choices)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
              ),
              leading: c.icon == null ? null : Icon(c.icon),
              title: Text(
                c.label,
                style: TextStyle(
                  fontWeight: c.value == value
                      ? FontWeight.w800
                      : FontWeight.w600,
                ),
              ),
              subtitle: c.hint == null ? null : Text(c.hint!),
              trailing: c.value == value
                  ? Icon(Icons.check_rounded, color: scheme.primary)
                  : null,
              onTap: () => Navigator.of(context).pop(c.value),
            ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  },
);

/// Centred icon, title and message for a group with nothing to show.
class SettingsEmpty extends StatelessWidget {
  const SettingsEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });
  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: scheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.xs),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          if (message != null) ...[
            const SizedBox(height: 2),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Spinner row shown while a group's data loads.
class SettingsLoading extends StatelessWidget {
  const SettingsLoading({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
    child: Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

/// A load failure in place, with a retry.
class SettingsError extends StatelessWidget {
  const SettingsError(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final danger = AppColors.dangerOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: SoftCard(
        radius: AppShape.card,
        showOrb: false,
        accent: danger,
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: danger),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 13.5, height: 1.35),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// A coloured pill for a status such as "Verified" or "This device".
class SettingsPill extends StatelessWidget {
  const SettingsPill(this.label, {super.key, this.color, this.icon});
  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) =>
      SoftMetaChip(label: label, icon: icon, accent: color);
}

// ---------------------------------------------------------------- refresh

/// Lets embedded panels hook into the settings page's pull-to-refresh (and
/// the refresh button on wide layouts) without owning a scroll view.
class SettingsRefreshRegistry {
  final _callbacks = <Future<void> Function()>[];

  void add(Future<void> Function() callback) => _callbacks.add(callback);
  void remove(Future<void> Function() callback) => _callbacks.remove(callback);

  /// Reloads every registered panel.
  Future<void> refreshAll() =>
      Future.wait([for (final c in List.of(_callbacks)) c()]);

  bool get isEmpty => _callbacks.isEmpty;
}

class SettingsRefreshScope extends InheritedWidget {
  const SettingsRefreshScope({
    super.key,
    required this.registry,
    required super.child,
  });
  final SettingsRefreshRegistry registry;

  static SettingsRefreshRegistry? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<SettingsRefreshScope>()
      ?.registry;

  @override
  bool updateShouldNotify(SettingsRefreshScope old) => registry != old.registry;
}

/// Registers [onRefresh] with the surrounding [SettingsRefreshScope] for as
/// long as it is mounted. Outside settings it does nothing.
class SettingsRefreshHook extends StatefulWidget {
  const SettingsRefreshHook({
    super.key,
    required this.onRefresh,
    required this.child,
  });
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<SettingsRefreshHook> createState() => _SettingsRefreshHookState();
}

class _SettingsRefreshHookState extends State<SettingsRefreshHook> {
  SettingsRefreshRegistry? _registry;
  late Future<void> Function() _callback;

  Future<void> _run() => _callback();

  @override
  void initState() {
    super.initState();
    _callback = widget.onRefresh;
    _registry = SettingsRefreshScope.maybeOf(context)?..add(_run);
  }

  @override
  void didUpdateWidget(SettingsRefreshHook old) {
    super.didUpdateWidget(old);
    _callback = widget.onRefresh;
  }

  @override
  void dispose() {
    _registry?.remove(_run);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
