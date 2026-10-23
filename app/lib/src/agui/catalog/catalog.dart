/// Aseman's AG-UI Surface Spec catalog: basic layout/content, Aseman data
/// views, extended inputs/nav/feedback, markets, chrome/forms/2D/3D, and
/// client functions — in the app's design language.
library;

import 'package:genui/genui.dart';

import '../protocol/events.dart' show asemanCatalogId;
import '../runtime/functions.dart';
import 'aseman.dart';
import 'basic.dart';
import 'chrome.dart';
import 'extended.dart';
import 'markets.dart';
import 'spatial.dart';

export '../protocol/events.dart' show asemanCatalogId;

/// Catalog ids surfaces may be created with.
const List<String> basicCatalogAliases = [
  asemanCatalogId,
];

/// Every component of the catalog, by group.
final Map<String, List<CatalogItem>> asemanComponentGroups = {
  'basic': basicItems,
  'aseman': asemanItems,
  'extended': extendedItems,
  'markets': marketItems,
  'chrome': chromeItems,
  'spatial': spatialItems,
};

/// The rules generated UI follows on Aseman (for prompts built from the
/// catalog).
const String asemanCatalogRules = '''
Aseman renders the Surface Spec catalog over AG-UI. Data props take literals,
{"path"} bindings or function calls at any depth. Interactive data views take
"selection" (a binding the tapped item is written to) and "action" (fired in
the tapped item's scope). Buttons may run client functions ({"functionCall":
{"call": "setValue", "args": {"path": "/tab", "value": "orders"}}}) to change
the UI without a round trip; Show renders a child only while a condition
holds. Use layout "chat" for inline chat surfaces; "app" for desk windows.''';

/// The catalog every Aseman surface renders with.
final Catalog asemanCatalog = Catalog(
  [
    for (final group in asemanComponentGroups.values) ...group,
  ],
  functions: allAsemanFunctions,
  catalogId: asemanCatalogId,
  catalogIdAliases: [
    asemanCatalogId,
    // Engine basic id: createSurface from the translate layer may use it.
    if (basicCatalogId != asemanCatalogId) basicCatalogId,
  ],
  systemPromptFragments: [BasicCatalogItems.basicCatalogRules, asemanCatalogRules],
);

/// The names of every component the catalog renders.
Iterable<String> get asemanComponentNames =>
    asemanCatalog.items.map((i) => i.name);
