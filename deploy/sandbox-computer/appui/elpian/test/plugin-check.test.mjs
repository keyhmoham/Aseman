// node --test deploy/sandbox-computer/appui/elpian/test/plugin-check.test.mjs
// The Elpian half needs quickjs-emscripten (deploy/tool-runtime: npm install);
// the web half needs Chromium (skipped without it).
import test from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { backendFunctions, checkPlugin, chromiumPath, webDocument, WEB_PLUGIN_CSP } from "../plugin-check.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../../../..");

const READING_LIST = `
var app = App.create({
  state: { items: [], draft: "" },
  view: function (s, app) {
    return { type: "Column", props: { style: { padding: "16", gap: "12" } }, children: [
      { type: "Text", props: { text: "Reading list" } },
      { type: "Row", props: { style: { gap: "8" } }, children: [
        { type: "Expanded", children: [app.input("draft", "draft", { hint: "Add a book" })] },
        { type: "Button", props: { text: "Add" }, events: { tap: app.handler("add", add) } },
      ] },
      { type: "Text", props: { text: s.items.length + " books" } },
    ] };
  },
  init: function (app) { Aseman.plugin.get("items").then(function (v) { app.set({ items: v || [] }); }); },
});
function add(e, app) {
  if (!app.state.draft) return;
  var items = app.state.items.concat([{ title: app.state.draft }]);
  app.set({ items: items, draft: "" });
  Aseman.plugin.set("items", items);
  Aseman.plugin.api("spaces", "message_list", {});
}
`;

test("an Elpian plugin runs on the SDK and the plugin shim, and passes", async () => {
  const r = await checkPlugin({ frontend: READING_LIST, permissions: ["spaces.message_list"] });
  assert.equal(r.ui, "elpian");
  assert.deepEqual(r.errors, []);
  assert.ok(r.renders > 0);
});

test("a platform action the plugin did not declare fails the check", async () => {
  const r = await checkPlugin({ frontend: READING_LIST, permissions: [] });
  assert.equal(r.ok, false);
  assert.ok(r.errors.some((e) => /spaces\.message_list.*did not declare/.test(e)), r.errors.join("\n"));
});

test("broken view trees and raw programs are caught with their fixes", async () => {
  const r = await checkPlugin({ frontend: `askHost('render', JSON.stringify({type:'Row', children:[{type:'TextField', props:{hint:'x'}}]}));` });
  assert.equal(r.ok, false);
  assert.ok(r.errors.some((e) => /layout-unbounded-width/.test(e)));
  assert.ok(r.warnings.some((w) => /App\.create/.test(w)));
});

test("the backend's tools() are read and the screen may only call them", async () => {
  assert.deepEqual(backendFunctions("function tools(){return [{name:'add'}]} function add(){}").functions, ["add"]);
  assert.match(backendFunctions("function tools(){return [{name:'add'}]}").error, /no function/);
  assert.match(backendFunctions("throw new Error('x')").error, /throws/);
  const r = await checkPlugin({
    frontend: `App.create({ state: {}, view: function(){ return {type:'Text', props:{text:'x'}}; }, init: function(){ Aseman.plugin.call('missing', {}); } });`,
    backend: "function tools(){return [{name:'add', description:'', input:{}}]} function add(){ return 1; }",
  });
  assert.ok(r.errors.some((e) => /backend function "missing"/.test(e)), r.errors.join("\n"));
});

test("a web plugin gets the frame's policy, the starting env and the bridge first", () => {
  const doc = webDocument("<!doctype html><html><head><title>x</title></head><body></body></html>", { theme: { mode: "dark" } });
  const head = doc.indexOf("<head>") + "<head>".length;
  assert.ok(doc.slice(head).startsWith(`<meta http-equiv="Content-Security-Policy" content="${WEB_PLUGIN_CSP}">`));
  assert.ok(doc.includes("window.__asemanInitialEnv="));
  assert.ok(doc.indexOf("Aseman web plugin bridge") < doc.indexOf("<title>"));
  assert.match(WEB_PLUGIN_CSP, /connect-src 'none'/);
});

test("the client ships the same plugin shims as the kit", () => {
  for (const name of ["aseman-plugin.js", "aseman-web-plugin.js", "aseman-elpian.js"]) {
    const kit = fs.readFileSync(path.join(here, "..", name), "utf8");
    const app = fs.readFileSync(path.join(repo, "app", "assets", "elpian", name), "utf8");
    assert.equal(app, kit, `app/assets/elpian/${name} differs from the kit's: copy it over`);
  }
});

const chromium = chromiumPath();

test("a web plugin loads, draws with WebGL and talks through the bridge", { skip: !chromium && "no Chromium" }, async () => {
  const html = `<!doctype html><html><head><style>body{margin:0;background:var(--aseman-surface);color:var(--aseman-on-surface)}canvas{width:100%;height:50vh}</style></head>
<body><h1>Globe</h1><canvas id=c></canvas><script>
var gl = document.getElementById('c').getContext('webgl'); if (!gl) throw new Error('no webgl');
gl.clearColor(0.2, 0.3, 0.5, 1); gl.clear(gl.COLOR_BUFFER_BIT);
Aseman.plugin.get('spin').then(function (v) { document.body.appendChild(document.createTextNode(' ' + v)); });
</script></body></html>`;
  const r = await checkPlugin({ ui: "web", frontend: html });
  assert.deepEqual(r.errors, []);
  assert.ok(r.notes.some((n) => /phone 360×640: .*1 canvas.*call get/.test(n)), r.notes.join("\n"));
});

test("a web plugin that reaches the network, overflows a phone or calls undeclared actions fails", { skip: !chromium && "no Chromium" }, async () => {
  const html = `<!doctype html><html><head><script src="https://cdn.example.com/lib.js"></script></head>
<body><div style="width:900px">wide</div><script>Aseman.plugin.api('admin', 'health', {}).catch(function(){});</script></body></html>`;
  const r = await checkPlugin({ ui: "web", frontend: html });
  assert.equal(r.ok, false);
  const all = r.errors.join("\n");
  assert.match(all, /from the network/);
  assert.match(all, /blocked by the frame's policy/);
  assert.match(all, /900px wide in a 360px window|wide in a 360px window/);
  assert.match(all, /admin\.health, which the plugin did not declare/);
});

test("plugin-inline makes a multi-file web build one document", async () => {
  const { inlineHtml } = await import("../plugin-inline.mjs");
  const os = await import("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "inline-"));
  fs.writeFileSync(path.join(dir, "app.js"), "window.x = '</script>';");
  fs.writeFileSync(path.join(dir, "app.css"), "@font-face{font-family:F;src:url(f.woff2)} body{color:red}");
  fs.writeFileSync(path.join(dir, "f.woff2"), "font");
  fs.writeFileSync(path.join(dir, "logo.png"), "png");
  const out = inlineHtml(`<html><head><link rel="stylesheet" href="app.css"><script src="https://cdn.example.com/x.js"></script></head>
<body><img src="logo.png"><script src="app.js"></script></body></html>`, dir);
  assert.match(out, /<style>@font-face\{font-family:F;src:url\("data:font\/woff2;base64,/);
  assert.match(out, /<img src="data:image\/png;base64,/);
  assert.match(out, /<script>window\.x = '<\\\/script>';<\/script>/);
  assert.match(out, /src="https:\/\/cdn\.example\.com\/x\.js"/, "remote URLs are left for the check to report");
});
