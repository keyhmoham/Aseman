import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/theme_roles.dart';
import 'glass_surface.dart';
import 'overlay_panels.dart';

export '../../core/theme/app_shape.dart';

/// Input controls shared across the app. Each one picks a value by tapping
/// (chips, segments, sliders, switches) and keeps typing for what really is
/// free text: names, addresses, secrets.

/// A small heading above a group of controls.
class AppFieldLabel extends StatelessWidget {
  const AppFieldLabel(this.label, {super.key, this.hint, this.trailing});
  final String label;
  final String? hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) =>
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(hint!,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: scheme.onSurfaceVariant)),
              ],
            ]),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            // Never more than about half the row: long values shrink with
            // an ellipsis instead of overflowing or squeezing the label.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .55),
              child: trailing!,
            ),
          ],
        ]),
      ),
    );
  }
}

/// One option of a chip or segment picker.
class AppChoice<T> {
  const AppChoice(this.value, this.label, {this.icon, this.hint});
  final T value;
  final String label;
  final IconData? icon;
  final String? hint;
}

/// Pick one of a few options with chips that wrap onto new lines.
class AppChoiceField<T> extends StatelessWidget {
  const AppChoiceField({
    super.key,
    required this.label,
    required this.choices,
    required this.value,
    required this.onChanged,
    this.hint,
  });
  final String label;
  final String? hint;
  final List<AppChoice<T>> choices;
  final T? value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = choices.where((c) => c.value == value).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppFieldLabel(label, hint: hint),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final choice in choices)
          ChoiceChip(
            selected: choice.value == value,
            avatar: choice.icon == null
                ? null
                : Icon(choice.icon,
                    size: 18,
                    color: choice.value == value
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant),
            showCheckmark: choice.icon == null,
            label: Text(choice.label),
            onSelected: (_) => onChanged(choice.value),
          ),
      ]),
      if (selected?.hint != null) ...[
        const SizedBox(height: 8),
        Text(selected!.hint!,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    ]);
  }
}

/// Pick one of two to four options with a full-width segmented button.
class AppSegmentedField<T> extends StatelessWidget {
  const AppSegmentedField({
    super.key,
    required this.label,
    required this.choices,
    required this.value,
    required this.onChanged,
    this.hint,
  });
  final String label;
  final String? hint;
  final List<AppChoice<T>> choices;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = choices.where((c) => c.value == value).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppFieldLabel(label, hint: hint),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [
            for (final c in choices)
              ButtonSegment(
                  value: c.value,
                  label: Text(c.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  icon: c.icon == null ? null : Icon(c.icon, size: 18)),
          ],
          selected: {value},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
      ),
      if (selected?.hint != null) ...[
        const SizedBox(height: 8),
        Text(selected!.hint!,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    ]);
  }
}

/// A switch on a tonal surface, with an icon, title and explanation.
class AppSwitchCard extends StatelessWidget {
  const AppSwitchCard({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSurface(
      color: value ? ThemeRoles.selectedFill(context) : null,
      alpha: value ? .7 : null,
      borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(children: [
            if (icon != null) ...[
              Icon(icon,
                  color: value
                      ? ThemeRoles.selectedInk(context)
                      : scheme.onSurfaceVariant),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: scheme.onSurfaceVariant)),
                    ],
                  ]),
            ),
            const SizedBox(width: 10),
            Switch(
              value: value,
              onChanged: onChanged,
              thumbIcon: WidgetStateProperty.resolveWith((states) => Icon(
                  states.contains(WidgetState.selected)
                      ? Icons.check_rounded
                      : Icons.close_rounded)),
            ),
          ]),
        ),
    );
  }
}

/// Picks a number with a slider, − / + steps and preset chips. The value
/// itself is a button that opens exact entry for the rare precise figure.
class AppAmountField extends StatelessWidget {
  const AppAmountField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.format,
    this.hint,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.presets = const [],
    this.presetLabel,
    this.unit,
    this.decimals = 2,
  });

  final String label;
  final String? hint;
  final double value;
  final ValueChanged<double> onChanged;

  /// How the value is shown, e.g. `500 credits` or `$0.12 / min`.
  final String Function(double) format;
  final double min;
  final double max;
  final double step;
  final List<double> presets;

  /// Optional custom chip text for a preset (e.g. 0 → "Free").
  final String? Function(double)? presetLabel;

  /// Suffix shown in exact entry, e.g. `credits`.
  final String? unit;
  final int decimals;

  double _snap(double v) {
    final snapped = (v / step).round() * step;
    return double.parse(snapped.toStringAsFixed(decimals))
        .clamp(min, double.infinity);
  }

  Future<void> _exact(BuildContext context) async {
    final controller = TextEditingController(
        text: value == value.roundToDouble()
            ? value.round().toString()
            : value.toStringAsFixed(decimals));
    final result = await showAppDialog<double>(
      context: context,
      builder: (context) {
        void submit() {
          final parsed =
              double.tryParse(controller.text.trim().replaceAll(',', ''));
          if (parsed == null || parsed < min) return;
          Navigator.pop(context, parsed);
        }

        return AlertDialog(
          icon: const Icon(Icons.tune_rounded),
          title: Text(label),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
            ],
            onSubmitted: (_) => submit(),
            decoration:
                InputDecoration(labelText: 'Exact value', suffixText: unit),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Set')),
          ],
        );
      },
    );
    controller.dispose();
    if (result != null)
      onChanged(double.parse(result.toStringAsFixed(decimals)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = math.max(max, value);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppFieldLabel(
        label,
        hint: hint,
        trailing: Material(
          color: ThemeRoles.selectedFill(context),
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => _exact(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(format(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: ThemeRoles.selectedInk(context))),
                ),
                const SizedBox(width: 6),
                Icon(Icons.edit_rounded,
                    size: 15, color: ThemeRoles.selectedInk(context)),
              ]),
            ),
          ),
        ),
      ),
      Row(children: [
        IconButton.filledTonal(
          tooltip: 'Less',
          onPressed: value <= min ? null : () => onChanged(_snap(value - step)),
          icon: const Icon(Icons.remove_rounded),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, top),
            min: min,
            max: top,
            onChanged: (v) => onChanged(_snap(v)),
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'More',
          onPressed: () => onChanged(_snap(value + step)),
          icon: const Icon(Icons.add_rounded),
        ),
      ]),
      if (presets.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in presets)
            ChoiceChip(
              selected: (p - value).abs() < step / 2,
              label: Text(presetLabel?.call(p) ?? format(p)),
              onSelected: (_) => onChanged(p),
            ),
        ]),
      ],
    ]);
  }
}

/// Rows of name/value pairs (HTTP headers, environment variables).
class AppPairsEditor extends StatefulWidget {
  const AppPairsEditor({
    super.key,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.hint,
    this.keyHint = 'Name',
    this.valueHint = 'Value',
    this.obscureValues = false,
  });
  final String label;
  final String? hint;
  final Map<String, String> initial;
  final ValueChanged<Map<String, String>> onChanged;
  final String keyHint;
  final String valueHint;
  final bool obscureValues;

  @override
  State<AppPairsEditor> createState() => _AppPairsEditorState();
}

class _AppPairsEditorState extends State<AppPairsEditor> {
  final rows = <(TextEditingController, TextEditingController)>[];

  @override
  void initState() {
    super.initState();
    for (final e in widget.initial.entries) {
      rows.add((
        TextEditingController(text: e.key),
        TextEditingController(text: e.value)
      ));
    }
  }

  @override
  void dispose() {
    for (final (k, v) in rows) {
      k.dispose();
      v.dispose();
    }
    super.dispose();
  }

  void _emit() => widget.onChanged({
        for (final (k, v) in rows)
          if (k.text.trim().isNotEmpty) k.text.trim(): v.text,
      });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppFieldLabel(widget.label, hint: widget.hint),
      for (var i = 0; i < rows.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: rows[i].$1,
                onChanged: (_) => _emit(),
                decoration:
                    InputDecoration(isDense: true, hintText: widget.keyHint),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: rows[i].$2,
                obscureText: widget.obscureValues,
                onChanged: (_) => _emit(),
                decoration:
                    InputDecoration(isDense: true, hintText: widget.valueHint),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () {
                final (k, v) = rows.removeAt(i);
                k.dispose();
                v.dispose();
                setState(() {});
                _emit();
              },
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
          ]),
        ),
      TextButton.icon(
        onPressed: () => setState(
            () => rows.add((TextEditingController(), TextEditingController()))),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: Text('Add ${widget.keyHint.toLowerCase()}'),
      ),
    ]);
  }
}

/// A password entry with a generator, a copy button and a strength meter.
class AppPasswordField extends StatefulWidget {
  const AppPasswordField(
      {super.key, required this.controller, this.label = 'New password'});
  final TextEditingController controller;
  final String label;

  @override
  State<AppPasswordField> createState() => _AppPasswordFieldState();
}

class _AppPasswordFieldState extends State<AppPasswordField> {
  bool obscure = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _generate() {
    const chars =
        'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_!@#%';
    final random = math.Random.secure();
    widget.controller.text =
        List.generate(18, (_) => chars[random.nextInt(chars.length)]).join();
    setState(() => obscure = false);
  }

  static (double, String, Color) strength(String value, [BuildContext? context]) {
    var score = 0;
    if (value.length >= 8) score++;
    if (value.length >= 12) score++;
    if (value.length >= 16) score++;
    if (RegExp(r'[A-Z]').hasMatch(value) && RegExp(r'[a-z]').hasMatch(value)) {
      score++;
    }
    if (RegExp(r'[0-9]').hasMatch(value)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(value)) score++;
    if (value.isEmpty)
      return (0, 'Enter or generate a password', AppColors.muted);
    if (value.length < 8) {
      return (
        .15,
        'Too short',
        context != null ? AppColors.dangerOf(context) : AppColors.danger,
      );
    }
    if (score <= 3) {
      return (
        .45,
        'Fair',
        context != null ? AppColors.warningOf(context) : AppColors.warning,
      );
    }
    if (score <= 4) {
      return (
        .7,
        'Good',
        context != null ? AppColors.cyanOf(context) : AppColors.cyan,
      );
    }
    return (
      1,
      'Strong',
      context != null ? AppColors.successOf(context) : AppColors.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final (value, label, color) = strength(widget.controller.text, context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextFormField(
        controller: widget.controller,
        obscureText: obscure,
        autofillHints: const [AutofillHints.newPassword],
        validator: (v) =>
            (v ?? '').length < 8 ? 'Use at least 8 characters' : null,
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: const Icon(Icons.lock_outline_rounded),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: obscure ? 'Show' : 'Hide',
                onPressed: () => setState(() => obscure = !obscure),
                icon: Icon(obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined)),
            IconButton(
                tooltip: 'Copy',
                onPressed: widget.controller.text.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: widget.controller.text)),
                icon: const Icon(Icons.copy_rounded)),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      AppMeter(value: value, color: color, height: 6),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w700))),
        TextButton.icon(
            onPressed: _generate,
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Generate strong password')),
      ]),
    ]);
  }
}

/// When something lapses: never, after a preset period, or on a picked date.
class AppExpiryField extends StatelessWidget {
  const AppExpiryField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });
  final String label;
  final String? hint;

  /// null means never.
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final presets = {'7 days': 7, '30 days': 30, '90 days': 90};
    int? daysAway(DateTime d) =>
        (d.difference(DateTime(now.year, now.month, now.day)).inHours / 24)
            .round();
    final current = value == null ? null : daysAway(value!);
    final isPreset = current != null && presets.values.contains(current);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppFieldLabel(label, hint: hint),
      Wrap(spacing: 8, runSpacing: 8, children: [
        ChoiceChip(
          selected: value == null,
          avatar: const Icon(Icons.all_inclusive_rounded, size: 18),
          showCheckmark: false,
          label: const Text('Never'),
          onSelected: (_) => onChanged(null),
        ),
        for (final p in presets.entries)
          ChoiceChip(
            selected: current == p.value,
            label: Text(p.key),
            onSelected: (_) => onChanged(DateTime(now.year, now.month, now.day)
                .add(Duration(days: p.value))),
          ),
        ChoiceChip(
          selected: value != null && !isPreset,
          avatar: const Icon(Icons.event_rounded, size: 18),
          showCheckmark: false,
          label: Text(value != null && !isPreset
              ? MaterialLocalizations.of(context).formatMediumDate(value!)
              : 'Pick a date'),
          onSelected: (_) async {
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? now.add(const Duration(days: 14)),
              firstDate: now,
              lastDate: now.add(const Duration(days: 3650)),
            );
            if (picked != null) onChanged(picked);
          },
        ),
      ]),
      if (value != null) ...[
        const SizedBox(height: 8),
        Text(
            'Lapses on ${MaterialLocalizations.of(context).formatFullDate(value!)}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    ]);
  }
}

/// A destructive confirmation: the action button stays disabled until the
/// operator ticks that they understand.
class AppConfirmCheck extends StatelessWidget {
  const AppConfirmCheck(
      {super.key,
      required this.value,
      required this.onChanged,
      required this.label});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer.withValues(alpha: .45),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.innerOf(context))),
      clipBehavior: Clip.antiAlias,
      child: CheckboxListTile(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onErrorContainer)),
      ),
    );
  }
}

/// A thin rounded progress meter that animates to [value] (0–1).
class AppMeter extends StatelessWidget {
  const AppMeter({super.key, required this.value, this.color, this.height = 8});
  final double value;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.isFinite ? value.clamp(0.0, 1.0) : 0.0),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => LayoutBuilder(
        builder: (context, constraints) => Container(
          height: height,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(height),
          ),
          alignment: Alignment.centerLeft,
          child: Container(
            width: constraints.maxWidth * v,
            decoration: BoxDecoration(
              color: color ?? scheme.primary,
              borderRadius: BorderRadius.circular(height),
            ),
          ),
        ),
      ),
    );
  }
}

/// A list of short values entered one at a time and shown as removable
/// chips, instead of a comma-separated text box.
class AppTagsField extends StatefulWidget {
  const AppTagsField({
    super.key,
    required this.label,
    required this.values,
    required this.onChanged,
    this.hint,
    this.suggestions = const [],
  });
  final String label;
  final String? hint;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;

  /// Values offered as one-tap chips.
  final List<String> suggestions;

  @override
  State<AppTagsField> createState() => _AppTagsFieldState();
}

class _AppTagsFieldState extends State<AppTagsField> {
  final input = TextEditingController();

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void _add(String raw) {
    final next = [...widget.values];
    for (final part in raw.split(',')) {
      final value = part.trim();
      if (value.isNotEmpty && !next.contains(value)) next.add(value);
    }
    input.clear();
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final offered =
        widget.suggestions.where((s) => !widget.values.contains(s)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppFieldLabel(widget.label, hint: widget.hint),
      if (widget.values.isNotEmpty) ...[
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in widget.values)
            InputChip(
              label: Text(v),
              onDeleted: () => widget.onChanged([...widget.values]..remove(v)),
            ),
        ]),
        const SizedBox(height: 10),
      ],
      TextField(
        controller: input,
        onSubmitted: _add,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Type and press Enter',
          suffixIcon: IconButton(
              tooltip: 'Add',
              onPressed: () => _add(input.text),
              icon: const Icon(Icons.add_rounded)),
        ),
      ),
      if (offered.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in offered)
            ActionChip(
                avatar: const Icon(Icons.add_rounded, size: 16),
                label: Text(s),
                onPressed: () => _add(s)),
        ]),
      ],
    ]);
  }
}

/// A duration picked from common presets, in seconds.
class AppDurationField extends StatelessWidget {
  const AppDurationField({
    super.key,
    required this.label,
    required this.seconds,
    required this.onChanged,
    this.hint,
    this.presets = const [300, 900, 3600, 21600, 86400, 604800],
  });
  final String label;
  final String? hint;
  final int? seconds;
  final ValueChanged<int> onChanged;
  final List<int> presets;

  static String format(int seconds) {
    if (seconds % 604800 == 0) {
      final w = seconds ~/ 604800;
      return '$w week${w == 1 ? '' : 's'}';
    }
    if (seconds % 86400 == 0) {
      final d = seconds ~/ 86400;
      return '$d day${d == 1 ? '' : 's'}';
    }
    if (seconds % 3600 == 0) {
      final h = seconds ~/ 3600;
      return '$h hour${h == 1 ? '' : 's'}';
    }
    if (seconds % 60 == 0) return '${seconds ~/ 60} min';
    return '$seconds s';
  }

  @override
  Widget build(BuildContext context) {
    final options = <int>{...presets, if (seconds != null) seconds!}.toList()
      ..sort();
    return AppChoiceField<int>(
      label: label,
      hint: hint,
      value: seconds,
      onChanged: onChanged,
      choices: [for (final s in options) AppChoice(s, format(s))],
    );
  }
}
