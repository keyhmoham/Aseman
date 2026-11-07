/* Aseman Arena — small helpers: view-tree building blocks, time and numbers. */

function compact() { return Aseman.viewport().sizeClass === "compact"; }
function wide() { return Aseman.viewport().sizeClass === "expanded"; }
function colors() { return (Aseman.env().theme || {}).colors || {}; }
function isDark() { return ((Aseman.env().theme || {}).mode) === "dark"; }

function T(text, variant, more) {
  var p = { text: String(text == null ? "" : text), variant: variant || "bodyMedium" };
  for (var k in more || {}) p[k] = more[k];
  return { type: "Text", props: p };
}
function R(children, style) {
  return { type: "Row", props: { style: Object.assign({ gap: "12", alignItems: "center" }, style || {}) }, children: children.filter(Boolean) };
}
function C(children, style) {
  return { type: "Column", props: { style: Object.assign({ gap: "8", alignItems: "stretch" }, style || {}) }, children: children.filter(Boolean) };
}
function X(child, flex) { return { type: "Expanded", props: flex ? { flex: flex } : {}, children: [child] }; }
function box(style, children) { return { type: "Container", props: { style: style }, children: children || [] }; }
function card(children, style, more) {
  var p = Object.assign({ variant: "filled", style: Object.assign({ padding: "16", gap: "10" }, style || {}) }, more || {});
  return { type: "Card", props: p, children: [C(children, { gap: (style && style.gap) || "10" })] };
}
function page(children) {
  return { type: "ListView", children: [C(children, { padding: compact() ? "16" : "24", gap: "20" })] };
}
function title(text, sub, action) {
  return R([X(C([T(text, compact() ? "headlineSmallEmphasized" : "headlineMediumEmphasized"), sub ? T(sub, "bodyMedium", { color: "muted", maxLines: 2 }) : null], { gap: "4" })), action || null], { alignItems: "center" });
}
function section(text, sub, children) {
  return C([R([X(T(text, "titleMediumEmphasized")), sub ? T(sub, "labelMedium", { color: "muted" }) : null]), C(children, { gap: "12" })], { gap: "10" });
}
function swatch(color, size) {
  var s = String(size || 12);
  return box({ width: s, height: s, borderRadius: String((size || 12) / 2), backgroundColor: color });
}

// Numbers and time.
function n(v) {
  v = Number(v || 0);
  if (v >= 1000000) return (v / 1000000).toFixed(1) + "M";
  if (v >= 10000) return Math.round(v / 1000) + "k";
  return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}
function ago(t) {
  var d = Date.now() / 1000 - Number(t || 0);
  if (d < 60) return "now";
  if (d < 3600) return Math.floor(d / 60) + "m";
  if (d < 86400) return Math.floor(d / 3600) + "h";
  return Math.floor(d / 86400) + "d";
}
function signed(v) { v = Number(v || 0); return (v > 0 ? "+" : "") + v; }
function pct(v) { return Math.round(Number(v || 0) * 100) + "%"; }
function plural(k, one, many) { return k + " " + (k === 1 ? one : (many || one + "s")); }
function hex(c, fallback) { return /^#[0-9a-fA-F]{6}$/.test(String(c || "")) ? c : fallback || "#6aa8ff"; }

// A unique key for the handler of a list item.
function hk(prefix, id) { return prefix + "_" + String(id).replace(/[^a-zA-Z0-9_]/g, "_"); }
