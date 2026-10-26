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
    const report = await check(fs.readFileSync(out.target, "utf8"), { server: url });
    assert.equal(report.ok, true, report.errors.join("\n"));
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
  assert.deepEqual(types(md).filter((t) => t === "Text").length >= 4, true);
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
  const registered = new Set([...engine.matchAll(/_registry\.register\('([^']+)'/g)].map((m) => m[1]));
  const kitNodes = new Set([...kitSrc.matchAll(/^\s+'([A-Z][A-Za-z]+)':\s*\(/gm)].map((m) => m[1]));
  assert.deepEqual([...new Set([...NODES.elpian, ...NODES.html])].sort(), [...registered].sort());
  assert.deepEqual([...NODES.kit].sort(), [...kitNodes].sort());
  const doc = fs.readFileSync(path.join(kit, "ELPIAN.md"), "utf8");
  for (const n of [...NODES.elpian, ...NODES.kit]) assert.ok(doc.includes("`" + n + "`"), `ELPIAN.md does not document ${n}`);
});
