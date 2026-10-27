// The Elpian UI DSL schema: every node type the Aseman client draws, with
// its props (and how strictly the Flutter builder reads them), events, child
// arity, parent and layout constraints. validate.mjs checks view trees
// against it; `node validate.mjs --describe <Type>` prints an entry.
//
// Prop types:
//   text      any scalar, shown as text (numbers are fine)
//   string    must be a JSON string (the builder casts it: anything else throws)
//   number    a number or a numeric string
//   num       must be a JSON number (cast: a string throws)
//   int       a whole JSON number
//   bool      must be true/false (cast: "true" throws)
//   flag      true/false; anything else is silently ignored
//   enum      one of `values` (a string)
//   icon      a Material icon name (icons.json)
//   color     a color: #hex, rgb()/rgba(), a CSS name, or (kit) a theme/status/series name
//   format    a kit value format (number:2, percent, currency:USD:0, date, …)
//   field     the name of a field of each data row
//   rows      an array of row objects (or plain numbers)
//   array     an array (`of`: an item schema of named fields)
//   object    a JSON object
//   any       anything
//   dart      a Dart-only prop (from Dart callers): ignored in a JSON tree
//
// Severity of a wrong value: `string`/`num`/`int`/`bool` and enum mismatches
// on cast props are errors (the node throws); the rest are warnings (the
// value is ignored or misread).
//
// Generated facts (node types, icons) are kept in sync with the Flutter
// sources by test/elpian.test.mjs; layout constraints (needsWidth,
// needsHeight, parents) come from rendering every node in unbounded layouts
// (app/test/elpian/dsl_layout_test.dart keeps them true): see LAYOUT.

// Events every node gets from the engine's gesture wrapper, unless the node
// handles its own (selfEvents).
export const GESTURE_EVENTS = [
  "tap", "click", "doubletap", "longpress", "tapdown", "tapup", "tapcancel",
  "dragstart", "drag", "dragend", "swipeleft", "swiperight", "swipeup", "swipedown",
  "pointerenter", "pointerexit", "pointerhover",
  "scalestart", "scaleupdate", "scaleend", "pinchstart", "pinchupdate", "pinchend",
  "rotatestart", "rotateupdate", "rotateend", "focus", "blur",
];

// Props every node takes.
export const COMMON_PROPS = {
  style: { type: "object", doc: "CSS-like style (see STYLE)" },
  className: { type: "any", doc: "stylesheet classes (string or list)" },
  class: { type: "any", doc: "alias of className" },
  id: { type: "string", doc: "stylesheet id" },
  slot: { type: "string", doc: "the parent's slot this child fills (Scaffold, AppBar, ListTile, Dismissible, …)" },
};

const LENGTH = "length";
// Style keys: the CSS parser's vocabulary (kebab-case aliases are accepted
// too). Value kinds: length (px number, "16", "50%", "10vw", calc()),
// number, int, color, duration ("300ms", "0.3s", 300), edges ("8", "8 16",
// "8 16 8 16", or {top,right,bottom,left}), radius (ONE number), string,
// bool, enum:<a|b>, curve, any.
export const STYLE = {
  width: LENGTH, height: LENGTH, minWidth: LENGTH, maxWidth: LENGTH, minHeight: LENGTH, maxHeight: LENGTH,
  aspectRatio: "number",
  padding: "edges", paddingTop: "number", paddingRight: "number", paddingBottom: "number", paddingLeft: "number", paddingX: "number", paddingY: "number",
  margin: "edges", marginTop: "number", marginRight: "number", marginBottom: "number", marginLeft: "number", marginX: "number", marginY: "number",
  alignment: "enum:center|topLeft|topCenter|topRight|centerLeft|centerRight|bottomLeft|bottomCenter|bottomRight",
  position: "enum:static|relative|absolute|fixed|sticky",
  top: LENGTH, right: LENGTH, bottom: LENGTH, left: LENGTH, zIndex: "number",
  display: "string",
  flexDirection: "enum:row|column|row-reverse|column-reverse",
  justifyContent: "enum:flex-start|start|center|flex-end|end|space-between|space-around|space-evenly",
  alignItems: "enum:flex-start|start|center|flex-end|end|stretch|baseline",
  flex: "int", flexGrow: "int", flexShrink: "int", flexBasis: "any",
  flexWrap: "enum:nowrap|wrap|wrap-reverse",
  overflow: "enum:visible|hidden|clip|auto|scroll", overflowX: "enum:visible|hidden|clip|auto|scroll", overflowY: "enum:visible|hidden|clip|auto|scroll",
  backgroundColor: "color", background: "any", backgroundImage: "string",
  backgroundSize: "enum:fill|contain|cover|fitWidth|fitHeight|none|scaleDown|fit-width|fit-height|scale-down",
  backgroundPosition: "string",
  gradient: "any",
  border: "border", borderRadius: "radius", borderColor: "color", borderWidth: "number", borderStyle: "string",
  color: "color", fontSize: "number",
  fontWeight: "enum:normal|bold|light|100|200|300|400|500|600|700|800|900|w100|w200|w300|w400|w500|w600|w700|w800|w900",
  fontStyle: "enum:normal|italic", fontFamily: "string",
  letterSpacing: "number", wordSpacing: "number", lineHeight: "number",
  textAlign: "enum:left|right|center|justify|start|end",
  textDecoration: "enum:none|underline|overline|line-through",
  textOverflow: "enum:ellipsis|clip|fade|visible",
  textTransform: "enum:none|uppercase|lowercase|capitalize",
  boxShadow: "any", textShadow: "any", transform: "any",
  rotate: "number", scale: "number", translate: "any", opacity: "number",
  visible: "bool", cursor: "string", pointerEvents: "string",
  gap: "number", rowGap: "number", columnGap: "number",
  gridTemplateColumns: "string", gridTemplateRows: "string", gridTemplateAreas: "string", gridAutoColumns: "string", gridAutoRows: "string", gridAutoFlow: "string",
  gridColumnGap: "number", gridRowGap: "number", gridGap: "number",
  transitionDuration: "duration", transitionCurve: "curve", transitionProperty: "string", transitionDelay: "duration",
  animationName: "string", animationDuration: "duration", animationTimingFunction: "string", animationDelay: "duration",
  animationIterationCount: "int", animationDirection: "string", animationFillMode: "string", animationPlayState: "string",
  animateOnBuild: "bool", staggerDelay: "duration", staggerChildren: "int",
  animationFrom: "number", animationTo: "number", slideBegin: "any", slideEnd: "any",
  scaleBegin: "number", scaleEnd: "number", rotationBegin: "number", rotationEnd: "number",
  fadeBegin: "number", fadeEnd: "number", colorBegin: "color", colorEnd: "color",
  paddingBegin: "edges", paddingEnd: "edges", alignmentBegin: "string", alignmentEnd: "string",
  shimmerBaseColor: "color", shimmerHighlightColor: "color", gradientColors: "any",
  animationAutoReverse: "bool", animationRepeat: "bool", keyframes: "any", verticalAlign: "string",
  borderCollapse: "string", borderSpacing: "any", captionSide: "string",
};

export const CURVES = ["linear", "ease", "ease-in", "ease-out", "ease-in-out", "bounce", "bounce-in", "bounce-out", "bounce-in-out",
  "elastic", "elastic-in", "elastic-out", "elastic-in-out", "decelerate", "fast-out-slow-in", "slow-middle",
  "ease-in-cubic", "ease-out-cubic", "ease-in-out-cubic", "ease-in-quart", "ease-out-quart", "ease-in-out-quart",
  "ease-in-quint", "ease-out-quint", "ease-in-out-quint", "ease-in-expo", "ease-out-expo", "ease-in-out-expo",
  "ease-in-circ", "ease-out-circ", "ease-in-out-circ", "ease-in-back", "ease-out-back", "ease-in-out-back"];

export const CSS_COLOR_NAMES = ["transparent", "black", "white", "red", "green", "blue", "yellow", "orange", "purple", "pink",
  "grey", "gray", "brown", "cyan", "indigo", "lime", "teal", "amber", "deeporange", "deeppurple", "lightblue", "lightgreen", "bluegrey"];
// Color names the UI kit's own `color` props take on top of #hex.
export const KIT_COLOR_NAMES = ["blue", "orange", "aqua", "yellow", "magenta", "green", "violet", "red", "primary", "accent", "muted",
  "gray", "grey", "other", "good", "success", "positive", "warning", "serious", "critical", "error", "danger", "negative", "info"];

export const TYPE_ROLES = ["displayLarge", "displayMedium", "displaySmall", "headlineLarge", "headlineMedium", "headlineSmall",
  "titleLarge", "titleMedium", "titleSmall", "bodyLarge", "bodyMedium", "bodySmall", "labelLarge", "labelMedium", "labelSmall"];
export const TYPE_ALIASES = ["display", "headline", "title", "body", "label", "h1", "h2", "h3", "h4", "h5", "h6", "caption", "overline"];

const SIZE5 = "xs|s|m|l|xl|small|medium|large|extraSmall|extraLarge|sm|md|lg";
const STATUS = "good|success|warning|serious|critical|error|info";

const e = (values, doc) => ({ type: "enum", values: values.split("|"), doc });
const t = (type, doc, extra) => ({ type, doc, ...(extra || {}) });

// Layout behaviour by measurement (see the header): needsWidth = throws in an
// unbounded width (directly in a Row, or in a horizontal scroll) unless given
// a width or wrapped in Expanded/Flexible; needsHeight = throws in an
// unbounded height (inside a vertical scroll).
const box = { children: "one" };
const anim = (doc, extra) => ({ category: "motion", children: "one", summary: doc, ...(extra || {}) });

export const TYPES = {
  // ── layout ────────────────────────────────────────────────────────────────
  Column: { category: "layout", children: "many", summary: "children top to bottom; style.gap, justifyContent, alignItems, flexWrap", axis: "vertical" },
  Row: { category: "layout", children: "many", summary: "children left to right; style.gap, justifyContent, alignItems, flexWrap", axis: "horizontal" },
  Wrap: { category: "layout", children: "many", summary: "children flowing onto new lines; style.gap" },
  Stack: { category: "layout", children: "many", summary: "children layered; place them with Positioned" },
  Positioned: { category: "layout", children: "one", parents: ["Stack"], summary: "a Stack child placed by style.top/right/bottom/left" },
  Expanded: { category: "layout", children: "one", parents: ["Row", "Column"], flexChild: true, props: { flex: t("number", "share of the free space (default 1)") }, summary: "fills the free space of its Row/Column" },
  Flexible: { category: "layout", children: "one", parents: ["Row", "Column"], flexChild: true, props: { flex: t("number", "share of the free space (default 1)") }, summary: "may fill the free space of its Row/Column" },
  Spacer: { category: "layout", children: "none", parents: ["Row", "Column"], flexChild: true, props: { flex: t("number", "share of the free space (default 1)") }, summary: "empty space that fills its Row/Column" },
  Container: { category: "layout", children: "one", summary: "a box: size, padding, margin, background, border, radius through style",
    props: { width: t("number"), height: t("number"), padding: t("dart", "use style.padding"), margin: t("dart", "use style.margin"), alignment: t("dart", "use style.alignment"), decoration: t("dart", "use style (backgroundColor, borderRadius, border, boxShadow, gradient)") } },
  Padding: { category: "layout", ...box, summary: "style.padding around its child" },
  Center: { category: "layout", ...box, summary: "centers its child" },
  Align: { category: "layout", ...box, summary: "aligns its child (style.alignment)" },
  SizedBox: { category: "layout", children: "one", summary: "a fixed style.width/height box (or empty space)" },
  ConstrainedBox: { category: "layout", ...box, summary: "min/max size (style.minWidth …)" },
  LimitedBox: { category: "layout", ...box, summary: "a max size when unconstrained" },
  OverflowBox: { category: "layout", ...box, summary: "lets its child overflow; needs a bounded box" },
  FittedBox: { category: "layout", ...box, summary: "scales its child to fit" },
  FractionallySizedBox: { category: "layout", ...box, props: { widthFactor: t("number", "0..1"), heightFactor: t("number", "0..1") }, summary: "sizes its child to a fraction of the space" },
  AspectRatio: { category: "layout", ...box, props: { aspectRatio: t("number", "width / height") }, summary: "keeps its child at an aspect ratio" },
  DecoratedBox: { category: "layout", ...box, summary: "paints style decoration behind its child" },
  ClipRRect: { category: "layout", ...box, summary: "clips its child to style.borderRadius" },
  Baseline: { category: "layout", ...box, props: { baseline: t("number") }, summary: "aligns its child's baseline" },
  RotatedBox: { category: "layout", ...box, props: { quarterTurns: t("number", "quarter turns clockwise") }, summary: "rotates its child by quarter turns" },
  Transform: { category: "layout", ...box, summary: "transforms its child (style.transform / rotate / scale / translate)" },
  Opacity: { category: "layout", ...box, props: { opacity: t("number", "0..1") }, summary: "fades its child" },
  IndexedStack: { category: "layout", children: "many", props: { index: t("number", "the child shown") }, summary: "shows one child by index" },
  ListView: { category: "layout", children: "many", scroll: "vertical", props: { scrollDirection: e("vertical|horizontal", "horizontal scrolls a row"), scrollable: t("flag", "false: no scrolling") }, summary: "a scrolling list (shrink-wraps its height)" },
  GridView: { category: "layout", children: "many", scroll: "vertical", props: { crossAxisCount: t("number", "columns (default 2)") }, summary: "a grid of equal cells" },
  Divider: { category: "layout", children: "none", summary: "a horizontal line" },
  VerticalDivider: { category: "layout", children: "none", summary: "a vertical line (in a Row with a bounded height)" },
  Hero: { category: "layout", ...box, props: { tag: t("any", "shared transition tag") }, summary: "a shared element transition" },

  // ── content ───────────────────────────────────────────────────────────────
  Text: {
    category: "content", children: "none", summary: "text, styled by an M3 type role",
    props: {
      text: t("text", "the text"), data: t("text", "alias of text"),
      variant: { type: "enum", values: [...TYPE_ROLES, ...TYPE_ROLES.map((r) => r + "Emphasized"), ...TYPE_ALIASES], doc: "M3 type role (add Emphasized for the bolder weight)" },
      color: e("primary|secondary|tertiary|error|muted|onSurfaceVariant|secondaryText|onSurface|onPrimaryContainer|onSecondaryContainer|onTertiaryContainer", "a theme color role"),
      maxLines: t("number"), overflow: e("ellipsis|clip|fade|visible"), softWrap: t("bool"), textAlign: e("left|right|center|justify|start|end"),
    },
    requires: ["text|data"],
  },
  Icon: { category: "content", children: "none", summary: "a Material icon (rounded)", props: { icon: t("icon", "Material icon name"), size: t("number", "default 24"), svgPath: t("string", "an SVG path in a 24×24 box instead"), semanticLabel: t("text") }, requires: ["icon|svgPath"] },
  Image: { category: "content", children: "none", summary: "an image; size with style.width/height", props: { src: t("string", "https URL, /v1/files/<id>/content, project path or data URI"), fit: e("cover|contain|fill|fitWidth|fitHeight|none|scaleDown"), alt: t("text", "accessible description") }, requires: ["src"] },
  Badge: { category: "content", children: "one", summary: "a badge on its child (an Icon)", props: { label: t("text"), count: t("number"), max: t("number"), show: t("flag") } },
  Tooltip: { category: "content", children: "one", summary: "a tooltip on its child", props: { message: t("text") }, requires: ["message"] },
  MathExpression: { category: "content", children: "none", summary: "a formula", props: { latex: t("string"), expression: t("string"), text: t("text"), data: t("text") }, requires: ["latex|expression|text|data"] },
  Math: { category: "content", children: "none", summary: "alias of MathExpression", props: { latex: t("string"), expression: t("string"), text: t("text"), data: t("text") }, requires: ["latex|expression|text|data"] },
  CircularProgressIndicator: { category: "content", children: "none", summary: "a spinner or ring (value 0..1)", props: { value: t("number", "0..1; omit to spin") } },
  LinearProgressIndicator: { category: "content", children: "none", summary: "a bar (value 0..1)", props: { value: t("number", "0..1; omit to sweep") } },
  LoadingIndicator: { category: "content", children: "none", summary: "the M3E morphing loading indicator", props: { size: t("number", "default 48"), contained: t("flag", "on a tonal circle") } },
  Canvas: { category: "content", children: "none", summary: "vector drawing by canvas commands", props: { commands: t("array"), width: t("number"), height: t("number"), backgroundColor: t("color") } },
  CachedCanvas: { category: "content", children: "none", summary: "a canvas that keeps its drawing across renders", props: { commands: t("array"), width: t("number"), height: t("number"), backgroundColor: t("color"), contextId: t("string"), id: t("string") } },
  Scene3D: { category: "content", children: "many", summary: "an embedded 3D scene (Godot)", props: { scene: t("any"), world: t("any"), initialScene: t("any"), width: t("num"), height: t("num"), clickable: t("flag") } },

  // ── Material 3 Expressive controls ────────────────────────────────────────
  Button: {
    category: "material", children: "one", selfEvents: ["tap", "click", "longpress"], summary: "an M3E button",
    props: {
      text: t("text", "the label"), label: t("text", "alias of text"),
      variant: e("filled|tonal|outlined|text|elevated|danger|secondary|tertiary|outline|ghost|link|error", "button style (default filled)"),
      icon: t("icon", "leading icon"), trailingIcon: t("icon", "trailing icon"),
      size: e(SIZE5, "xs 32 · s 40 (default) · m 56 · l 96 · xl 136"),
      shape: e("round|square"), selected: t("flag", "a toggle button"), loading: t("flag"), fullWidth: t("flag"),
      tooltip: t("text"), disabled: t("flag"),
    },
  },
  IconButton: {
    category: "material", children: "one", selfEvents: ["tap", "click", "longpress"], summary: "an icon-only button",
    props: { icon: t("icon"), selectedIcon: t("icon"), variant: e("standard|filled|tonal|outlined"), size: e(SIZE5), shape: e("round|square"), selected: t("flag"), tooltip: t("text", "describe the action (accessibility)"), disabled: t("flag") },
    requires: ["icon"],
  },
  FAB: {
    category: "material", children: "one", selfEvents: ["tap", "click"], scaffoldSlot: true, summary: "the floating action button (alias FloatingActionButton)",
    props: { icon: t("icon", "default add"), label: t("text", "extended FAB"), text: t("text"), size: e("small|medium|large"), variant: e("primary|secondary|tertiary|surface|filled"), mini: t("flag"), tooltip: t("text"), elevation: t("number"), heroTag: t("any"), disabled: t("flag") },
  },
  FloatingActionButton: {
    category: "material", children: "one", selfEvents: ["tap", "click"], scaffoldSlot: true, summary: "the floating action button (alias FAB)",
    props: { icon: t("icon", "default add"), label: t("text", "extended FAB"), text: t("text"), size: e("small|medium|large"), variant: e("primary|secondary|tertiary|surface|filled"), mini: t("flag"), tooltip: t("text"), elevation: t("number"), heroTag: t("any"), disabled: t("flag") },
  },
  SegmentedButton: {
    category: "material", children: "none", selfEvents: ["change"], needsKey: true, summary: "a connected group of 2–5 options",
    props: {
      segments: { type: "array", of: { value: "text", label: "text", icon: "icon", tooltip: "text" }, scalars: true, doc: "[{value, label, icon}] or strings" },
      items: { type: "array", of: { value: "text", label: "text", icon: "icon", tooltip: "text" }, scalars: true, doc: "alias of segments" },
      selected: t("any", "a value (or list with multi)"), value: t("any", "alias of selected"), multi: t("flag"), emptyAllowed: t("flag"), showIcon: t("flag"), size: e("s|m|small|medium"), disabled: t("flag"),
    },
    requires: ["segments|items"],
  },
  Chip: {
    category: "material", children: "none", selfEvents: ["tap", "click", "change", "remove"], summary: "an M3 chip (filter chip with selected)",
    props: { label: t("text"), text: t("text"), icon: t("icon"), selected: t("flag", "a filter chip"), variant: e("assist|filter|input|suggestion|elevated"), disabled: t("flag") },
    requires: ["label|text"],
  },
  ListTile: {
    category: "material", children: "slots", slots: ["leading", "trailing", "title", "subtitle"], selfEvents: ["tap", "click", "longpress"], summary: "a list item",
    props: { title: t("text"), subtitle: t("text"), overline: t("text"), leading: t("icon"), leadingAvatar: t("text", "a name: initials"), leadingImage: t("string", "an image URL"), trailing: t("icon"), trailingText: t("text"), selected: t("flag"), dense: t("flag"), disabled: t("flag"), lines: t("number", "3 wraps the subtitle") },
    requires: ["title"],
  },
  ListGroup: {
    category: "material", children: "many", summary: "ListTiles as one segmented M3E group",
    props: { title: t("text"), variant: e("tonal|outlined"), radius: t("number"), innerRadius: t("number"), gap: t("number") },
    childTypes: ["ListTile"],
  },
  NavigationBar: {
    category: "material", children: "none", selfEvents: ["change"], scaffoldSlot: true, summary: "the bottom navigation bar (3–5 destinations)",
    props: {
      items: { type: "array", of: { icon: "icon", selectedIcon: "icon", label: "text", badge: "any" }, min: 2, max: 5, doc: "[{icon, label, badge}]" },
      destinations: { type: "array", of: { icon: "icon", selectedIcon: "icon", label: "text", badge: "any" }, doc: "alias of items" },
      selected: t("number", "index"), value: t("number", "alias of selected"), labels: e("always|selected|never"),
    },
    requires: ["items|destinations"],
  },
  SearchBar: { category: "material", children: "none", events: ["input", "submit"], needsKey: true, summary: "a pill search field", props: { hint: t("text"), value: t("text"), icon: t("icon"), trailingIcon: t("icon"), elevation: t("number") } },
  TextField: {
    category: "material", children: "none", events: ["input", "submit"], needsKey: true, summary: "a text input",
    props: {
      hint: t("string"), label: t("text"), value: t("text"), icon: t("icon"), prefixIcon: t("icon"), trailingIcon: t("icon"), suffixIcon: t("icon"),
      prefix: t("text"), suffix: t("text"), helper: t("text"), error: t("text"), counter: t("text"), variant: e("filled|outlined"),
      obscureText: t("flag"), multiline: t("flag"), maxLines: t("num"), disabled: t("flag"),
      keyboardType: { type: "enum", strict: true, values: ["text", "number", "email", "phone", "url", "date", "time", "datetime-local"] },
      min: t("string", "yyyy-MM-dd (date pickers)"), max: t("string", "yyyy-MM-dd (date pickers)"),
    },
  },
  Checkbox: { category: "material", children: "none", events: ["change"], needsKey: true, summary: "a checkbox", props: { value: t("bool"), label: t("text"), labelPosition: e("start|end"), disabled: t("flag") } },
  Switch: { category: "material", children: "none", events: ["change"], needsKey: true, summary: "a switch", props: { value: t("bool"), label: t("text"), labelPosition: e("start|end"), icons: t("flag"), disabled: t("flag") } },
  Radio: { category: "material", children: "none", events: ["change"], summary: "a radio button", props: { value: t("any"), groupValue: t("any") } },
  Slider: { category: "material", children: "none", events: ["change"], needsKey: true, summary: "a slider", props: { value: t("number"), min: t("number"), max: t("number"), step: t("number"), divisions: t("number"), label: t("any", "true or a suffix like \"%\""), disabled: t("flag") } },
  Card: {
    category: "material", children: "many", selfEvents: ["tap", "click", "longpress", "doubletap"], summary: "an M3 card (style.padding inside, style.gap between children)",
    props: { variant: e("filled|elevated|outlined"), tone: e("primary|secondary|tertiary|error|danger|inverse"), radius: t("number"), elevation: t("number") },
  },
  InkWell: { category: "interaction", children: "one", selfEvents: [...GESTURE_EVENTS, "hover"], summary: "makes its child tappable with a ripple", props: { disabled: t("flag"), splashColor: t("color"), highlightColor: t("color"), hoverColor: t("color"), focusColor: t("color") } },
  GestureDetector: { category: "interaction", children: "one", selfEvents: [...GESTURE_EVENTS], summary: "makes its child respond to gestures", props: { behavior: e("opaque|translucent|deferToChild") } },
  Dismissible: { category: "interaction", children: "slots", slots: ["background", "secondaryBackground"], selfEvents: ["dismiss", "dismissed", "dismissupdate", "resize"], needsKey: true, summary: "swipe to dismiss", props: { direction: t("string"), threshold: t("number"), movementDuration: t("any"), resizeDuration: t("any") } },
  Draggable: { category: "interaction", children: "slots", slots: ["feedback", "childWhenDragging"], selfEvents: ["dragstart", "drag", "dragend", "dragcancel", "dragcomplete"], summary: "a draggable child", props: { data: t("any"), axis: e("horizontal|vertical"), longPress: t("flag"), feedbackOpacity: t("number"), fadeWhileDragging: t("flag"), maxSimultaneousDrags: t("number") } },
  DragTarget: { category: "interaction", children: "one", selfEvents: ["accept", "dragover", "dragleave"], summary: "accepts dropped Draggables", props: { accept: t("any"), accepts: t("any"), activeStyle: t("object"), rejectStyle: t("object") } },

  // ── app chrome ────────────────────────────────────────────────────────────
  Scaffold: {
    category: "chrome", children: "slots", slots: ["appBar", "drawer", "endDrawer", "floatingActionButton", "bottomNavigationBar", "bottomBar", "bottomSheet", "persistentFooterButtons", "persistentFooterButton", "body"],
    selfEvents: ["drawerchange", "enddrawerchange"], summary: "a full-screen page: AppBar, body, FAB, NavigationBar, Drawer",
    props: { floatingActionButtonLocation: t("string"), extendBody: t("flag"), extendBodyBehindAppBar: t("flag"), resizeToAvoidBottomInset: t("bool"), primary: t("flag"), drawerEnableOpenDragGesture: t("flag"), endDrawerEnableOpenDragGesture: t("flag") },
  },
  AppBar: {
    category: "chrome", children: "slots", slots: ["title", "leading", "actions", "action", "bottom", "flexibleSpace"], scaffoldSlot: true, summary: "the top app bar",
    props: { title: t("text"), centerTitle: t("flag"), elevation: t("number"), scrolledUnderElevation: t("number"), automaticallyImplyLeading: t("flag"), primary: t("flag"), titleSpacing: t("number") },
  },
  Drawer: { category: "chrome", children: "many", scaffoldSlot: true, summary: "a navigation drawer (in a Scaffold)", props: { elevation: t("number") } },

  // ── motion ────────────────────────────────────────────────────────────────
  AnimatedContainer: anim("a Container that animates style changes (style.transitionDuration, transitionCurve)"),
  AnimatedOpacity: anim("animates style.opacity"),
  AnimatedCrossFade: anim("cross-fades between its two children", { children: "many", props: { showFirst: t("bool") } }),
  AnimatedSwitcher: anim("animates between successive children (give each a different key)", { props: { transitionType: { type: "enum", strict: true, values: ["fade", "scale", "rotation", "slide"] } } }),
  AnimatedAlign: anim("animates style.alignment"),
  AnimatedPadding: anim("animates style.padding"),
  AnimatedPositioned: anim("a Positioned that animates", { parents: ["Stack"] }),
  AnimatedScale: anim("animates style.scale"),
  AnimatedRotation: anim("animates style.rotate"),
  AnimatedSlide: anim("animates style.translate"),
  AnimatedSize: anim("animates its child's size"),
  AnimatedDefaultTextStyle: anim("animates the text style of its subtree"),
  FadeTransition: anim("fades its child in (style.fadeBegin / fadeEnd, animationDuration)"),
  SlideTransition: anim("slides its child in (style.slideBegin / slideEnd)"),
  ScaleTransition: anim("scales its child in (style.scaleBegin / scaleEnd)"),
  RotationTransition: anim("rotates its child (style.rotationBegin / rotationEnd)"),
  SizeTransition: anim("reveals its child along an axis", { props: { axis: { type: "enum", strict: true, values: ["vertical", "horizontal"] } } }),
  TweenAnimationBuilder: anim("animates a value on build", { props: { tweenType: { type: "enum", strict: true, values: ["opacity", "scale", "rotation", "translateX", "translateY"] } } }),
  StaggeredAnimation: anim("staggers its children in", { children: "many" }),
  Shimmer: anim("a loading shimmer over its child (skeletons)"),
  Pulse: anim("pulses its child"),
  AnimatedGradient: anim("an animated gradient background (style.gradientColors)"),

  // ── UI kit: data views ────────────────────────────────────────────────────
  Chart: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "line, area, bar, scatter, bubble, candlestick, histogram, pie, donut, radar, heatmap, treemap",
    props: {
      type: e("line|area|bar|scatter|bubble|candlestick|histogram|pie|donut|radar|heatmap|treemap|funnel|waterfall|sankey|gantt|boxplot|box|sunburst|bullet|segmented|stackedbar|radialbar|rings|calendar|wordcloud"), data: t("rows"), x: t("field"), y: t("field"),
      series: { type: "array", of: { field: "field", label: "text", color: "color" }, scalars: true, doc: "[field] or [{field, label, color}]" },
      title: t("text"), subtitle: t("text"), stacked: t("flag"), horizontal: t("flag"), smooth: t("flag"), points: t("flag"), zero: t("flag"), valueLabels: t("flag"), legend: t("any"),
      xFormat: t("format"), yFormat: t("format"), xLabel: t("text"), yLabel: t("text"), xTitle: t("text", "alias of xLabel"), yTitle: t("text", "alias of yLabel"), donut: t("flag", "pie as a donut"), min: t("number"), max: t("number"), height: t("number"),
      open: t("field"), high: t("field"), low: t("field"), close: t("field"), size: t("field"), label: t("field"), value: t("field"), centerLabel: t("text"), centerCaption: t("text"),
      field: t("field"), bins: t("number"), rows: t("any"), columns: t("any"), values: t("any"), kind: t("any"),
    },
    requires: ["data|values|rows"],
  },
  Sparkline: { category: "kit", children: "none", summary: "a tiny trend line", props: { values: t("rows"), field: t("field"), type: e("line|bar|area"), area: t("flag", "fill under the line"), color: t("color"), height: t("number"), width: t("number") }, requires: ["values"] },
  Gauge: { category: "kit", children: "none", summary: "a value on a 240° arc", props: { value: t("number"), min: t("number"), max: t("number"), label: t("text"), format: t("format"), color: t("color"), size: t("number"), thresholds: { type: "array", of: { value: "number", status: "string", color: "color" } } }, requires: ["value"] },
  Heatmap: { category: "kit", children: "none", selfEvents: ["select"], summary: "a matrix of colored cells", props: { data: t("rows"), rows: t("array"), columns: t("array"), values: t("array"), x: t("field"), y: t("field"), value: t("field"), format: t("format"), diverging: t("flag"), showValues: t("flag"), cellHeight: t("number"), valueLabel: t("string", "legend label of the value") } },
  Treemap: { category: "kit", children: "none", selfEvents: ["select"], summary: "nested rectangles by value", props: { data: t("rows"), label: t("field"), value: t("field"), group: t("field"), colorBy: t("field"), format: t("format"), colorFormat: t("format"), height: t("number"), valueLabel: t("string", "legend label of the size"), colorLabel: t("string", "legend label of colorBy") }, requires: ["data"] },
  Graph: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "a node-link network",
    props: { nodes: { type: "array", of: { id: "text", label: "text", group: "any", color: "color" } }, edges: { type: "array", of: { from: "text", to: "text", label: "text", weight: "number" } }, links: { type: "array", of: { from: "text", to: "text", label: "text", weight: "number" }, doc: "alias of edges" }, layout: e("force|circle|tree"), directed: t("flag"), size: t("field"), height: t("number") },
    requires: ["nodes"],
  },
  DataGrid: {
    category: "kit", children: "none", selfEvents: ["select"], notInWidget: true, summary: "a sortable, searchable table",
    props: {
      data: t("rows"),
      columns: { type: "array", of: { field: "field", label: "text", type: "string", format: "format", align: "string", width: "number", max: "number", colors: "any", color: "color" }, doc: "[{field, label, type, format, align, width}]" },
      search: t("flag"), searchHint: t("text"), pageSize: t("number"), sortable: t("flag"), sortBy: t("string"), sortDirection: e("asc|desc"), striped: t("flag"), dense: t("flag"), maxHeight: t("number"), title: t("text"), emptyText: t("text"),
    },
    requires: ["data"],
  },
  Stat: { category: "kit", children: "none", summary: "a key figure: label, value, delta, trend", props: { label: t("text"), value: t("any"), format: t("format"), delta: t("number"), deltaFormat: t("format"), deltaLabel: t("text"), caption: t("text"), goodDirection: e("up|down"), trend: t("rows"), icon: t("icon"), status: { type: "enum", strict: true, values: STATUS.split("|") }, color: t("color"), size: e("compact|default|hero") }, requires: ["value"] },
  KeyValue: { category: "kit", children: "none", summary: "label → value pairs", props: { items: { type: "array", of: { label: "text", key: "text", value: "any", format: "format", type: "string" } }, data: t("object"), labels: t("object"), formats: t("object"), columns: t("number"), layout: e("horizontal|vertical") }, requires: ["items|data"] },
  Timeline: { category: "kit", children: "none", selfEvents: ["select"], summary: "events in time", props: { data: t("rows"), items: t("rows"), titleField: t("field"), descriptionField: t("field"), timeField: t("field"), timeFormat: t("format") }, requires: ["data|items"] },
  TreeView: { category: "kit", children: "none", selfEvents: ["select"], summary: "an expandable tree", props: { data: t("any"), labelField: t("field"), childrenField: t("field"), expanded: t("number"), format: t("format") }, requires: ["data"] },
  JsonView: { category: "kit", children: "none", summary: "a JSON value, expandable", props: { value: t("any"), data: t("any"), expanded: t("number") } },
  CodeBlock: { category: "kit", children: "none", summary: "highlighted code", props: { code: t("text"), language: t("string"), lineNumbers: t("flag"), maxHeight: t("number") }, requires: ["code"] },
  Progress: { category: "kit", children: "none", summary: "a linear (or circular) progress", props: { value: t("number"), max: t("number"), variant: e("linear|circular|wavy"), wavy: t("flag"), label: t("text"), showValue: t("flag"), format: t("format"), color: t("color"), status: t("string"), size: t("number"), thickness: t("number") } },
  Tag: { category: "kit", children: "none", summary: "a pill label or status", props: { text: t("text"), label: t("text"), value: t("text"), status: t("string"), color: t("color"), variant: e("tonal|filled|outline|outlined"), icon: t("icon"), dot: t("flag") }, requires: ["text|label|value"] },
  Rating: { category: "kit", children: "none", selfEvents: ["change"], summary: "stars", props: { value: t("number"), max: t("number"), size: t("number"), color: t("color"), showValue: t("flag") } },
  Callout: { category: "kit", children: "many", summary: "a highlighted message (info, good, warning, critical)", props: { title: t("text"), text: t("text"), severity: e("info|good|success|warning|serious|critical|error"), status: t("string"), icon: t("icon"), color: t("color") } },
  Avatar: { category: "kit", children: "none", summary: "initials or a photo", props: { name: t("text"), label: t("text"), url: t("string"), image: t("string"), size: t("number"), color: t("color") } },
  ResponsiveGrid: { category: "kit", children: "many", summary: "equal-width columns that adapt to the width", props: { columns: t("number"), minColumnWidth: t("number"), maxColumns: t("number"), gap: t("number"), runGap: t("number") } },
  Section: { category: "kit", children: "many", summary: "a titled group", props: { title: t("text"), subtitle: t("text"), icon: t("icon"), trailing: t("text"), gap: t("number") } },
  Expandable: { category: "kit", children: "many", summary: "a panel that opens on tap", props: { title: t("text"), subtitle: t("text"), icon: t("icon"), expanded: t("flag") }, requires: ["title"] },
  Scroll: { category: "kit", children: "many", scroll: "dynamic", summary: "a scroll area", props: { direction: e("vertical|horizontal"), maxHeight: t("number") } },

  // ── UI kit: flows, distributions, calendars ──────────────────────────────
  Funnel: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "stages narrowing to an outcome, with shares and step conversion",
    props: { data: t("rows", "[{label, value}]"), values: t("rows"), label: t("field"), value: t("field"), format: t("format"), color: t("color"), title: t("text"), subtitle: t("text") },
    requires: ["data|values"],
  },
  Waterfall: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "a start value moved by increases and decreases to a total",
    props: { data: t("rows", "[{label, value}] (rows with total: true draw the running total)"), values: t("rows"), label: t("field"), value: t("field"), x: t("field"), y: t("field"), start: t("number"), startLabel: t("text"),
      showTotal: t("flag"), totalLabel: t("text"), format: t("format"), yFormat: t("format"), height: t("number"), upColor: t("color"), downColor: t("color"), color: t("color"), title: t("text"), subtitle: t("text") },
    requires: ["data|values"],
  },
  Sankey: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "flows between nodes in layers, ribbons as thick as their value",
    props: { links: t("rows", "[{from, to, value}]"), data: t("rows"), edges: t("rows"), nodes: { type: "array", of: { id: "text", label: "text", color: "color" } }, source: t("field"), target: t("field"), value: t("field"),
      format: t("format"), height: t("number"), title: t("text"), subtitle: t("text") },
    requires: ["links|data|edges"],
  },
  Gantt: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "tasks on a time axis with progress, groups, milestones and today",
    props: { data: t("rows", "[{label, start, end, progress, group, status, color}]"), tasks: t("rows"), label: t("field"), start: t("field"), end: t("field"), timeFormat: t("format"), title: t("text"), subtitle: t("text") },
    requires: ["data|tasks"],
  },
  BoxPlot: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "distributions: quartiles, whiskers, outliers",
    props: { data: t("rows", "[{label, values: [...]}] or [{label, min, q1, median, q3, max}]"), label: t("field"), x: t("field"), format: t("format"), yFormat: t("format"), height: t("number"), colorful: t("flag"), title: t("text"), subtitle: t("text") },
    requires: ["data"],
  },
  BulletChart: {
    category: "kit", children: "none", summary: "values against targets over qualitative ranges",
    props: { items: { type: "array", of: { label: "text", value: "number", target: "number", ranges: "array", max: "number", format: "format", color: "color", status: "string" } }, label: t("text"), value: t("number"), target: t("number"), ranges: t("array"), max: t("number"),
      format: t("format"), color: t("color"), status: t("string"), title: t("text"), subtitle: t("text") },
    requires: ["items|value"],
  },
  SegmentedBar: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "one bar split into parts, with a legend of shares",
    props: { data: t("rows", "[{label, value, color}]"), values: t("rows"), label: t("field"), value: t("field"), format: t("format"), thickness: t("number"), legend: t("flag"), showPercent: t("flag"), title: t("text"), subtitle: t("text") },
    requires: ["data|values"],
  },
  RadialBars: {
    category: "kit", children: "none", summary: "concentric progress rings (activity rings)",
    props: { data: t("rows", "[{label, value, max, color}]"), values: t("rows"), max: t("number"), size: t("number"), format: t("format"), centerLabel: t("text"), centerCaption: t("text"), legend: t("flag"), title: t("text"), subtitle: t("text") },
    requires: ["data|values"],
  },
  Sunburst: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "a hierarchy as rings, arcs sized by value",
    props: { data: t("any", "{label, value, children} or a list of them"), size: t("number"), height: t("number"), format: t("format"), centerCaption: t("text"), title: t("text"), subtitle: t("text") },
    requires: ["data"],
  },
  CalendarHeatmap: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "a contribution graph: one cell per day, darker for more",
    props: { data: t("rows", "[{date, value}]"), date: t("field"), value: t("field"), end: t("string", "yyyy-MM-dd (default the last date)"), weeks: t("number"), format: t("format"), color: t("color"), title: t("text"), subtitle: t("text") },
    requires: ["data"],
  },
  WordCloud: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "words sized by weight",
    props: { data: t("rows", "[{text, value}]"), words: t("rows"), label: t("field"), text: t("field"), value: t("field"), max: t("number"), minSize: t("number"), maxSize: t("number"), colorful: t("flag"), height: t("number"), title: t("text"), subtitle: t("text") },
    requires: ["data|words"],
  },

  // ── UI kit: tables ────────────────────────────────────────────────────────
  PivotTable: {
    category: "kit", children: "none", selfEvents: ["select"], notInWidget: true, summary: "rows × columns of an aggregated value, with totals and heat shading",
    props: { data: t("rows"), rows: t("any", "a field or a list of fields"), columns: t("any", "a field or a list of fields"), value: t("field"), aggregate: e("sum|count|avg|mean|average|min|max"),
      format: t("format"), totals: t("flag"), heat: t("flag"), sort: t("flag"), color: t("color"), maxHeight: t("number"), title: t("text"), subtitle: t("text") },
    requires: ["data"],
  },
  Leaderboard: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "a ranked list with medals, avatars, bars and rank changes",
    props: { data: t("rows", "[{name, value, subtitle, avatar, change, id}]"), label: t("field"), name: t("field"), value: t("field"), max: t("number"), format: t("format"), highlight: t("text"), showBar: t("flag"), title: t("text"), subtitle: t("text") },
    requires: ["data"],
  },

  // ── UI kit: app widgets ───────────────────────────────────────────────────
  Tabs: {
    category: "kit", children: "many", selfEvents: ["change"], needsKey: true, summary: "an M3 tab bar over panels (the children, one per tab)",
    props: { tabs: { type: "array", of: { label: "text", icon: "icon", badge: "any" }, scalars: true, min: 1, doc: "[{label, icon, badge}] or strings" }, items: { type: "array", of: { label: "text", icon: "icon", badge: "any" }, scalars: true, doc: "alias of tabs" },
      selected: t("number", "index (set from the program)"), variant: e("primary|secondary"), scrollable: t("flag"), gap: t("number") },
    requires: ["tabs|items"],
  },
  Calendar: {
    category: "kit", children: "none", selfEvents: ["select", "change"], notInWidget: true, summary: "a month calendar with events; the selected day's events below",
    props: { month: t("string", "yyyy-MM"), selected: t("string", "yyyy-MM-dd"), events: { type: "array", of: { date: "string", start: "string", title: "text", label: "text", time: "text", subtitle: "text", color: "color", status: "string" } },
      firstDay: e("monday|sunday"), showEvents: t("flag") },
  },
  Kanban: {
    category: "kit", children: "none", selfEvents: ["select", "move"], notInWidget: true, summary: "columns of cards; long-press to drag a card to another column",
    props: { columns: { type: "array", of: { id: "any", title: "text", label: "text", color: "color", cards: "array", items: "array" }, doc: "[{id, title, color, cards: [{title, subtitle, description, tags, assignee, avatar, due, priority, status, color}]}]" },
      columnWidth: t("number"), draggable: t("flag"), emptyText: t("text") },
    requires: ["columns"],
  },
  Carousel: {
    category: "kit", children: "many", selfEvents: ["change"], summary: "swipeable slides (the children, or items) with peeking neighbours and dots",
    props: { items: { type: "array", of: { image: "string", src: "string", url: "string", title: "text", subtitle: "text" }, scalars: true }, images: t("array"), height: t("number"), autoplay: t("number", "ms between slides (≥ 1000)"), viewportFraction: t("number"), dots: t("flag") },
  },
  Stepper: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "progress through steps (done, current, error, to do)",
    props: { steps: { type: "array", of: { title: "text", label: "text", subtitle: "text", description: "text", state: "string", status: "string" }, scalars: true }, items: t("array"), current: t("number"), orientation: e("vertical|horizontal") },
    requires: ["steps|items"],
  },
  Chat: {
    category: "kit", children: "none", selfEvents: ["select"], notInWidget: true, summary: "a chat thread: bubbles, avatars, grouping, typing indicator, suggestions",
    props: { messages: { type: "array", of: { role: "string", from: "string", text: "text", name: "text", time: "text", avatar: "string" } }, me: t("text", "the role that is the person (default user)"), showAvatars: t("flag"), typing: t("flag"), suggestions: t("array") },
    requires: ["messages"],
  },
  Countdown: {
    category: "kit", children: "none", selfEvents: ["done"], summary: "a live countdown on tonal tiles",
    props: { to: t("string", "an ISO date/time"), until: t("string"), seconds: t("number"), label: t("text"), size: e("compact|default|hero"), showDays: t("flag"), showSeconds: t("flag") },
    requires: ["to|until|seconds"],
  },
  Clock: {
    category: "kit", children: "none", summary: "a live analog or digital clock",
    props: { mode: e("analog|digital"), size: t("number"), utcOffset: t("number", "hours"), label: t("text"), seconds: t("flag"), hour24: t("flag") },
  },
  EmptyState: {
    category: "kit", children: "none", selfEvents: ["action"], summary: "an icon, a title, a line and the action that fills the view",
    props: { icon: t("icon"), title: t("text"), text: t("text"), action: t("text", "the button label"), actionIcon: t("icon"), size: e("compact|default") },
    requires: ["title"],
  },
  AvatarGroup: {
    category: "kit", children: "none", summary: "overlapping avatars with a +N",
    props: { names: t("array"), items: { type: "array", of: { name: "text", label: "text", url: "string", image: "string" }, scalars: true }, people: t("array"), max: t("number"), size: t("number") },
    requires: ["names|items|people"],
  },
  Pagination: {
    category: "kit", children: "none", selfEvents: ["change"], summary: "page numbers with prev/next",
    props: { page: t("number", "1-based"), value: t("number"), pages: t("number"), total: t("number"), siblings: t("number") },
    requires: ["pages|total"],
  },
  Breadcrumbs: {
    category: "kit", children: "none", selfEvents: ["select"], summary: "where the person is; earlier crumbs are tappable",
    props: { items: { type: "array", of: { label: "text", icon: "icon" }, scalars: true } },
    requires: ["items"],
  },

  // ── UI kit: text views ────────────────────────────────────────────────────
  Markdown: {
    category: "kit", children: "none", selfEvents: ["link"], summary: "markdown: headings, lists, tasks, quotes, code, tables, images, links",
    props: { text: t("text"), content: t("text"), markdown: t("text"), size: e("compact|default") },
    requires: ["text|content|markdown"],
  },
  LogView: {
    category: "kit", children: "none", notInWidget: true, summary: "log lines with levels in a monospace panel that follows the end",
    props: { lines: t("array", "strings or [{time, level, message, source}]"), data: t("array"), title: t("text"), filter: t("text"), wrap: t("flag"), showTime: t("flag"), lineNumbers: t("flag"), follow: t("flag"), fontSize: t("number"), maxHeight: t("number"), emptyText: t("text") },
    requires: ["lines|data"],
  },
  DiffView: {
    category: "kit", children: "none", notInWidget: true, summary: "the line difference between two texts (or a unified diff)",
    props: { before: t("text"), after: t("text"), old: t("text"), new: t("text"), diff: t("text", "a unified diff"), title: t("text"), file: t("text"), context: t("number"), maxHeight: t("number") },
    requires: ["before|after|old|new|diff"],
  },
  QRCode: {
    category: "kit", children: "none", summary: "a QR code of a URL or text",
    props: { data: t("text"), value: t("text"), text: t("text"), url: t("text"), size: t("number"), ecc: e("L|M|Q|H"), color: t("color"), background: t("color"), rounded: t("flag"), label: t("text") },
    requires: ["data|value|text|url"],
  },
};

// Chart routes these types to their own nodes, so it takes their props too.
export const CHART_ROUTES = { funnel: "Funnel", waterfall: "Waterfall", sankey: "Sankey", gantt: "Gantt", boxplot: "BoxPlot", box: "BoxPlot", sunburst: "Sunburst",
  bullet: "BulletChart", segmented: "SegmentedBar", stackedbar: "SegmentedBar", radialbar: "RadialBars", rings: "RadialBars", calendar: "CalendarHeatmap", wordcloud: "WordCloud" };
for (const t of new Set(Object.values(CHART_ROUTES))) TYPES.Chart.props = { ...TYPES[t].props, ...TYPES.Chart.props };
TYPES.Chart.requires = ["data|values|rows|links|items|edges|tasks|words"];

// Layout facts, measured: app/test/elpian/dsl_layout_test.dart renders every
// node directly in a Row, in a vertical and in a horizontal scroll, and checks
// these lists are exactly the nodes that throw there.
export const LAYOUT = {
  // Throw without a width bound (directly in a Row, in a horizontal scroll).
  needsWidth: ["AppBar", "GridView", "LinearProgressIndicator", "ListGroup", "ListTile", "ListView", "NavigationBar", "OverflowBox", "Scaffold", "SearchBar", "TextField"],
  // Throw without a height bound (inside a vertical scroll).
  needsHeight: ["Drawer", "OverflowBox", "Scaffold"],
  // UI kit views that take a fixed fallback width there instead of throwing
  // (WidthFallback in kit.dart): fine, but they do not fill the space.
  fallbackWidth: ["Chart", "DataGrid", "Heatmap", "Treemap", "Graph", "Timeline", "TreeView", "KeyValue", "CodeBlock", "Section", "Expandable", "Callout",
    "Funnel", "Waterfall", "Sankey", "Gantt", "BoxPlot", "BulletChart", "SegmentedBar", "Sunburst", "CalendarHeatmap", "WordCloud", "PivotTable", "Leaderboard",
    "Tabs", "Calendar", "Carousel", "Stepper", "Chat", "Markdown", "LogView", "DiffView"],
  // Must be the direct child of one of these.
  parents: { Expanded: ["Row", "Column"], Flexible: ["Row", "Column"], Spacer: ["Row", "Column"], Positioned: ["Stack"], AnimatedPositioned: ["Stack"] },
};
for (const t of LAYOUT.needsWidth) TYPES[t].needsWidth = true;
for (const t of LAYOUT.needsHeight) TYPES[t].needsHeight = true;
for (const t of LAYOUT.fallbackWidth) TYPES[t].fallbackWidth = true;
for (const [t, parents] of Object.entries(LAYOUT.parents)) TYPES[t].parents = parents;

// HTML-named nodes render too, but app UI should use the Flutter and kit
// nodes: they are drawn leniently (any props) and flagged as a design issue.
export const HTML_DOC = "an HTML-named element (renders, but prefer the Flutter/M3E nodes)";

// Nodes that do not belong on a glanceable phone widget.
export const NOT_IN_WIDGET = ["DataGrid", "PivotTable", "Calendar", "Kanban", "Chat", "LogView", "DiffView", "Tabs", "Pagination", "Breadcrumbs", "ListView", "GridView", "TextField", "SearchBar", "NavigationBar", "SegmentedButton", "ListGroup",
  "Scaffold", "AppBar", "Drawer", "textarea", "input", "form", "table"];
export const WIDGET_MAX_NODES = 80;

// Nodes that put their children in a vertical (unbounded-height) column.
export const VERTICAL_STACKERS = new Set(["Column", "ListView", "GridView", "Card", "ListGroup", "Section", "Expandable", "Callout", "Drawer", "StaggeredAnimation", "Scroll", "Wrap", "ResponsiveGrid"]);
