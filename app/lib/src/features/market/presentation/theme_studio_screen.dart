import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/default_theme_packs.dart';
import '../../../core/theme/design_language.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/theme_pack.dart';
import '../../../core/theme/theme_pack_controller.dart';
import '../../../core/theme/theme_ui_spec.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/sky_ui.dart';

Future<void> showThemeStudio(
  BuildContext context,
  AppDependencies dependencies,
) =>
    showFloatingPanel(
      context,
      ThemeStudioScreen(dependencies: dependencies),
      maxWidth: 880,
    );

/// Professional theme authoring: design-language presets, live control
/// preview, structured recipe tweaks, and advanced JSON for full packs.
class ThemeStudioScreen extends StatefulWidget {
  const ThemeStudioScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<ThemeStudioScreen> createState() => _ThemeStudioScreenState();
}

class _ThemeStudioScreenState extends State<ThemeStudioScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _json;
  late final TabController _tabs;
  ThemePack _draft = DefaultThemePacks.sky;
  String _baseId = DefaultThemePacks.skyId;
  String? _error;
  bool _busy = false;
  bool _publish = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _name = TextEditingController(text: 'My theme');
    _description = TextEditingController(text: _draft.meta.description);
    _json = TextEditingController(text: _encode(_draft));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _name.dispose();
    _description.dispose();
    _json.dispose();
    super.dispose();
  }

  String _encode(ThemePack pack) =>
      const JsonEncoder.withIndent('  ').convert(pack.toJson());

  void _setDraft(ThemePack pack, {bool syncJson = true}) {
    setState(() {
      _draft = pack;
      _error = null;
      if (syncJson) _json.text = _encode(pack);
    });
  }

  void _loadBase(String id) {
    final pack = DefaultThemePacks.byId(id);
    _baseId = id;
    _description.text = pack.meta.description;
    _setDraft(pack.copyWith(
      meta: ThemePackMeta(
        id: 'user.${DateTime.now().millisecondsSinceEpoch}',
        name: _name.text.trim().isEmpty ? pack.meta.name : _name.text.trim(),
        description: _description.text.trim(),
        author: 'you',
        previewColors: pack.meta.previewColors,
      ),
    ));
  }

  void _applyLanguage(DesignLanguage language) {
    final tokens = _draft.tokens;
    // Align key radii with the language so Material/Fluent/Neo-brutal read
    // correctly without forcing authors to hand-edit every token.
    final cardR = language.card.radius;
    final controlR = language.input.radius;
    final fabR = language.fab.radius;
    ThemeTokens align(ThemeTokens t) => ThemeTokens(
          accent: t.accent,
          secondaryAccent: t.secondaryAccent,
          scaffold: t.scaffold,
          surface: t.surface,
          surfaceHigh: t.surfaceHigh,
          inputFill: t.inputFill,
          success: t.success,
          warning: t.warning,
          danger: t.danger,
          cardAlpha: language.card.fill == FillKind.glass ? t.cardAlpha : 0.98,
          overlayAlpha:
              language.sheet.fill == FillKind.glass ? t.overlayAlpha : 0.98,
          blurSigma: language.card.fill == FillKind.glass ? t.blurSigma : 0,
          barrier: t.barrier,
          radiusCard: cardR,
          radiusInner: language.panelHeader.radius,
          radiusControl: controlR,
          radiusFab: fabR.clamp(0, 999),
          radiusFabSmall: fabR.clamp(0, 999) * .75,
          radiusFabLarge: fabR.clamp(0, 999) == 999 ? 999 : fabR * 1.4,
          density: language.id == DesignLanguage.denseModern ||
                  language.id == DesignLanguage.fluent
              ? -1
              : t.density,
          spacingScale: t.spacingScale,
          titleWeight: t.titleWeight,
          labelWeight: t.labelWeight,
          letterSpacingDisplay: t.letterSpacingDisplay,
          letterSpacingTitle: t.letterSpacingTitle,
          fontFamily: t.fontFamily,
          motionScale: t.motionScale,
          reduceMotion: t.reduceMotion,
          fabMistAlpha: t.fabMistAlpha,
          navHeight: language.controlHeight + 18,
        );
    _setDraft(_draft.copyWith(
      language: language,
      tokens: ThemeTokenSet(
        light: align(tokens.light),
        dark: align(tokens.dark),
      ),
    ));
  }

  ThemePack? _namedDraft() {
    final err = _draft.validate();
    if (err != null) {
      setState(() => _error = err);
      return null;
    }
    return _draft.copyWith(
      meta: ThemePackMeta(
        id: _draft.meta.id.startsWith('builtin.')
            ? 'user.${DateTime.now().millisecondsSinceEpoch}'
            : _draft.meta.id,
        name: _name.text.trim().isEmpty ? _draft.meta.name : _name.text.trim(),
        description: _description.text.trim(),
        author: _draft.meta.author.isEmpty ? 'you' : _draft.meta.author,
        previewColors: _draft.meta.previewColors,
      ),
    );
  }

  Future<void> _preview() async {
    final pack = _namedDraft();
    if (pack == null) return;
    await ThemePackScope.of(context).apply(pack);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Preview: ${pack.language.label} · ${pack.meta.name}')),
    );
  }

  Future<void> _save() async {
    // If Advanced JSON is open, prefer its contents.
    if (_tabs.index == 2) {
      try {
        final parsed = ThemePack.decode(_json.text);
        final err = parsed.validate();
        if (err != null) {
          setState(() => _error = err);
          return;
        }
        _draft = parsed;
      } catch (e) {
        setState(() => _error = e.toString());
        return;
      }
    }
    final pack = _namedDraft();
    if (pack == null) return;
    setState(() => _busy = true);
    try {
      final created = await widget.dependencies.service.createTheme(
        name: pack.meta.name,
        description: pack.meta.description,
        packJson: pack.encode(),
        publish: _publish,
      );
      await ThemePackScope.of(context).apply(
        pack,
        listing: created.listingId,
        botId: created.themeId,
      );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _syncJsonIntoDraft() {
    try {
      final parsed = ThemePack.decode(_json.text);
      final err = parsed.validate();
      if (err != null) {
        setState(() => _error = err);
        return;
      }
      _setDraft(parsed, syncJson: false);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                SkyIconBadge(
                  icon: Icons.design_services_rounded,
                  accent: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Theme Studio',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        'Design languages · control recipes · shell layout',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Language'), icon: Icon(Icons.auto_awesome_rounded)),
                ButtonSegment(value: 1, label: Text('Controls'), icon: Icon(Icons.widgets_outlined)),
                ButtonSegment(value: 2, label: Text('JSON'), icon: Icon(Icons.data_object_rounded)),
              ],
              selected: {_tabs.index},
              onSelectionChanged: (v) {
                _tabs.index = v.first;
                setState(() {});
              },
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              children: [
                const AppFieldLabel('Name'),
                TextField(controller: _name),
                const SizedBox(height: AppSpacing.sm),
                const AppFieldLabel('Description'),
                TextField(controller: _description, maxLines: 2),
                const SizedBox(height: AppSpacing.md),
                if (_tabs.index == 0) ..._languageTab(scheme),
                if (_tabs.index == 1) ..._controlsTab(scheme),
                if (_tabs.index == 2) ..._jsonTab(scheme),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: AppSpacing.md),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Publish to Store'),
                  subtitle: const Text('Submit for marketplace review'),
                  trailing: PackSwitch(
                    value: _publish,
                    onChanged: (v) => setState(() => _publish = v),
                  ),
                  onTap: () => setState(() => _publish = !_publish),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : _preview,
                      child: const Text('Preview on device'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text(_busy ? 'Saving…' : 'Save theme'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _languageTab(ColorScheme scheme) => [
        const AppFieldLabel('Start from builtin'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final pack in DefaultThemePacks.all)
              ChoiceChip(
                label: Text(pack.meta.name),
                selected: _baseId == pack.id,
                onSelected: (_) => _loadBase(pack.id),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const AppFieldLabel('Design language'),
        Text(
          'Presets reshape buttons, chips, inputs, cards, sheets, FABs and menus. Pick Custom to keep recipes and edit them in Controls.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final lang in DesignLanguage.presets)
              FilterChip(
                label: Text(lang.label),
                selected: _draft.language.id == lang.id,
                onSelected: (_) => _applyLanguage(lang),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const AppFieldLabel('Part colours'),
        Text(
          'By default one Settings accent colours every decorative UI part. '
          'Turn off Unified accent to give nav, feed, desk, and others their '
          'own accents. Status colours (success / warning / danger) stay '
          'semantic either way.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Unified accent'),
          subtitle: Text(
            _draft.parts.unified
                ? 'All coloured parts share the selected palette accent'
                : 'Per-part overrides are active',
          ),
          trailing: PackSwitch(
            value: _draft.parts.unified,
            onChanged: (v) => _setDraft(
              _draft.copyWith(
                parts: _draft.parts.copyWith(
                  unified: v,
                  overrides: v ? const {} : _draft.parts.overrides,
                ),
              ),
            ),
          ),
          onTap: () => _setDraft(
            _draft.copyWith(
              parts: _draft.parts.copyWith(
                unified: !_draft.parts.unified,
                overrides: !_draft.parts.unified
                    ? const {}
                    : _draft.parts.overrides,
              ),
            ),
          ),
        ),
        if (!_draft.parts.unified) ...[
          const SizedBox(height: AppSpacing.sm),
          for (final part in ThemePartId.values)
            _PartAccentRow(
              part: part,
              color: _draft.parts.overrides[part]?.accent,
              fallback: _draft.defaultPalette.accent,
              onChanged: (color) {
                final next = Map<ThemePartId, ThemePartColor>.from(
                  _draft.parts.overrides,
                );
                if (color == null) {
                  next.remove(part);
                } else {
                  next[part] = ThemePartColor(accent: color);
                }
                _setDraft(
                  _draft.copyWith(
                    parts: _draft.parts.copyWith(
                      unified: false,
                      overrides: next,
                    ),
                  ),
                );
              },
            ),
        ],
        const SizedBox(height: AppSpacing.lg),
        const AppFieldLabel('UI composition'),
        Text(
          'Disable built-in shell / chrome slots or attach Elpian panels '
          '(replace, before, after, wrap). Live programs use `code` / '
          '`program` with `Aseman.api(ns, action, body)` against the core '
          'client. New sections go in `ui.islands` (home tabs, profile, '
          'pages). Wrap trees may embed the built-in via `ThemeHostChild`.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SoftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Disabled slots',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final slot in [
                    ...FeatureSlots.known,
                    ...ThemeChromeSlots.known,
                  ])
                    FilterChip(
                      label: Text(slot),
                      selected: _draft.ui.disabled.contains(slot),
                      onSelected: (on) {
                        final next = {..._draft.ui.disabled};
                        if (on) {
                          next.add(slot);
                        } else {
                          next.remove(slot);
                        }
                        _setDraft(
                          _draft.copyWith(
                            ui: _draft.ui.copyWith(disabled: next),
                          ),
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Elpian panel on home.you (example)',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: AppSpacing.sm),
              PackSwitch(
                value: _draft.ui.surfaces.containsKey(FeatureSlots.homeYou),
                onChanged: (on) {
                  final surfaces =
                      Map<String, ThemeSurfaceSpec>.from(_draft.ui.surfaces);
                  if (on) {
                    surfaces[FeatureSlots.homeYou] = ThemeSurfaceSpec(
                      slot: FeatureSlots.homeYou,
                      mode: ThemeSurfaceMode.after,
                      elpian: ThemeElpianSource(
                        inline: {
                          'type': 'Container',
                          'props': {
                            'className': 'panel-card',
                            'padding': 12,
                          },
                          'children': [
                            {
                              'type': 'Text',
                              'props': {
                                'text': 'Theme Elpian panel',
                                'className': 'primary',
                              },
                            },
                          ],
                        },
                      ),
                    );
                  } else {
                    surfaces.remove(FeatureSlots.homeYou);
                  }
                  _setDraft(
                    _draft.copyWith(ui: _draft.ui.copyWith(surfaces: surfaces)),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const AppFieldLabel('Live preview'),
        _LanguagePreview(pack: _draft),
      ];

  List<Widget> _controlsTab(ColorScheme scheme) => [
        const AppFieldLabel('Button recipe'),
        _RecipeEditor(
          recipe: _draft.language.button,
          onChanged: (r) => _setDraft(_draft.copyWith(
            language: _draft.language.copyWith(
              id: DesignLanguage.custom,
              label: 'Custom',
              button: r,
            ),
          )),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppFieldLabel('Card recipe'),
        _RecipeEditor(
          recipe: _draft.language.card,
          onChanged: (r) => _setDraft(_draft.copyWith(
            language: _draft.language.copyWith(
              id: DesignLanguage.custom,
              label: 'Custom',
              card: r,
            ),
          )),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppFieldLabel('Toggle recipe'),
        _RecipeEditor(
          recipe: _draft.language.toggle,
          onChanged: (r) => _setDraft(_draft.copyWith(
            language: _draft.language.copyWith(
              id: DesignLanguage.custom,
              label: 'Custom',
              toggle: r,
            ),
          )),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppFieldLabel('FAB recipe'),
        _RecipeEditor(
          recipe: _draft.language.fab,
          onChanged: (r) => _setDraft(_draft.copyWith(
            language: _draft.language.copyWith(
              id: DesignLanguage.custom,
              label: 'Custom',
              fab: r,
            ),
          )),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppFieldLabel('Input recipe'),
        _RecipeEditor(
          recipe: _draft.language.input,
          onChanged: (r) => _setDraft(_draft.copyWith(
            language: _draft.language.copyWith(
              id: DesignLanguage.custom,
              label: 'Custom',
              input: r,
            ),
          )),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppFieldLabel('Chat bubble recipe'),
        _RecipeEditor(
          recipe: _draft.language.chatBubble,
          onChanged: (r) => _setDraft(_draft.copyWith(
            language: _draft.language.copyWith(
              id: DesignLanguage.custom,
              label: 'Custom',
              chatBubble: r,
            ),
          )),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Tip: use the JSON tab for full richness — gradients, per-state '
          'hovered/pressed/selected styles, typography, iconography, extras '
          'slots, and global graphics (grain/sheen/vignette).',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _LanguagePreview(pack: _draft),
      ];

  List<Widget> _jsonTab(ColorScheme scheme) => [
        const AppFieldLabel('aseman.theme/v1 JSON'),
        TextField(
          controller: _json,
          maxLines: 18,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
          ),
          onChanged: (_) {},
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _syncJsonIntoDraft,
            icon: const Icon(Icons.sync_rounded),
            label: const Text('Apply JSON to draft'),
          ),
        ),
      ];
}

class _LanguagePreview extends StatelessWidget {
  const _LanguagePreview({required this.pack});

  final ThemePack pack;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.fromPack(pack, Theme.of(context).brightness);
    return Theme(
      data: theme,
      child: SoftCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${pack.language.label} · ${pack.meta.name}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(onPressed: () {}, child: const Text('Primary')),
                OutlinedButton(onPressed: () {}, child: const Text('Outline')),
                TextButton(onPressed: () {}, child: const Text('Text')),
                const Chip(label: Text('Chip')),
                SkyFab(onPressed: () {}, icon: Icons.add_rounded, mini: true),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const TextField(
              decoration: InputDecoration(
                labelText: 'Input field',
                hintText: 'Typed in this language',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SoftCard(
              child: Text(
                'Card / panel chrome follows the language fill, radius and border.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _PreviewToggles(),
            const SizedBox(height: AppSpacing.sm),
            Slider(value: .45, onChanged: (_) {}),
          ],
        ),
      ),
    );
  }
}

class _PreviewToggles extends StatefulWidget {
  const _PreviewToggles();

  @override
  State<_PreviewToggles> createState() => _PreviewTogglesState();
}

class _PreviewTogglesState extends State<_PreviewToggles> {
  bool _on = true;
  bool _check = true;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PackSwitch(
          value: _on,
          onChanged: (v) => setState(() => _on = v),
          showIcons: true,
        ),
        Checkbox(
          value: _check,
          onChanged: (v) => setState(() => _check = v ?? false),
        ),
        RadioGroup<bool>(
          groupValue: _check,
          onChanged: (v) => setState(() => _check = v ?? false),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Radio<bool>(value: true),
              Radio<bool>(value: false),
            ],
          ),
        ),
      ],
    );
  }
}

class _PartAccentRow extends StatelessWidget {
  const _PartAccentRow({
    required this.part,
    required this.color,
    required this.fallback,
    required this.onChanged,
  });

  final ThemePartId part;
  final Color? color;
  final Color fallback;
  final ValueChanged<Color?> onChanged;

  static const _presets = [
    Color(0xFF8B7BFF),
    Color(0xFF58D7FF),
    Color(0xFF43D39E),
    Color(0xFFFFB648),
    Color(0xFFFF6B79),
    Color(0xFF2A78D6),
    Color(0xFF0D9488),
    Color(0xFF64748B),
  ];

  Future<void> _editHex(BuildContext context) async {
    final controller = TextEditingController(
      text: colorToHex(color ?? fallback),
    );
    final result = await showDialog<Color?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${part.label} accent'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Hex colour',
            hintText: '#RRGGBB',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = parseColor(controller.text.trim());
              Navigator.pop(context, parsed ?? color ?? fallback);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null && color != null) {
      onChanged(null);
    } else if (result != null) {
      onChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = color ?? fallback;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.sm,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: current,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    part.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (color != null)
                  TextButton(
                    onPressed: () => onChanged(null),
                    child: const Text('Reset'),
                  ),
                TextButton(
                  onPressed: () => _editHex(context),
                  child: const Text('Hex'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in _presets)
                  InkWell(
                    onTap: () => onChanged(preset),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: preset,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: current.toARGB32() == preset.toARGB32()
                              ? scheme.onSurface
                              : scheme.outlineVariant,
                          width: current.toARGB32() == preset.toARGB32()
                              ? 2
                              : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (color == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Using palette accent',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecipeEditor extends StatelessWidget {
  const _RecipeEditor({required this.recipe, required this.onChanged});

  final ControlRecipe recipe;
  final ValueChanged<ControlRecipe> onChanged;

  @override
  Widget build(BuildContext context) {
    return SoftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final shape in ShapeKind.values)
                ChoiceChip(
                  label: Text(shape.name),
                  selected: recipe.shape == shape,
                  onSelected: (_) => onChanged(recipe.copyWith(shape: shape)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final fill in FillKind.values)
                ChoiceChip(
                  label: Text(fill.name),
                  selected: recipe.fill == fill,
                  onSelected: (_) => onChanged(recipe.copyWith(fill: fill)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Radius ${recipe.radius.toStringAsFixed(0)}'),
          Slider(
            value: recipe.radius.clamp(0, 48),
            max: 48,
            onChanged: (v) => onChanged(recipe.copyWith(radius: v)),
          ),
          Text('Border ${recipe.borderWidth.toStringAsFixed(0)}'),
          Slider(
            value: recipe.borderWidth.clamp(0, 4),
            max: 4,
            divisions: 8,
            onChanged: (v) => onChanged(recipe.copyWith(borderWidth: v)),
          ),
          Text('Elevation ${recipe.elevation.toStringAsFixed(0)}'),
          Slider(
            value: recipe.elevation.clamp(0, 12),
            max: 12,
            divisions: 12,
            onChanged: (v) => onChanged(recipe.copyWith(elevation: v)),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Ink',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              for (final ink in InkKind.values)
                ChoiceChip(
                  label: Text(ink.name),
                  selected: recipe.ink == ink,
                  onSelected: (_) => onChanged(recipe.copyWith(ink: ink)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Motion · press ${recipe.motion.pressScale.toStringAsFixed(2)} · '
            '${recipe.motion.durationMs}ms',
          ),
          Slider(
            value: recipe.motion.pressScale.clamp(0.85, 1.0),
            min: 0.85,
            max: 1,
            onChanged: (v) => onChanged(
              recipe.copyWith(
                motion: recipe.motion.copyWith(pressScale: v),
              ),
            ),
          ),
          Text('Glow ${recipe.effects.glow.toStringAsFixed(0)}'),
          Slider(
            value: recipe.effects.glow.clamp(0, 32),
            max: 32,
            onChanged: (v) => onChanged(
              recipe.copyWith(
                effects: recipe.effects.copyWith(glow: v),
              ),
            ),
          ),
          Text('Sheen ${recipe.effects.sheen.toStringAsFixed(2)}'),
          Slider(
            value: recipe.effects.sheen.clamp(0, 1),
            max: 1,
            onChanged: (v) => onChanged(
              recipe.copyWith(
                effects: recipe.effects.copyWith(sheen: v),
              ),
            ),
          ),
          Text('Opacity ${recipe.effects.opacity.toStringAsFixed(2)}'),
          Slider(
            value: recipe.effects.opacity.clamp(0.2, 1),
            min: 0.2,
            max: 1,
            onChanged: (v) => onChanged(
              recipe.copyWith(
                effects: recipe.effects.copyWith(opacity: v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
