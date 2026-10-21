/// Aseman's genui catalog: the A2UI basic catalog in the app's design
/// language, Aseman's data, layout and escape-hatch components, the new
/// inputs, navigation and feedback components, the market components, and
/// Aseman's client functions.
///
/// It answers to the basic catalog's id (and its other spellings) as well as
/// its own, so a surface created for the basic catalog — what tools and
/// agents send — gets every component.
library;

import 'package:genui/genui.dart';

import '../runtime/functions.dart';
import 'basic.dart';
import 'extended.dart';
import 'markets.dart';
import 'aseman.dart';

/// Aseman's own catalog id.
const String asemanCatalogId = 'https://aseman.app/a2ui/catalogs/aseman/v1';

/// Spellings of the basic catalog id surfaces are created with.
const List<String> basicCatalogAliases = [
  'https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json',
  'https://a2ui.org/specification/v0_9/basic_catalog.json',
  asemanCatalogId,
];

/// Every component of the catalog, by group.
final Map<String, List<CatalogItem>> asemanComponentGroups = {
  'basic': basicItems,
  'aseman': asemanItems,
  'extended': extendedItems,
  'markets': marketItems,
};

/// The rules generated UI follows on Aseman (for prompts built from the
/// catalog).
const String asemanCatalogRules = '''
Aseman renders the basic catalog plus its own components. Data props take
literals, {"path"} bindings or function calls at any depth. Interactive data
views take "selection" (a binding the tapped item is written to) and "action"
(fired in the tapped item's scope). Buttons may run client functions
({"functionCall": {"call": "setValue", "args": {"path": "/tab", "value":
"orders"}}}) to change the UI without a round trip; Show renders a child only
while a condition holds.''';

/// The catalog every Aseman surface renders with.
final Catalog asemanCatalog = Catalog(
  [
    for (final group in asemanComponentGroups.values) ...group,
  ],
  functions: allAsemanFunctions,
  catalogId: basicCatalogId,
  catalogIdAliases: basicCatalogAliases,
  systemPromptFragments: [BasicCatalogItems.basicCatalogRules, asemanCatalogRules],
);

/// The names of every component the catalog renders.
Iterable<String> get asemanComponentNames =>
    asemanCatalog.items.map((i) => i.name);
