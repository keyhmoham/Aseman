// node --test deploy/sandbox-computer/appui/elpian/test/validate.test.mjs
// The UI DSL validator: in sync with the Flutter engine, right about what
// breaks, quiet about what works, and reachable as a CLI and an MCP server.
import test from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { validate, describe } from "../validate.mjs";
import { TYPES, STYLE, COMMON_PROPS } from "../schema.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const kit = path.resolve(here, "..");
const repo = path.resolve(kit, "../../../..");
const dart = (p) => fs.readFileSync(path.join(repo, "app/lib/src", p), "utf8");
const NODES = JSON.parse(fs.readFileSync(path.join(kit, "nodes.json"), "utf8"));

const codes = (r, severity) => r.issues.filter((i) => !severity || i.severity === severity).map((i) => i.code);
const errorsOf = (tree, opts) => codes(validate(tree, { design: false, ...opts }), "error");
const T = (text) => ({ type: "Text", props: { text } });

// ── in sync with the engine ─────────────────────────────────────────────────

test("the schema knows exactly the node types the engine draws", () => {
  const drawn = new Set([...NODES.elpian, ...NODES.kit]);
  assert.deepEqual(Object.keys(TYPES).sort(), [...drawn].sort());
});

test("icons.json is the icon map of the Icon node", () => {
  const src = dart("elpian/widgets/elpian_icon.dart");
  const map = src.slice(src.indexOf("_iconMap = {"));
  const keys = [...new Set([...map.matchAll(/^\s+'(\w+)': Icons\./gm)].map((m) => m[1]))].sort();
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(kit, "icons.json"), "utf8")).icons, keys);
});

test("every prop an Elpian builder reads is in the schema", () => {
  const engine = dart("elpian/core/elpian_engine.dart");
  const regs = [...engine.matchAll(/_registry\.register\(\s*'([^']+)',\s*(\w+)\.build\)/g)].map((m) => ({ type: m[1], cls: m[2] }));
  const fileOf = {};
  for (const f of fs.readdirSync(path.join(repo, "app/lib/src/elpian/widgets"))) {
    for (const m of dart(`elpian/widgets/${f}`).matchAll(/^class (\w+)/gm)) fileOf[m[1]] = `elpian/widgets/${f}`;
  }
  const byFile = {};
  for (const { type, cls } of regs) if (fileOf[cls] && TYPES[type]) (byFile[fileOf[cls]] = byFile[fileOf[cls]] || []).push(type);
  const missing = [];
  for (const [file, types] of Object.entries(byFile)) {
    const src = dart(file);
    const read = new Set([
      ...[...src.matchAll(/(?:_?props|node\.props|widget\.node\.props)\['(\w+)'\]/g)].map((m) => m[1]),
      ...[...src.matchAll(/(?:textProp|numProp|boolProp)\(\w+(?:\.node)?, '(\w+)'\)/g)].map((m) => m[1]),
    ]);
    const known = new Set([...Object.keys(COMMON_PROPS), ...types.flatMap((t) => Object.keys(TYPES[t].props || {}))]);
    for (const p of read) if (!known.has(p)) missing.push(`${file}: ${p} (${types.join(", ")})`);
  }
  assert.deepEqual(missing, [], "props the builders read but the validator would call unknown");
});

test("every prop the UI kit reads is in the schema of some kit node", () => {
  const dir = path.join(repo, "app/lib/src/features/tools/ui_kit");
  const files = [...fs.readdirSync(dir).filter((f) => f.endsWith(".dart")), ...fs.readdirSync(path.join(dir, "charts")).map((f) => `charts/${f}`)];
  const kitProps = new Set(Object.entries(TYPES).filter(([, s]) => s.category === "kit").flatMap(([, s]) => Object.keys(s.props || {})));
  const missing = new Set();
  for (const f of files) {
    for (const m of fs.readFileSync(path.join(dir, f), "utf8").matchAll(/(?<![\w.])(?:widget\.)?props\['(\w+)'\]/g)) if (!kitProps.has(m[1]) && !COMMON_PROPS[m[1]]) missing.add(`${f}: ${m[1]}`);
  }
  assert.deepEqual([...missing], []);
});

test("every style key the CSS parser reads is in the schema, and nothing else", () => {
  const src = dart("elpian/css/css_parser.dart");
  const body = src.slice(src.indexOf("static CSSStyle _parseUncached"));
  const read = new Set([...body.slice(0, body.indexOf("\n  }\n")).matchAll(/styleMap\['([\w-]+)'\]/g)].map((m) => m[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase())));
  for (const base of ["padding", "margin"]) for (const s of ["", "Top", "Right", "Bottom", "Left", "X", "Y"]) read.add(base + s);
  const widgetsRead = ["gradientColors"]; // read by AnimatedGradient
  const missing = [...read].filter((k) => !STYLE[k]);
  const extra = Object.keys(STYLE).filter((k) => !read.has(k) && !widgetsRead.includes(k));
  assert.deepEqual(missing, [], "style keys the parser reads but the validator would call unknown");
  assert.deepEqual(extra, [], "style keys the validator accepts but the parser never reads");
});

// ── quiet about what works ──────────────────────────────────────────────────

test("real screens validate clean: the showcase app's renders", () => {
  const renders = JSON.parse(fs.readFileSync(path.join(repo, "app/test/elpian/fixtures/showcase_renders.json"), "utf8"));
  for (const [screen, tree] of Object.entries(renders)) {
    const r = validate(tree);
    assert.equal(r.errors + r.warnings, 0, `${screen}:\n${r.issues.map((i) => i.message).join("\n")}`);
  }
});

test("every OpenUI component renders to valid Elpian (no errors)", () => {
  const ctx = { console };
  ctx.globalThis = ctx;
  ctx.askHost = () => JSON.stringify({ type: "object", data: { value: {} } });
  vm.createContext(ctx);
  for (const f of ["aseman-elpian.js", "openui-elpian.js"]) vm.runInContext(fs.readFileSync(path.join(kit, f), "utf8"), ctx);
  const app = { state: {}, render() {}, handler: (k) => "h_" + k.replace(/\W/g, "_") };
  const sample = { title: "T", label: "L", value: "3", text: "x", content: "# H\n- a", name: "f", items: [{ label: "a", value: "a" }, { label: "b", value: "b" }],
    labels: ["a", "b"], values: [1, 2], columns: [{ c: "Col", p: { header: "h", data: [1, 2] } }], steps: [{ title: "s" }], suggestions: ["more"],
    options: [{ label: "o", value: "o" }], headers: ["A"], rows: [{ feature: "f", values: [1] }], days: [1, 2], names: ["Ann", "Bo"], icon: "star" };
  const bad = [];
  for (const c of ctx.OpenUI.components()) {
    const node = JSON.parse(JSON.stringify(ctx.OpenUI.render({ c, p: sample, children: [T("child")] }, { app })));
    const r = validate({ type: "ListView", children: [{ type: "Column", children: [node] }] }, { design: false });
    for (const i of r.issues) if (i.severity === "error") bad.push(`${c}: ${i.message}`);
  }
  assert.deepEqual(bad, []);
});

test("correct layouts are not flagged", () => {
  const ok = [
    { type: "Row", children: [{ type: "Expanded", children: [{ type: "TextField", key: "a", props: { label: "Name" } }] }, { type: "Button", props: { text: "Go" } }] },
    { type: "Row", props: { style: { width: 320 } }, children: [{ type: "Expanded", children: [T("x")] }] },
    { type: "Column", children: [{ type: "Expanded", children: [{ type: "ListView", children: [T("a")] }] }] },
    { type: "ListView", children: [{ type: "Column", props: { style: { height: 300 } }, children: [{ type: "Expanded", children: [{ type: "DataGrid", props: { data: [{ a: 1 }] } }] }] }] },
    { type: "Row", children: [{ type: "Expanded", children: [{ type: "Row", children: [{ type: "Expanded", children: [{ type: "Chart", props: { data: [{ x: 1, y: 2 }], x: "x", y: "y" } }] }] }] }] },
    { type: "Stack", children: [{ type: "Positioned", props: { style: { top: 0 } }, children: [T("x")] }] },
    { type: "Scaffold", children: [{ type: "AppBar", props: { title: "T" } }, { type: "ListView", children: [{ type: "ListGroup", children: [{ type: "ListTile", props: { title: "x" } }] }] }, { type: "FAB", props: { icon: "add" } }] },
    { type: "Row", children: [{ type: "Stat", props: { label: "L", value: 3 } }, { type: "Progress", props: { value: 0.3 } }, { type: "Spacer" }, { type: "IconButton", props: { icon: "close", tooltip: "Close" } }] },
  ];
  for (const tree of ok) {
    const r = validate(tree);
    assert.deepEqual(codes(r).filter((c) => !c.startsWith("design") && !c.startsWith("a11y")), [], JSON.stringify(tree));
  }
});

// ── right about what breaks ─────────────────────────────────────────────────

test("node shape: types, top-level keys, children", () => {
  assert.deepEqual(errorsOf({ type: "Fancy" }), ["type-unknown"]);
  assert.match(validate({ type: "Colum" }).issues[0].message, /Did you mean `Column`/);
  assert.deepEqual(errorsOf({ props: {} }), ["type-missing"]);
  assert.deepEqual(errorsOf({ type: "Card", child: T("x") }), ["shape-child"]);
  assert.deepEqual(errorsOf({ type: "Button", onTap: "go", props: { text: "Go" } }), ["shape-handler"]);
  assert.deepEqual(errorsOf({ type: "Text", text: "hi" }), ["shape-prop"]);
  assert.deepEqual(errorsOf({ type: "Column", children: [T("a"), null, "b", false] }), ["child-not-node", "child-not-node", "child-not-node"]);
  assert.deepEqual(errorsOf({ type: "Column", children: T("a") }), ["children-not-array"]);
  assert.deepEqual(codes(validate({ type: "Text", props: { text: "a" }, children: [T("b")] }), "warning"), ["children-ignored"]);
  assert.deepEqual(codes(validate({ type: "Center", children: [T("a"), T("b")] }), "warning"), ["children-dropped"]);
});

test("props: types where builders cast, enums, ranges, unknowns", () => {
  assert.deepEqual(errorsOf({ type: "Switch", key: "s", props: { value: "true" } }), ["prop-type"]);
  assert.deepEqual(errorsOf({ type: "TextField", props: { hint: 42 } }), ["prop-type"]);
  assert.deepEqual(errorsOf({ type: "Row", children: [{ type: "Expanded", props: { flex: "2" }, children: [T("x")] }] }), []);
  assert.deepEqual(errorsOf({ type: "TextField", props: { maxLines: "3" } }), ["prop-type"]);
  assert.deepEqual(codes(validate({ type: "Row", children: [{ type: "Expanded", props: { flex: 0 }, children: [T("x")] }] })), ["prop-range"]);
  assert.deepEqual(errorsOf({ type: "Opacity", props: { opacity: 2 }, children: [T("x")] }), ["prop-range"]);
  assert.deepEqual(errorsOf({ type: "AnimatedSwitcher", props: { transitionType: 1 }, children: [T("x")] }), ["prop-type"]);
  assert.deepEqual(errorsOf({ type: "Slider", key: "s", props: { min: 5, max: 1 } }), ["prop-value"]);
  assert.deepEqual(errorsOf({ type: "Button", props: { text: "Go" }, events: { tap: "go" } }), []);
  const unknown = validate({ type: "Button", props: { text: "Go", varient: "tonal", onPress: "x" } });
  assert.deepEqual(codes(unknown), ["prop-unknown", "prop-handler"]);
  assert.match(unknown.issues[0].message, /Did you mean `variant`/);
  assert.deepEqual(codes(validate({ type: "Button", props: { text: "Go", variant: "primaryy" } })), ["prop-enum"]);
  assert.deepEqual(codes(validate({ type: "Icon", props: { icon: "hom" } })), ["icon-unknown"]);
  assert.deepEqual(codes(validate({ type: "Icon", props: { icon: "deleteOutline" } })), []);
  assert.deepEqual(codes(validate({ type: "Stat", props: { value: 3, format: "dollars" } })), ["prop-value"]);
  assert.deepEqual(codes(validate({ type: "Text" })), ["prop-missing"]);
  assert.deepEqual(codes(validate({ type: "Container", props: { padding: "16" } })), ["prop-dart-only"]);
  assert.deepEqual(codes(validate({ type: "NavigationBar", props: { items: [{ icon: "home", label: "a" }, { icon: "nope", label: "b" }] } }, { design: false })), ["icon-unknown"]);
});

test("data fields named by charts and grids exist on the rows", () => {
  const rows = [{ month: "Jan", revenue: 3 }];
  assert.deepEqual(codes(validate({ type: "Chart", props: { data: rows, x: "month", y: "revenue" } })), []);
  assert.deepEqual(codes(validate({ type: "Chart", props: { data: rows, x: "date", series: ["revenue", "cost"] } })), ["field-missing", "field-missing"]);
  assert.deepEqual(codes(validate({ type: "DataGrid", props: { data: rows, columns: [{ field: "month" }, { field: "revnue" }] } })), ["field-missing"]);
  assert.deepEqual(codes(validate({ type: "PivotTable", props: { data: rows, rows: "month", columns: "region", value: "revenue" } })), ["field-missing"]);
  assert.deepEqual(codes(validate({ type: "Gantt", props: { data: [{ task: "a", from: "2026-01-01" }], start: "begin" } })), ["field-missing"]);
});

test("styles: keys, units, radii, colors, cast strings", () => {
  const s = (style) => validate({ type: "Container", props: { style } });
  assert.deepEqual(codes(s({ padding: "8 16", gap: 12, borderRadius: "16", backgroundColor: "#fff", width: "50%" })), []);
  assert.deepEqual(codes(s({ colour: "red" })), ["style-unknown"]);
  assert.match(s({ paddingHorizontal: 8 }).issues[0].message, /paddingX/);
  assert.deepEqual(codes(s({ borderRadius: "16 16 0 0" }), "error"), ["style-value"]);
  assert.deepEqual(codes(s({ padding: -4 }), "error"), ["style-value"]);
  assert.deepEqual(codes(s({ justifyContent: 1 }), "error"), ["style-value"]);
  assert.deepEqual(codes(s({ visible: "false" }), "error"), ["style-value"]);
  assert.deepEqual(codes(s({ width: "10rem" }), "warning"), ["style-value"]);
  assert.deepEqual(codes(s({ color: "bluish" }), "warning"), ["style-value"]);
  assert.deepEqual(codes(s({ border: "1px solid #ccc" }), "warning"), ["style-value"]);
  assert.deepEqual(codes(s({ "background-color": "#000" })), []);
  assert.deepEqual(errorsOf({ type: "Text", props: { text: "x", style: "padding: 4px" } }), ["style-not-object"]);
  const theme = { colors: { primary: "#6750A4" } };
  assert.deepEqual(codes(validate({ type: "Container", props: { style: { backgroundColor: "#6750a4" } } }, { theme })), []);
  assert.deepEqual(codes(validate({ type: "Container", props: { style: { backgroundColor: "#123456" } } }, { theme })), ["design-hardcoded-color"]);
});

test("events and keys", () => {
  assert.deepEqual(errorsOf({ type: "Button", props: { text: "x" }, events: { tap: 3 } }), ["event-handler"]);
  assert.deepEqual(errorsOf({ type: "Button", props: { text: "x" }, events: "tap" }), ["events-not-object"]);
  assert.deepEqual(codes(validate({ type: "Button", props: { text: "x" }, events: { press: "go" } })), ["event-unknown"]);
  assert.deepEqual(codes(validate({ type: "Text", props: { text: "x" }, events: { tap: "go", swipeleft: "back" } })), []);
  assert.deepEqual(errorsOf({ type: "Text", key: 3, props: { text: "x" } }), ["key-type"]);
  assert.deepEqual(errorsOf({ type: "Column", children: [{ ...T("a"), key: "k" }, { ...T("b"), key: "k" }] }), ["key-duplicate-sibling"]);
  assert.deepEqual(errorsOf({ type: "Column", children: [{ type: "Card", children: [{ type: "Button", key: "go", props: { text: "a" }, events: { tap: "a" } }] }, { type: "Button", key: "go", props: { text: "b" }, events: { tap: "b" } }] }), ["key-duplicate"]);
  assert.deepEqual(codes(validate({ type: "TextField", props: { label: "n" }, events: { input: "n" } })), ["key-missing"]);
});

test("parents and parent data", () => {
  assert.deepEqual(errorsOf({ type: "Card", children: [{ type: "Expanded", children: [T("x")] }] }), ["parent-invalid"]);
  assert.deepEqual(errorsOf({ type: "Column", children: [{ type: "Positioned", children: [T("x")] }] }), ["parent-invalid"]);
  assert.deepEqual(errorsOf({ type: "Positioned", children: [T("x")] }), ["parent-invalid"]);
  assert.deepEqual(errorsOf({ type: "Row", children: [{ type: "Expanded", events: { tap: "go" }, children: [T("x")] }] }), ["parent-data-events"]);
  assert.deepEqual(errorsOf({ type: "Row", props: { style: { flexWrap: "wrap" } }, children: [{ type: "Expanded", children: [T("x")] }] }), ["flex-in-wrap"]);
  assert.deepEqual(codes(validate({ type: "Scaffold", children: [{ type: "Scaffold" }] }), "warning"), ["scaffold-nested"]);
});

test("layout: what throws without a bound", () => {
  assert.deepEqual(errorsOf({ type: "Row", children: [{ type: "TextField" }] }), ["layout-unbounded-width"]);
  assert.deepEqual(errorsOf({ type: "Row", children: [{ type: "Column", children: [{ type: "ListTile", props: { title: "t" } }] }] }), ["layout-unbounded-width"]);
  assert.deepEqual(errorsOf({ type: "ListView", props: { scrollDirection: "horizontal" }, children: [{ type: "TextField" }] }), ["layout-unbounded-width"]);
  // UI kit views take a fallback width there: a warning, not an error.
  assert.deepEqual(codes(validate({ type: "Row", children: [{ type: "Chart", props: { data: [1, 2] } }] }, { design: false })), ["layout-fallback-width"]);
  assert.deepEqual(codes(validate({ type: "Row", children: [{ type: "Expanded", children: [{ type: "Chart", props: { data: [1, 2] } }] }] }, { design: false })), []);
  assert.deepEqual(errorsOf({ type: "Row", children: [{ type: "TextField", props: { style: { width: 200 } } }] }), []);
  assert.deepEqual(errorsOf({ type: "ListView", children: [{ type: "Column", children: [{ type: "Expanded", children: [T("x")] }] }] }), ["layout-flex-unbounded"]);
  assert.deepEqual(errorsOf({ type: "Row", children: [{ type: "Row", children: [{ type: "Expanded", children: [T("x")] }] }] }), ["layout-flex-unbounded"]);
  assert.deepEqual(errorsOf({ type: "ListView", children: [{ type: "Scaffold" }] }), ["layout-unbounded-height"]);
  assert.deepEqual(errorsOf({ type: "Column", children: [{ type: "Spacer" }] }), []);
  assert.deepEqual(errorsOf({ type: "Column", children: [{ type: "Spacer" }] }, { root: "scroll" }), ["layout-flex-unbounded"]);
  // Unmodelled (HTML) parents are not guessed at.
  assert.deepEqual(errorsOf({ type: "div", children: [{ type: "TextField" }] }), []);
});

test("the phone widget is glanceable", () => {
  const w = (tree) => errorsOf(tree, { mode: "widget" });
  assert.deepEqual(w({ type: "Row", children: [{ type: "Expanded", children: [{ type: "Stat", props: { label: "L", value: 1 } }] }] }), []);
  assert.deepEqual(w({ type: "Column", children: [{ type: "DataGrid", props: { data: [] } }] }), ["widget-node"]);
  assert.deepEqual(w({ type: "Button", props: { text: "x" }, events: { tap: "go" } }), ["widget-events"]);
  assert.deepEqual(w({ type: "Column", children: Array.from({ length: 90 }, () => T("x")) }), ["widget-size"]);
  assert.deepEqual(w({ type: "Kanban", props: { columns: [] } }), ["widget-node"]);
  assert.deepEqual(w({ type: "Row", children: [{ type: "RadialBars", props: { data: [{ label: "Move", value: 3 }] } }, { type: "Countdown", props: { seconds: 60 } }] }), []);
});

test("design notes: M3 Expressive practice", () => {
  const notes = (tree) => codes(validate(tree), "info").concat(codes(validate(tree), "warning").filter((c) => c.startsWith("design")));
  assert.deepEqual(notes({ type: "Text", props: { text: "x", style: { fontSize: 22, fontWeight: "bold" } } }), ["design-type-role"]);
  assert.deepEqual(notes({ type: "Button", props: { text: "➕ Add" } }), ["design-emoji-icon"]);
  assert.deepEqual(notes({ type: "Row", children: [{ type: "Button", props: { text: "a" } }, { type: "Button", props: { text: "b" } }] }), ["design-filled-buttons"]);
  assert.deepEqual(notes({ type: "Card", children: [{ type: "Card", children: [T("x")] }] }), ["design-nested-card"]);
  assert.deepEqual(notes({ type: "IconButton", props: { icon: "add" } }), ["a11y-tooltip"]);
  assert.deepEqual(notes({ type: "div", children: [T("x")] }), ["design-html"]);
  assert.deepEqual(codes(validate({ type: "div" }, { design: false })), []);
});

test("describe explains a node", () => {
  const d = describe("ListTile");
  assert.match(d, /leadingAvatar/);
  assert.match(d, /needs a bounded width/);
  assert.match(describe("Expanded"), /must be a direct child of: Row or Column/);
  assert.match(describe("Colum"), /Did you mean `Column`/);
});

// ── reachable as a CLI and as an MCP server ─────────────────────────────────

test("the CLI exits 1 on errors and 0 when valid", () => {
  const run = (tree, ...args) => spawnSync(process.execPath, [path.join(kit, "validate.mjs"), "-", ...args], { input: JSON.stringify(tree), encoding: "utf8" });
  const bad = run({ type: "Row", children: [{ type: "TextField" }] });
  assert.equal(bad.status, 1);
  assert.match(bad.stdout, /ERROR \[layout-unbounded-width\] Row > TextField/);
  const good = run({ type: "Column", children: [T("hi")] });
  assert.equal(good.status, 0, good.stdout);
  assert.match(good.stdout, /^VALID/m);
  assert.equal(run({ type: "Text", props: { text: "x", foo: 1 } }, "--strict").status, 1);
  const json = JSON.parse(run({ type: "Fancy" }, "--json").stdout);
  assert.equal(json.ok, false);
  assert.equal(json.issues[0].code, "type-unknown");
  const openui = run({ c: "Card", p: { title: "Hi" }, children: [{ c: "Button", p: { label: "Go", icon: "send" } }] }, "--openui");
  assert.equal(openui.status, 0, openui.stdout);
});

test("the MCP server lists and runs its tools over stdio", async () => {
  const child = spawn(process.execPath, [path.join(kit, "validate-mcp.mjs")], { stdio: ["pipe", "pipe", "inherit"] });
  const replies = new Map();
  let buf = "";
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line.trim()) {
        const m = JSON.parse(line);
        replies.set(m.id, m);
      }
    }
  });
  const send = (m) => child.stdin.write(JSON.stringify(m) + "\n");
  const wait = async (id) => {
    for (let i = 0; i < 200 && !replies.has(id); i++) await new Promise((r) => setTimeout(r, 25));
    return replies.get(id);
  };
  try {
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } } });
    const init = await wait(1);
    assert.equal(init.result.serverInfo.name, "aseman-elpian");
    assert.ok(init.result.capabilities.tools);
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    assert.deepEqual((await wait(2)).result.tools.map((t) => t.name), ["elpian_validate", "elpian_validate_program", "elpian_describe", "elpian_icons"]);
    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "elpian_validate", arguments: { tree: { type: "Row", children: [{ type: "TextField" }] } } } });
    assert.match((await wait(3)).result.content[0].text, /layout-unbounded-width/);
    send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "elpian_describe", arguments: { types: ["SegmentedButton"] } } });
    assert.match((await wait(4)).result.content[0].text, /segments/);
    send({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "elpian_icons", arguments: { query: "calendar" } } });
    assert.match((await wait(5)).result.content[0].text, /calendar_month/);
    const bundle = path.join(fs.mkdtempSync(path.join(kit, "..", ".tmp-")), "app.js");
    fs.writeFileSync(bundle, ["aseman-elpian.js", "openui-elpian.js"].map((f) => fs.readFileSync(path.join(kit, f), "utf8")).join("\n;\n") +
      `\n;App.create({ view: function () { return { type: "Row", children: [{ type: "TextField", props: { hint: "q" } }] }; },
        widget: { static: true, view: function () { return { type: "Stat", props: { label: "L", value: 1 } }; } } });`);
    send({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "elpian_validate_program", arguments: { bundle } } });
    const prog = (await wait(6)).result.content[0].text;
    fs.rmSync(path.dirname(bundle), { recursive: true });
    assert.match(prog, /as the app[\s\S]*layout-unbounded-width/);
    assert.match(prog, /as the phone widget[\s\S]*VALID/);
    assert.match(prog, /Program INVALID/);
    send({ jsonrpc: "2.0", id: 7, method: "nope" });
    assert.equal((await wait(7)).error.code, -32601);
  } finally {
    child.stdin.end();
    child.kill();
  }
});

test("errors mean the tree breaks: shared cases with the Flutter test", () => {
  const { cases } = JSON.parse(fs.readFileSync(path.join(repo, "app/test/elpian/fixtures/validator_cases.json"), "utf8"));
  const wrong = [];
  for (const c of cases) {
    const r = validate(c.tree, { design: false });
    const verdict = r.errors ? "error" : r.warnings ? "warning" : "clean";
    if (verdict !== c.validator) wrong.push(`${c.name}: ${verdict}, expected ${c.validator} (${r.issues.map((i) => i.code).join(", ")})`);
  }
  assert.deepEqual(wrong, []);
});
