# Generative UI (genui)

Tradera renders every A2UI surface — tools' generated frontends, agents'
composed desk widgets (`ui_compose`) and the `A2UISurface` element of Elpian
mini apps — with Flutter's [genui](https://github.com/flutter/genui)
(A2UI v0.9) and one catalog in the app's design language.

| Directory | What it holds |
|---|---|
| `runtime/` | `GenUiSurfaces` (genui's `SurfaceController` over raw messages: creation order, `sendDataModel`, problems), message normalization (`v0.9.1`, `{{…}}`/`${…}` text, `.` paths), reactive value resolution (`Resolved`: bindings and calls at any depth), actions, client functions, `GenUiHost` |
| `catalog/` | `basic.dart` (the A2UI basic catalog, restyled), `tradera.dart` (UI-kit data views, layout, `Elpian`, `ToolFrontend`), `extended.dart` (new inputs, navigation, feedback, `Show`), `markets.dart` (`Quote`, `OrderBook`, `TickerTape`, `AllocationBar`, `Trend`), `catalog.dart` (`traderaCatalog`) |
| `widgets/` | `GenUiSurfaceView` (one surface: theme `primaryColor`, attribution, actions) and `GenUiView` (static messages + an action handler) |

The node (`services/pkg/a2ui`) knows the same component list, teaches it to
models with `CatalogPrompt` and rejects components the app cannot render; a
Go test checks the two lists match these sources.

## Writing a component

```dart
final myItem = traderaItem(
  'Thing',
  description: 'What it is, for agents.',
  properties: {'value': P.any('The value.'), 'action': P.action()},
  required: ['value'],
  build: (item, props) => Text('${props['value']}'), // props resolved, live
);
```

`props` arrive with every binding and function call resolved and kept
current. `item` gives the raw props (`item.raw`), children
(`item.child(id)`, `item.children(spec, layout)` — ids or a
`{componentId, path}` template), two-way binding (`item.write(binding,
value)`), actions (`item.fire(action, scope: …, extra: …)`) and row scopes
(`item.itemScope(binding, index)`). Add the item to its group's list and its
name to `services/pkg/a2ui/catalog.go` (with a line in `CatalogPrompt`).

## Behaviour kept from the previous renderer

genui's own basic functions and data model differ from the A2UI spec in a
few places; Tradera overrides them so stored surfaces render as before:
spec argument names for `formatNumber` / `formatCurrency` / `formatDate`,
a working `email` check, calls nested in list arguments (`and`'s
`values`), strict binding detection in action contexts, `userMessage` and
the v1.0 `{name, context}` action shorthand, `.`-relative paths, and
deleting an absent path as a no-op. `test/genui` runs the basic catalog's
43 examples and the A2UI conformance cases against this stack.
