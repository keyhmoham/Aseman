// node --test deploy/sandbox-computer/appui/elpian/test/
// Needs quickjs-emscripten (deploy/tool-runtime: npm install).
import test from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { bundle } from "../bundle.mjs";
import { check } from "../check.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const kit = path.resolve(here, "..");
const repo = path.resolve(kit, "../../../..");
const NODES = JSON.parse(fs.readFileSync(path.join(kit, "nodes.json"), "utf8"));
const KNOWN = new Set([...NODES.elpian, ...NODES.html, ...NODES.kit]);

function project(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "elpian-"));
  fs.mkdirSync(path.join(dir, "elpian", "src"), { recursive: true });
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, "elpian", "src", name), body);
  return dir;
}

const TODO = `
var app = App.create({
  state: { items: [], draft: "" },
  view: function (s, app) {
    return { type: "Column", props: { style: { padding: "16", gap: "12" } }, children: [
      { type: "Text", props: { text: "Todos", style: { fontSize: "22", fontWeight: "bold" } } },
      app.input("draft", "draft", { hint: "What needs doing?" }),
      { type: "Button", props: { text: "Add" }, events: { tap: app.handler("add", add) } },
      { type: "DataGrid", props: { data: s.items, columns: [{ field: "title" }] } },
      OpenUI.panel(app, "advice", { agent: "assistant", title: "Advice", prompt: "Plan {{n}} todos", vars: { n: s.items.length } }),
    ] };
  },
  init: function (app) { load(); },
  widget: {
    size: "medium",
    view: function (s) {
      return { type: "Row", props: { style: { gap: "12", padding: "12" } }, children: [
        { type: "Stat", props: { label: "Open todos", value: s.items.length, size: "compact" } },
        { type: "Sparkline", props: { values: [1, 2, s.items.length] } },
      ] };
    },
    refresh: function () { load(); },
    refreshMs: 30000,
  },
});
function load() {
  Aseman.fetch("api/todos").then(function (r) { app.set({ items: r.json.items }); });
}
function add(e, app) {
  if (!app.state.draft) return;
  Aseman.fetch("api/todos", { method: "POST", body: { title: app.state.draft } }).then(load);
  app.set({ draft: "" });
}
`;

function server() {
  const items = [{ title: "first" }];
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      if (req.url === "/api/todos" && req.method === "POST") items.push(JSON.parse(body));
      if (req.url.startsWith("/api/todos")) {
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ items }));
      }
      res.writeHead(404);
      res.end("{}");
    });
  });
  return new Promise((r) => srv.listen(0, "127.0.0.1", () => r({ srv, items, url: `http://127.0.0.1:${srv.address().port}` })));
}

test("a bundled app runs on QuickJS against its own server and the space", async () => {
  const dir = project({ "main.js": TODO });
  const out = bundle(dir);
  assert.deepEqual(out.files.slice(0, 2), ["aseman-elpian.js", "openui-elpian.js"]);
  const { srv, items, url } = await server();
  try {
    const report = await check(fs.readFileSync(out.target, "utf8"), { server: url, widget: true });
    assert.equal(report.ok, true, report.errors.join("\n"));
    assert.deepEqual(report.widget.hint, { view: "self", size: "medium", shape: "card", static: false });
    assert.ok(report.widget.requests >= 2, "the widget loads, then refreshes, its live data");
    assert.ok(report.renders >= 3, "renders after data and the agent's answer arrive");
    assert.ok(report.handlers >= 2);
    assert.ok(items.length >= 1);
  } finally {
    srv.close();
  }
});

const SDK = ["aseman-elpian.js", "openui-elpian.js"].map((f) => fs.readFileSync(path.join(kit, f), "utf8")).join("\n;\n");

test("the check names what would break", async () => {
  const report = await check(SDK + `
    App.create({ view: function (s, app) { return { type: "Column", children: [
      { type: "Fancy", props: {} },
      { type: "Button", props: { text: "x" }, events: { tap: "nowhere" } },
      { type: "Button", props: { text: "y" }, events: { tap: app.handler("boom", function () { throw new Error("kaput"); }) } },
    ] }; } });
    askHost("dom.window", "");
  `);
  assert.equal(report.ok, false);
  const all = report.errors.join("\n");
  assert.match(all, /"Fancy" is not drawn/);
  assert.match(all, /"nowhere", which is not a global function/);
  assert.match(all, /kaput/);
  assert.match(report.warnings.join("\n"), /dom\.window/);
  const silent = await check("var x = 1;");
  assert.match(silent.errors.join("\n"), /never rendered/);
});

// Loads the SDK in a plain JS context with a recording host.
function sdk() {
  const renders = [];
  const ctx = { console };
  ctx.globalThis = ctx;
  ctx.askHost = (api, payload) => {
    if (api === "render") renders.push(JSON.parse(payload));
    return JSON.stringify({ type: "object", data: { value: { accepted: true } } });
  };
  vm.createContext(ctx);
  for (const f of ["aseman-elpian.js", "openui-elpian.js"]) vm.runInContext(fs.readFileSync(path.join(kit, f), "utf8"), ctx);
  return { ctx, renders };
}

function types(node, out = []) {
  if (!node || typeof node !== "object") return out;
  out.push(node.type);
  (node.children || []).forEach((c) => types(c, out));
  return out;
}

test("every OpenUI component of the web catalog renders as Elpian nodes", () => {
  const spec = JSON.parse(fs.readFileSync(path.join(kit, "..", "openui", "catalog.spec.json"), "utf8"));
  const names = Array.isArray(spec.components) ? spec.components.map((c) => c.name) : Object.keys(spec.components);
  const { ctx } = sdk();
  const rendered = new Set(ctx.OpenUI.components());
  const missing = names.filter((n) => !rendered.has(n));
  assert.deepEqual(missing, [], "components the Elpian OpenUI does not render");
  const sample = { title: "T", label: "L", value: "3", text: "x", content: "# H\n- a\n- b\n\n```js\nx\n```", name: "f",
    items: [{ label: "a", value: "a" }, { label: "b", value: "b" }], labels: ["a", "b"], values: [1, 2],
    columns: [{ c: "Col", p: { header: "h", data: [1, 2] } }], steps: [{ title: "s" }], suggestions: ["more"],
    options: [{ label: "o", value: "o" }], headers: ["A"], rows: [{ feature: "f", values: [1] }], days: [1, 2], names: ["Ann", "Bo"],
    pros: ["p"], cons: ["c"], images: ["a.png"], slides: ["a.png"], code: "x", tone: "neutral" };
  for (const c of names) {
    const node = ctx.OpenUI.render({ c, p: sample, children: [{ c: "Text", p: { text: "child" } }] });
    for (const t of types(node)) assert.ok(KNOWN.has(t), `${c} renders unknown node type ${t}`);
    assert.doesNotMatch(JSON.stringify(node), /Could not show this part/, `${c} failed to render`);
  }
});

test("agent replies become OpenUI or markdown nodes", () => {
  const { ctx } = sdk();
  const card = ctx.OpenUI.fromReply('Here:\n```openui\n{"c":"Stat","p":{"label":"Users","value":"42"}}\n```');
  assert.equal(card.type, "Stat");
  const md = ctx.OpenUI.fromReply("# Plan\n\n1. one\n2. two\n\nDone **now**.");
  assert.equal(md.type, "Markdown");
  assert.match(md.props.text, /Done \*\*now\*\*/);
  assert.equal(ctx.OpenUI.tryParse("no json"), null);
});

test("requests settle tasks, and failures reach catch", () => {
  const { ctx } = sdk();
  let got = null;
  let failed = null;
  ctx.Aseman.ask("a", "hi").then((r) => (got = r.reply));
  ctx.Aseman.call("t", "m", {}).catch((e) => (failed = e.message + ":" + e.status));
  ctx.__asemanSettle(JSON.stringify({ id: "r1", ok: true, data: { reply: "hello" } }));
  ctx.__asemanSettle({ id: "r2", ok: false, status: 402, error: "insufficient funds" });
  assert.equal(got, "hello");
  assert.equal(failed, "insufficient funds:402");
});

test("nodes.json lists exactly what the engine and the UI kit draw", () => {
  const engine = fs.readFileSync(path.join(repo, "app/lib/src/elpian/core/elpian_engine.dart"), "utf8");
  const kitSrc = fs.readFileSync(path.join(repo, "app/lib/src/features/tools/ui_kit/kit.dart"), "utf8");
  const registered = new Set([...engine.matchAll(/_registry\.register\(\s*'([^']+)'/g)].map((m) => m[1]));
  const kitNodes = new Set([...kitSrc.matchAll(/^\s+'([A-Z][A-Za-z]+)':\s*\(/gm)].map((m) => m[1]));
  assert.deepEqual([...new Set([...NODES.elpian, ...NODES.html])].sort(), [...registered].sort());
  assert.deepEqual([...NODES.kit].sort(), [...kitNodes].sort());
  const doc = fs.readFileSync(path.join(kit, "ELPIAN.md"), "utf8");
  for (const n of [...NODES.elpian, ...NODES.kit]) assert.ok(doc.includes("`" + n + "`"), `ELPIAN.md does not document ${n}`);
});

test("every app ships a glanceable, live phone widget", async () => {
  const none = await check(SDK + `App.create({ view: function () { return { type: "Text", props: { text: "hi" } }; } });`, { widget: true });
  assert.equal(none.ok, false);
  assert.match(none.errors.join("\n"), /widget: the app has no phone widget/);

  const screen = await check(SDK + `App.create({
    view: function () { return { type: "Text", props: { text: "full" } }; },
    widget: function () { return { type: "Column", children: [{ type: "DataGrid", props: { data: [] } }, { type: "TextField", props: {} }] }; },
  });`, { widget: true });
  const all = screen.errors.join("\n");
  assert.match(all, /uses DataGrid, TextField/);
  assert.match(all, /shows no live data/);

  const calm = await check(SDK + `App.create({
    view: function () { return { type: "Text", props: { text: "full" } }; },
    widget: { static: true, view: function () { return { type: "Stat", props: { label: "Timer", value: "25:00" } }; } },
  });`, { widget: true });
  assert.equal(calm.ok, true, calm.errors.join("\n"));

  // The full app is unchanged by having a widget.
  const fullOnly = await check(SDK + `App.create({ view: function () { return { type: "Text", props: { text: "full" } }; },
    widget: function () { return { type: "Text", props: { text: "w" } }; } });`);
  assert.equal(fullOnly.ok, true);
});

test("the Material 3 Expressive showcase passes the check, as an app and as a widget", async () => {
  const tasks = [
    { id: 1, title: "Ship", owner: "Ann", due: "today", done: false, priority: "high" },
    { id: 2, title: "Write docs", owner: "Bo", due: "Fri", done: true, priority: "normal" },
  ];
  const srv = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(req.url.startsWith("/api/tasks") ? 200 : 404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ tasks }));
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  try {
    const src = SDK + "\n;\n" + fs.readFileSync(path.join(kit, "examples", "showcase.js"), "utf8");
    const report = await check(src, { server: `http://127.0.0.1:${srv.address().port}`, widget: true });
    assert.equal(report.ok, true, report.errors.join("\n"));
    assert.ok(report.widget.requests >= 1, "the widget loads live data");
  } finally {
    srv.close();
  }
});

test("OpenUI draws M3E buttons and icons, not class names or glyph text", () => {
  const { ctx } = sdk();
  const app = { state: {}, render() {}, handler: (k) => "h_" + k };
  const node = ctx.OpenUI.render({ c: "Stack", children: [
    { c: "Button", p: { label: "Go", icon: "send" } },
    { c: "Button", p: { label: "Later", variant: "secondary" } },
    { c: "Pagination", p: { page: 2, pages: 3 } },
    { c: "Tabs", p: { items: [{ c: "TabItem", p: { trigger: "One" } }, { c: "TabItem", p: { trigger: "Two" } }] } },
    { c: "List", p: { items: [{ label: "Row", icon: "event" }] } },
  ] }, { app });
  const json = JSON.stringify(node);
  assert.doesNotMatch(json, /className/);
  assert.match(json, /"variant":"filled","icon":"send"/);
  assert.match(json, /"variant":"tonal"/);
  for (const t of ["Pagination", "Tabs", "ListGroup", "ListTile"]) assert.ok(types(node).includes(t), `uses ${t}`);
});

test("handler keys never share a name, and trees reach the host without holes", () => {
  const { ctx, renders } = sdk();
  const names = [];
  ctx.App.create({
    view: function (s, app) {
      names.length = 0;
      return { type: "Row", children: ["÷", "×", "−", "+", "=", "a b"].map(function (k) {
        const name = app.handler("key_" + k, function () {});
        names.push(name);
        return { type: "Button", props: { text: k }, events: { tap: name } };
      }).concat([null, undefined, false, "plain", [{ type: "Text", props: { text: "nested" } }]]) };
    },
  });
  assert.equal(new Set(names).size, names.length, `distinct handler names: ${names.join(", ")}`);
  for (const n of names) assert.match(n, /^[A-Za-z_$][\w$]*$/, "a JS identifier");
  assert.equal(ctx.App.prototype.handler.call({ prefix: "p_" }, "save", () => {}), "p_save", "plain keys keep their names");
  const tree = renders[renders.length - 1];
  assert.deepEqual(tree.children.slice(-2), [{ type: "Text", props: { text: "plain" } }, { type: "Text", props: { text: "nested" } }]);
  assert.ok(tree.children.every((c) => c && typeof c === "object"));
});

test("the check explores states and names the steps to a defect", async () => {
  const src = SDK + "\n;\n" + fs.readFileSync(path.join(here, "fixtures", "calculator.js"), "utf8");
  const report = await check(src, { widget: false });
  assert.equal(report.ok, false);
  const all = report.errors.join("\n");
  assert.match(all, /the view threw: cannot read property 'toFixed' of null.*reached after: tap "÷" → tap "="/);
  assert.match(all, /TextField has no width bound.*\[layout-unbounded-width\].*reached after: tap "÷" → tap "="/);
  assert.ok(report.states > 20, `explored ${report.states} states`);
});

test("exploring never floods the app's server with writes", async () => {
  let posts = 0;
  const items = [];
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      if (req.method === "POST") {
        posts++;
        items.push(JSON.parse(body || "{}"));
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ items }));
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  try {
    const report = await check(SDK + `
      var app = App.create({ state: { items: [], n: 0 }, view: function (s, app) { return { type: "Column", children: [
        { type: "Text", props: { text: "Items " + s.items.length + " · " + s.n } },
        { type: "Button", props: { text: "Add" }, events: { tap: app.handler("add", function () {
          Aseman.fetch("api/items", { method: "POST", body: { n: app.state.n } }).then(function (r) { app.set({ items: r.json.items || [] }); });
        }) } },
        { type: "Button", props: { text: "More" }, events: { tap: app.handler("more", function () { app.set({ n: app.state.n + 1 }); }) } },
      ] }; } });`, { server: `http://127.0.0.1:${srv.address().port}`, widget: false });
    assert.equal(report.ok, true, report.errors.join("\n"));
    assert.ok(report.transitions > 10, "it explored");
    assert.ok(posts <= 1, `the server got ${posts} POSTs`);
  } finally {
    srv.close();
  }
});
