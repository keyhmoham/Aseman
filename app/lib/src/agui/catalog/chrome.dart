/// Navigation, chrome, forms, chat-inline and motion components for the
/// Aseman Surface Spec catalog.
library;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'item.dart';
import 'style.dart';

final List<CatalogItem> chromeItems = [
  appBarItem,
  navigationRailItem,
  drawerItem,
  bottomNavItem,
  breadcrumbItem,
  commandPaletteItem,
  fabItem,
  sidebarItem,
  formItem,
  formFieldItem,
  autocompleteItem,
  chipInputItem,
  colorPickerItem,
  filePickerItem,
  codeEditorItem,
  richTextEditorItem,
  tagInputItem,
  chatCardItem,
  inlinePanelItem,
  confirmBarItem,
  suggestionChipsItem,
  animatedVisibilityItem,
  sharedAxisItem,
  heroItem,
];

final appBarItem = asemanItem(
  'AppBar',
  description: 'Top app bar: title, optional leading and actions.',
  properties: {
    'title': P.any('Title text.'),
    'leading': P.child('Optional leading control id.'),
    'actions': P.children('Trailing action component ids.'),
    'subtitle': P.any('Optional subtitle.'),
  },
  build: (item, p) => AppBar(
    title: Text(stringify(p['title'])),
    leading: p['leading'] != null ? item.child(p['leading']) : null,
    actions: [
      for (final id in item.childIds(p['actions'])) item.child(id),
    ],
    bottom: p['subtitle'] != null
        ? PreferredSize(
            preferredSize: const Size.fromHeight(28),
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(stringify(p['subtitle']),
                    style: agUiTextStyle(item.buildContext, 'caption')),
              ),
            ),
          )
        : null,
  ),
);

final navigationRailItem = asemanItem(
  'NavigationRail',
  description: 'Side navigation rail with destinations.',
  properties: {
    'destinations': P.any('[{label, icon?, value}]'),
    'value': P.any('Selected value or {"path"}.'),
    'action': P.action(),
  },
  build: (item, p) {
    final dests = p['destinations'] is List ? p['destinations'] as List : const <Object>[];
    final selected = p['value'];
    var index = 0;
    for (var i = 0; i < dests.length; i++) {
      final d = dests[i];
      if (d is Map && d['value'] == selected) index = i;
    }
    return NavigationRail(
      selectedIndex: dests.isEmpty ? 0 : index.clamp(0, dests.length - 1),
      onDestinationSelected: (i) {
        if (i < 0 || i >= dests.length) return;
        final d = dests[i];
        if (d is Map) {
          item.write(item.raw['value'], d['value']);
          item.fire(item.raw['action'], extra: {'value': d['value']});
        }
      },
      destinations: [
        for (final d in dests)
          if (d is Map)
            NavigationRailDestination(
              icon: Icon(agUiIcon('${d['icon'] ?? 'circle'}')),
              label: Text(stringify(d['label'])),
            ),
      ],
    );
  },
);

final drawerItem = asemanItem(
  'Drawer',
  description: 'Side drawer with a child body.',
  properties: {
    'child': P.child(),
    'title': P.any('Optional header title.'),
  },
  required: ['child'],
  build: (item, p) => Drawer(
    child: ListView(
      padding: EdgeInsets.zero,
      children: [
        if (p['title'] != null)
          DrawerHeader(
            child: Text(stringify(p['title']),
                style: agUiTextStyle(item.buildContext, 'h4')),
          ),
        item.child(p['child']),
      ],
    ),
  ),
);

final bottomNavItem = asemanItem(
  'BottomNav',
  description: 'Bottom navigation bar.',
  properties: {
    'destinations': P.any('[{label, icon?, value}]'),
    'value': P.any('Selected value or {"path"}.'),
    'action': P.action(),
  },
  build: (item, p) {
    final dests = p['destinations'] is List ? p['destinations'] as List : const <Object>[];
    var index = 0;
    for (var i = 0; i < dests.length; i++) {
      final d = dests[i];
      if (d is Map && d['value'] == p['value']) index = i;
    }
    return NavigationBar(
      selectedIndex: dests.isEmpty ? 0 : index.clamp(0, dests.length - 1),
      onDestinationSelected: (i) {
        if (i < 0 || i >= dests.length) return;
        final d = dests[i];
        if (d is Map) {
          item.write(item.raw['value'], d['value']);
          item.fire(item.raw['action'], extra: {'value': d['value']});
        }
      },
      destinations: [
        for (final d in dests)
          if (d is Map)
            NavigationDestination(
              icon: Icon(agUiIcon('${d['icon'] ?? 'circle'}')),
              label: stringify(d['label']),
            ),
      ],
    );
  },
);

final breadcrumbItem = asemanItem(
  'Breadcrumb',
  description: 'Breadcrumb trail of links.',
  properties: {
    'items': P.any('[{label, action?}]'),
  },
  build: (item, p) {
    final items = p['items'] is List ? p['items'] as List : const <Object>[];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('/', style: agUiTextStyle(item.buildContext, 'caption')),
            ),
          Builder(builder: (context) {
            final it = items[i];
            if (it is! Map) return const SizedBox.shrink();
            final label = stringify(it['label']);
            if (it['action'] != null) {
              return TextButton(
                onPressed: () => item.fire(it['action']),
                child: Text(label),
              );
            }
            return Text(label, style: agUiTextStyle(context, 'body'));
          }),
        ],
      ],
    );
  },
);

final commandPaletteItem = asemanItem(
  'CommandPalette',
  description: 'Searchable command list.',
  properties: {
    'items': P.any('[{label, icon?, action, keywords?}]'),
    'placeholder': P.any('Search placeholder.'),
    'value': P.any('Filter text {"path"}.'),
  },
  build: (item, p) {
    final q = stringify(p['value']).toLowerCase();
    final items = p['items'] is List ? p['items'] as List : const <Object>[];
    final filtered = [
      for (final it in items)
        if (it is Map &&
            (q.isEmpty ||
                stringify(it['label']).toLowerCase().contains(q) ||
                stringify(it['keywords']).toLowerCase().contains(q)))
          it,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: InputDecoration(
            hintText: stringify(p['placeholder']).isEmpty
                ? 'Search commands…'
                : stringify(p['placeholder']),
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: (v) => item.write(item.raw['value'], v),
        ),
        for (final it in filtered)
          ListTile(
            leading: Icon(agUiIcon('${it['icon'] ?? 'bolt'}')),
            title: Text(stringify(it['label'])),
            onTap: () => item.fire(it['action']),
          ),
      ],
    );
  },
);

final fabItem = asemanItem(
  'FAB',
  description: 'Floating action button.',
  properties: {
    'icon': P.any('Material icon name.'),
    'label': P.any('Optional extended label.'),
    'action': P.action(),
  },
  build: (item, p) {
    final label = stringify(p['label']);
    if (label.isNotEmpty) {
      return FloatingActionButton.extended(
        onPressed: () => item.fire(item.raw['action']),
        icon: Icon(agUiIcon('${p['icon'] ?? 'add'}')),
        label: Text(label),
      );
    }
    return FloatingActionButton(
      onPressed: () => item.fire(item.raw['action']),
      child: Icon(agUiIcon('${p['icon'] ?? 'add'}')),
    );
  },
);

final sidebarItem = asemanItem(
  'Sidebar',
  description: 'Persistent sidebar with a child body.',
  properties: {
    'child': P.child(),
    'width': P.any('Width in logical pixels.'),
  },
  required: ['child'],
  build: (item, p) => SizedBox(
    width: (p['width'] as num?)?.toDouble() ?? 240,
    child: item.child(p['child']),
  ),
);

final formItem = asemanItem(
  'Form',
  description: 'Form container; child fields; submit action.',
  properties: {
    'children': P.children(),
    'title': P.any('Optional title.'),
    'action': P.action('Submit action.'),
    'submitLabel': P.any('Submit button label.'),
  },
  build: (item, p) => item.children(
    p['children'],
    (kids) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (p['title'] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(stringify(p['title']),
                style: agUiTextStyle(item.buildContext, 'h4')),
          ),
        ...kids,
        if (item.raw['action'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton(
              onPressed: () => item.fire(item.raw['action']),
              child: Text(stringify(p['submitLabel']).isEmpty
                  ? 'Submit'
                  : stringify(p['submitLabel'])),
            ),
          ),
      ],
    ),
  ),
);

final formFieldItem = asemanItem(
  'FormField',
  description: 'Labeled field wrapper around a child input.',
  properties: {
    'label': P.any('Field label.'),
    'child': P.child(),
    'helper': P.any('Helper text.'),
    'required': P.any('Whether required.'),
  },
  required: ['child'],
  build: (item, p) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (p['label'] != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            stringify(p['label']) + (p['required'] == true ? ' *' : ''),
            style: agUiTextStyle(item.buildContext, 'caption'),
          ),
        ),
      item.child(p['child']),
      if (p['helper'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(stringify(p['helper']),
              style: agUiTextStyle(item.buildContext, 'caption')),
        ),
    ],
  ),
);

final autocompleteItem = asemanItem(
  'Autocomplete',
  description: 'Text field with suggestion options.',
  properties: {
    'options': P.any('[string] or [{label, value}]'),
    'value': P.any('{"path"} binding.'),
    'label': P.any('Label.'),
    'action': P.action(),
  },
  build: (item, p) {
    final options = <String>[];
    if (p['options'] is List) {
      for (final o in p['options'] as List) {
        if (o is String) {
          options.add(o);
        } else if (o is Map) {
          options.add(stringify(o['label'] ?? o['value']));
        }
      }
    }
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: stringify(p['value'])),
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        if (q.isEmpty) return options;
        return options.where((o) => o.toLowerCase().contains(q));
      },
      onSelected: (v) {
        item.write(item.raw['value'], v);
        item.fire(item.raw['action'], extra: {'value': v});
      },
      fieldViewBuilder: (context, controller, focus, onSubmit) {
        return TextField(
          controller: controller,
          focusNode: focus,
          decoration: InputDecoration(labelText: stringify(p['label'])),
          onSubmitted: (_) => onSubmit(),
          onChanged: (v) => item.write(item.raw['value'], v),
        );
      },
    );
  },
);

final chipInputItem = asemanItem(
  'ChipInput',
  description: 'Multi-value chip input bound to a list path.',
  properties: {
    'value': P.any('List {"path"}.'),
    'label': P.any('Label.'),
    'action': P.action(),
  },
  build: (item, p) {
    final values = p['value'] is List
        ? [for (final v in p['value'] as List) stringify(v)]
        : <String>[];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < values.length; i++)
          InputChip(
            label: Text(values[i]),
            onDeleted: () {
              final next = [...values]..removeAt(i);
              item.write(item.raw['value'], next);
              item.fire(item.raw['action'], extra: {'value': next});
            },
          ),
        SizedBox(
          width: 120,
          child: TextField(
            decoration: InputDecoration(
              labelText: stringify(p['label']).isEmpty
                  ? 'Add'
                  : stringify(p['label']),
              isDense: true,
            ),
            onSubmitted: (v) {
              if (v.trim().isEmpty) return;
              final next = [...values, v.trim()];
              item.write(item.raw['value'], next);
              item.fire(item.raw['action'], extra: {'value': next});
            },
          ),
        ),
      ],
    );
  },
);

final colorPickerItem = asemanItem(
  'ColorPicker',
  description: 'Simple palette color picker (#hex).',
  properties: {
    'value': P.any('{"path"} to #hex.'),
    'swatches': P.any('Optional list of #hex colors.'),
    'action': P.action(),
  },
  build: (item, p) {
    final swatches = p['swatches'] is List
        ? [for (final s in p['swatches'] as List) stringify(s)]
        : const [
            '#2563EB',
            '#F59E0B',
            '#10B981',
            '#EF4444',
            '#8B5CF6',
            '#64748B',
          ];
    final current = stringify(p['value']);
    return Wrap(
      spacing: 8,
      children: [
        for (final hex in swatches)
          GestureDetector(
            onTap: () {
              item.write(item.raw['value'], hex);
              item.fire(item.raw['action'], extra: {'value': hex});
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: agUiColor(item.buildContext, hex) ?? Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: hex.toLowerCase() == current.toLowerCase()
                      ? Theme.of(item.buildContext).colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  },
);

final filePickerItem = asemanItem(
  'FilePicker',
  description: 'File pick trigger (fires action with intent).',
  properties: {
    'label': P.any('Button label.'),
    'action': P.action(),
    'accept': P.any('Accepted kinds hint.'),
  },
  build: (item, p) => OutlinedButton.icon(
    onPressed: () => item.fire(item.raw['action'], extra: {
      'accept': p['accept'],
      'pick': true,
    }),
    icon: const Icon(Icons.attach_file),
    label: Text(stringify(p['label']).isEmpty ? 'Choose file' : stringify(p['label'])),
  ),
);

final codeEditorItem = asemanItem(
  'CodeEditor',
  description: 'Monospace multi-line code editor bound to a path.',
  properties: {
    'value': P.any('{"path"}.'),
    'language': P.any('Language hint.'),
    'minLines': P.any('Minimum lines.'),
    'action': P.action(),
  },
  build: (item, p) => TextField(
    controller: TextEditingController(text: stringify(p['value']))
      ..selection = TextSelection.collapsed(offset: stringify(p['value']).length),
    maxLines: null,
    minLines: (p['minLines'] as num?)?.toInt() ?? 6,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    decoration: InputDecoration(
      border: const OutlineInputBorder(),
      hintText: p['language'] != null ? stringify(p['language']) : null,
    ),
    onChanged: (v) {
      item.write(item.raw['value'], v);
      item.fire(item.raw['action'], extra: {'value': v});
    },
  ),
);

final richTextEditorItem = asemanItem(
  'RichTextEditor',
  description: 'Multi-line rich text (Markdown) editor.',
  properties: {
    'value': P.any('{"path"}.'),
    'label': P.any('Label.'),
    'action': P.action(),
  },
  build: (item, p) => TextField(
    controller: TextEditingController(text: stringify(p['value'])),
    maxLines: null,
    minLines: 4,
    decoration: InputDecoration(
      labelText: stringify(p['label']),
      border: const OutlineInputBorder(),
      alignLabelWithHint: true,
    ),
    onChanged: (v) {
      item.write(item.raw['value'], v);
      item.fire(item.raw['action'], extra: {'value': v});
    },
  ),
);

final tagInputItem = asemanItem(
  'TagInput',
  description: 'Tag chips bound to a list path (same idea as ChipInput).',
  properties: {
    'value': P.any('List {"path"}.'),
    'label': P.any('Label.'),
    'action': P.action(),
  },
  build: (item, p) {
    final values = p['value'] is List
        ? [for (final v in p['value'] as List) stringify(v)]
        : <String>[];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < values.length; i++)
          InputChip(
            label: Text(values[i]),
            onDeleted: () {
              final next = [...values]..removeAt(i);
              item.write(item.raw['value'], next);
              item.fire(item.raw['action'], extra: {'value': next});
            },
          ),
        SizedBox(
          width: 120,
          child: TextField(
            decoration: InputDecoration(
              labelText: stringify(p['label']).isEmpty
                  ? 'Add tag'
                  : stringify(p['label']),
              isDense: true,
            ),
            onSubmitted: (v) {
              if (v.trim().isEmpty) return;
              final next = [...values, v.trim()];
              item.write(item.raw['value'], next);
              item.fire(item.raw['action'], extra: {'value': next});
            },
          ),
        ),
      ],
    );
  },
);

final chatCardItem = asemanItem(
  'ChatCard',
  description: 'Compact card for inline chat surfaces.',
  properties: {
    'child': P.child(),
    'title': P.any('Optional title.'),
  },
  required: ['child'],
  build: (item, p) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p['title'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(stringify(p['title']),
                  style: agUiTextStyle(item.buildContext, 'h5')),
            ),
          item.child(p['child']),
        ],
      ),
    ),
  ),
);

final inlinePanelItem = asemanItem(
  'InlinePanel',
  description: 'Borderless inline panel for chat or tight layouts.',
  properties: {
    'child': P.child(),
    'padding': P.any('Padding number.'),
  },
  required: ['child'],
  build: (item, p) => Padding(
    padding: EdgeInsets.all((p['padding'] as num?)?.toDouble() ?? 8),
    child: item.child(p['child']),
  ),
);

final confirmBarItem = asemanItem(
  'ConfirmBar',
  description: 'Confirm / cancel action bar for chat flows.',
  properties: {
    'confirmLabel': P.any('Confirm label.'),
    'cancelLabel': P.any('Cancel label.'),
    'confirmAction': P.action(),
    'cancelAction': P.action(),
    'message': P.any('Optional prompt text.'),
  },
  build: (item, p) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (p['message'] != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(stringify(p['message'])),
        ),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => item.fire(item.raw['cancelAction']),
              child: Text(stringify(p['cancelLabel']).isEmpty
                  ? 'Cancel'
                  : stringify(p['cancelLabel'])),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: () => item.fire(item.raw['confirmAction']),
              child: Text(stringify(p['confirmLabel']).isEmpty
                  ? 'Confirm'
                  : stringify(p['confirmLabel'])),
            ),
          ),
        ],
      ),
    ],
  ),
);

final suggestionChipsItem = asemanItem(
  'SuggestionChips',
  description: 'Horizontal suggestion chips that fire actions.',
  properties: {
    'items': P.any('[{label, action}]'),
  },
  build: (item, p) {
    final items = p['items'] is List ? p['items'] as List : const <Object>[];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final it in items)
          if (it is Map)
            ActionChip(
              label: Text(stringify(it['label'])),
              onPressed: () => item.fire(it['action']),
            ),
      ],
    );
  },
);

final animatedVisibilityItem = asemanItem(
  'AnimatedVisibility',
  description: 'Shows child with a fade when visible is true.',
  properties: {
    'visible': P.any('Boolean or {"path"}.'),
    'child': P.child(),
  },
  required: ['child'],
  build: (item, p) => AnimatedOpacity(
    opacity: p['visible'] == false ? 0 : 1,
    duration: const Duration(milliseconds: 200),
    child: IgnorePointer(
      ignoring: p['visible'] == false,
      child: item.child(p['child']),
    ),
  ),
);

final sharedAxisItem = asemanItem(
  'SharedAxis',
  description: 'Animated switch between children by index.',
  properties: {
    'children': P.children(),
    'index': P.any('Visible child index.'),
  },
  build: (item, p) {
    final ids = item.childIds(p['children']);
    final index = ((p['index'] as num?)?.toInt() ?? 0).clamp(0, ids.isEmpty ? 0 : ids.length - 1);
    if (ids.isEmpty) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(
        key: ValueKey(ids[index]),
        child: item.child(ids[index]),
      ),
    );
  },
);

final heroItem = asemanItem(
  'Hero',
  description: 'Flutter Hero flight wrapper.',
  properties: {
    'tag': P.any('Hero tag.'),
    'child': P.child(),
  },
  required: ['child', 'tag'],
  build: (item, p) => Hero(
    tag: stringify(p['tag']),
    child: item.child(p['child']),
  ),
);

String stringify(Object? v) => v == null ? '' : '$v';
