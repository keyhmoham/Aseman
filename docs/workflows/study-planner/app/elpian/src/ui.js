/* Building blocks drawn right to left: the client lays rows out left to
 * right, so rows are written in reading order and reversed here, and texts
 * align to the right. */

function compact() { return Aseman.viewport().sizeClass === "compact"; }
function dark() { var t = (Aseman.env().theme || {}); return t.mode === "dark"; }
function colors() { return (Aseman.env().theme || {}).colors || {}; }

function T(text, variant, more) {
  var p = { text: String(text == null ? "" : text), variant: variant || "bodyMedium", textAlign: "right" };
  for (var k in more || {}) p[k] = more[k];
  return { type: "Text", props: p };
}
function W(text, variant, more) { // white text on the night sky
  var p = more || {};
  p.style = Object.assign({ color: "#ffffff" }, p.style || {});
  return T(text, variant, p);
}
function R(children, style) {
  var list = [];
  for (var i = 0; i < children.length; i++) if (children[i]) list.push(children[i]);
  list.reverse();
  return { type: "Row", props: { style: Object.assign({ gap: "12", alignItems: "center" }, style || {}) }, children: list };
}
function C(children, style) {
  return { type: "Column", props: { style: Object.assign({ gap: "8", alignItems: "stretch" }, style || {}) }, children: children.filter(Boolean) };
}
function X(child, flex) { return { type: "Expanded", props: flex ? { flex: flex } : {}, children: [child] }; }
function box(style, children) { return { type: "Container", props: { style: style }, children: children || [] }; }
function dot(color, size) { var s = String(size || 10); return box({ width: s, height: s, borderRadius: String((size || 10) / 2), backgroundColor: color }); }
function card(children, style, more) {
  var p = Object.assign({ variant: "filled", style: Object.assign({ padding: "16", gap: "10" }, style || {}) }, more || {});
  return { type: "Card", props: p, children: [C(children, { gap: (style && style.gap) || "10" })] };
}
function sectionTitle(text, small) {
  return R([X(T(text, "titleMediumEmphasized")), small ? T(small, "labelMedium", { color: "muted" }) : null]);
}
function pill(text, color) {
  return box({ padding: "2 10", borderRadius: "999", backgroundColor: color || BRAND.primary }, [T(text, "labelSmall", { style: { color: "#ffffff" } })]);
}

// The night-sky band of the header and the hero text under it.
function sky(children, pad) {
  return box({ gradient: BRAND.sky, padding: pad || "16 16 24 16", borderRadius: "28" }, [C(children, { gap: "10" })]);
}

// The four destinations: a NavigationBar on phones, a segmented bar on desk windows.
var NAV = [
  { id: "home", label: "امروز", icon: "home" },
  { id: "calendar", label: "تقویم", icon: "calendar_month" },
  { id: "plan", label: "برنامه", icon: "bar_chart" },
  { id: "new", label: "برنامه‌ی تازه", icon: "auto_awesome" },
];
function navItems() { return NAV.slice().reverse(); } // right to left
function navIndex(view) { var items = navItems(); for (var i = 0; i < items.length; i++) if (items[i].id === view) return i; return items.length - 1; }

function brandRow(s, app) {
  var nav = null;
  if (!compact()) {
    nav = { type: "SegmentedButton", key: "topnav", props: { selected: s.view, segments: navItems().map(function (n) { return { value: n.id, label: n.label, icon: n.icon }; }) },
      events: { change: app.handler("topnav", function (e, app) { go(e.value); }) } };
  }
  return R([
    R([{ type: "Icon", props: { icon: "auto_awesome", size: 26, style: { color: BRAND.star } } }, W((s.meta && s.meta.product) || "آسمان‌درس", "titleLargeEmphasized")], { gap: "8" }),
    { type: "Spacer" },
    nav,
  ]);
}
