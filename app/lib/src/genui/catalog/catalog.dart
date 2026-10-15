/// Tradera's genui catalog: the A2UI basic catalog in the app's design
/// language, Tradera's data, layout and escape-hatch components, the new
/// inputs, navigation and feedback components, the market components, and
/// Tradera's client functions.
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
import 'tradera.dart';

/// Tradera's own catalog id.
const String traderaCatalogId = 'https://tradera.app/a2ui/catalogs/tradera/v1';

/// Spellings of the basic catalog id surfaces are created with.
const List<String> basicCatalogAliases = [
  'https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json',
  'https://a2ui.org/specification/v0_9/basic_catalog.json',
  traderaCatalogId,
];

/// Every component of the catalog, by group.
final Map<String, List<CatalogItem>> traderaComponentGroups = {
  'basic': basicItems,
  'tradera': traderaItems,
  'extended': extendedItems,
  'markets': marketItems,
};

/// The rules generated UI follows on Tradera (for prompts built from the
/// catalog).
const String traderaCatalogRules = '''
Tradera renders the basic catalog plus its own components. Data props take
literals, {"path"} bindings or function calls at any depth. Interactive data
views take "selection" (a binding the tapped item is written to) and "action"
(fired in the tapped item's scope). Buttons may run client functions
({"functionCall": {"call": "setValue", "args": {"path": "/tab", "value":
"orders"}}}) to change the UI without a round trip; Show renders a child only
while a condition holds.''';

/// The catalog every Tradera surface renders with.
final Catalog traderaCatalog = Catalog(
  [
    for (final group in traderaComponentGroups.values) ...group,
  ],
  functions: allTraderaFunctions,
  catalogId: basicCatalogId,
  catalogIdAliases: basicCatalogAliases,
  systemPromptFragments: [BasicCatalogItems.basicCatalogRules, traderaCatalogRules],
);

/// The names of every component the catalog renders.
Iterable<String> get traderaComponentNames =>
    traderaCatalog.items.map((i) => i.name);
