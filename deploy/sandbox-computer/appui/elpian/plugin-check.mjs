#!/usr/bin/env node
// Checks a Creator plugin before it is created, the way the Aseman client
// will run it (PLUGINS.md):
//
//   * ui "elpian" (the default): the screen program runs on QuickJS after the
//     Aseman Elpian SDK and the plugin shim (aseman-elpian.js +
//     aseman-plugin.js, exactly what the client prepends), against a
//     simulated host that answers Aseman.plugin.* like the plugin gate: its
//     own store, its backend's declared functions, only its declared platform
//     actions. Every screen it reaches is validated by the UI DSL validator
//     (validate.mjs), as a phone and as a desk window.
//   * ui "web": the HTML document loads in headless Chromium, with the same
//     Content-Security-Policy and bridge (aseman-web-plugin.js) the client's
//     web frame gives it, at a phone (360×640) and a desk window (1280×800):
//     it must load without errors, never reach the network, draw something,
//     fit a phone, and use the person's theme. --screenshots DIR saves what
//     it looks like (phone.png, desk.png) to look at with read_image.
//
//   node plugin-check.mjs <frontend.js | index.html> [--ui elpian|web]
//        [--backend backend.js] [--permissions ns.action,ns.*] [--name N] [--description D]
//        [--screenshots DIR] [--json]
//
// Exit code 1 when the plugin would break for the person using it.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** The policy the client's web frame enforces: inline only, no network. */
export const WEB_PLUGIN_CSP =
  "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob: data:; " +
  "style-src 'unsafe-inline' data:; img-src data: blob:; font-src data:; media-src data: blob:; " +
  "worker-src blob: data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'";

export const MAX_WEB_DOCUMENT = 6 << 20;

const SAMPLE_THEME = {
  mode: "light",
  radius: 16,
  font: "Roboto, system-ui, sans-serif",
  colors: {
    primary: "#6750A4", onPrimary: "#FFFFFF", primaryContainer: "#EADDFF", onPrimaryContainer: "#21005D",
    secondary: "#625B71", onSecondary: "#FFFFFF", tertiary: "#7D5260", surface: "#FEF7FF", onSurface: "#1D1B20",
    onSurfaceVariant: "#49454F", surfaceContainer: "#F3EDF7", surfaceContainerHigh: "#ECE6F0",
    outline: "#79747E", outlineVariant: "#CAC4D0", error: "#B3261E", onError: "#FFFFFF",
  },
};

/** The functions a backend program declares in tools(), or an error. */
export function backendFunctions(source) {
  if (!source) return { functions: ["get", "set"] };
  const sandbox = { askHost: () => "null", console: { log() {}, error() {} } };
  try {
    vm.createContext(sandbox);
    vm.runInContext(String(source), sandbox, { timeout: 1000, filename: "backend.js" });
    if (typeof sandbox.tools !== "function") return { error: "the backend does not declare tools()" };
    const list = sandbox.tools();
    if (!Array.isArray(list)) return { error: "tools() must return a list of {name, description, input}" };
    const functions = [];
    const missing = [];
    for (const t of list) {
      const name = t && t.name;
      if (typeof name !== "string" || !name) return { error: "every tool in tools() needs a name" };
      functions.push(name);
      if (typeof sandbox[name] !== "function") missing.push(name);
    }
    if (missing.length) return { error: `tools() declares ${missing.join(", ")} but the backend defines no function of that name` };
    return { functions };
  } catch (e) {
    return { error: `the backend throws when loaded: ${e.message}` };
  }
}

// ── Elpian ─────────────────────────────────────────────────────────────────

/** SDK + plugin shim + program: what the client runs. */
export function elpianBundle(program) {
  const sdk = fs.readFileSync(path.join(here, "aseman-elpian.js"), "utf8");
  const shim = fs.readFileSync(path.join(here, "aseman-plugin.js"), "utf8");
  return `${sdk}\n${shim}\n${program}\n`;
}

// ── Craft: what a correct tree can still get wrong ─────────────────────────

// Characters people draw pictures with when they do not know the drawing
// nodes: dots, bullets, slashes, bars.
const ART = /^[\s.·•●○◦∙⋅°*+\-_=|/\\…:oO◯⬤■□▪▫]+$/;

// Asked for in the plugin's name or description → the nodes made for it.
const CHARTS = ["Chart", "Sparkline", "Funnel", "Waterfall", "Sankey", "Gantt", "BoxPlot", "BulletChart", "SegmentedBar", "RadialBars",
  "Sunburst", "CalendarHeatmap", "Gauge", "Heatmap", "PivotTable"];
const DRAWN = ["Canvas", "CachedCanvas", "canvas"];
export const INTENTS = [
  { re: /\b(analog(ue)?\s+(clock|watch)|clock\s*face|wall\s*clock|watch\s*face)\b/i, nodes: ["Clock", ...DRAWN], severity: "error",
    fix: '{type: "Clock", props: {mode: "analog", seconds: true, size: 240}} draws a live analog clock (it ticks by itself); a custom face is a Canvas (fillCircle, arc, lineTo)' },
  { re: /\b(gauge|speedometer|dial)\b/i, nodes: ["Gauge", "RadialBars", ...DRAWN], severity: "error",
    fix: '{type: "Gauge", props: {value, min, max, label, thresholds}}' },
  { re: /\bkanban\b/i, nodes: ["Kanban"], severity: "warning", fix: '{type: "Kanban", props: {columns, cards}} (elpian_describe Kanban)' },
  { re: /\bcountdown\b/i, nodes: ["Countdown", "Clock", ...DRAWN], severity: "warning", fix: '{type: "Countdown"} ticks by itself (app.every is 5 s at least)' },
  { re: /\b(clock|time\s*zones?|world\s*time)\b/i, nodes: ["Clock", ...DRAWN], severity: "warning", fix: '{type: "Clock", props: {mode: "analog" | "digital", utcOffset, label}} — live, it ticks by itself' },
  { re: /\bcalendar\b/i, nodes: ["Calendar", "CalendarHeatmap"], severity: "warning", fix: '{type: "Calendar"} (elpian_describe Calendar)' },
  { re: /\b(chart|graph|plot|trend|histogram)s?\b/i, nodes: [...CHARTS, ...DRAWN], severity: "warning", fix: '{type: "Chart", props: {type: "line" | "bar" | "pie" | …, data, x, y}} inside a filled Card (elpian_describe Chart)' },
];

// Design notes that decide whether a plugin looks made or assembled: shown
// to the agent as warnings, not buried in notes.
const DESIGN_WARNINGS = new Set(["design-filled-buttons", "design-emoji-icon", "design-type-role", "design-hardcoded-color", "design-nested-card"]);

function walkNodes(node, visit) {
  if (node === null || node === undefined || node === false) return;
  if (Array.isArray(node)) return node.forEach((n) => walkNodes(n, visit));
  if (typeof node === "string") return visit({ type: "Text", props: { text: node } });
  if (typeof node !== "object") return;
  visit(node);
  walkNodes(node.children, visit);
  if (node.props) for (const v of Object.values(node.props)) if (v && typeof v === "object" && (v.type || Array.isArray(v))) walkNodes(v, visit);
}

/** Findings no schema can see: pictures drawn with characters, the node made for what was asked left unused. */
export function craftFindings(trees, { name = "", description = "" } = {}) {
  const errors = [];
  const warnings = [];
  const types = new Set();
  let worstArt = 0;
  let sample = [];
  for (const tree of trees) {
    let art = 0;
    const seen = [];
    walkNodes(tree, (n) => {
      if (n.type) types.add(n.type);
      if (n.type !== "Text") return;
      const text = String((n.props && (n.props.text ?? n.props.data)) ?? "");
      const lines = text.split("\n").filter((l) => l.trim());
      if (!lines.length) return;
      // A short mark, or a block of lines made only of marks.
      if ((text.trim().length <= 4 && ART.test(text)) || (lines.length >= 3 && lines.filter((l) => ART.test(l)).length >= lines.length * 0.7)) {
        art += lines.length >= 3 ? lines.length : 1;
        if (seen.length < 4 && !seen.includes(text.trim())) seen.push(text.trim().slice(0, 12));
      }
    });
    if (art > worstArt) {
      worstArt = art;
      sample = seen;
    }
  }
  if (worstArt >= 10) {
    errors.push(`the screen draws a picture out of text characters (${worstArt} marks such as ${sample.map((t) => JSON.stringify(t)).join(", ")}): ` +
      "it looks broken on every screen and theme. Fix: use the node made for it (Clock, Gauge, Chart, Progress, RadialBars …) or draw it on a Canvas " +
      "({type: \"Canvas\", props: {width, height, commands: [{type: \"setFillStyle\", params: {color}}, {type: \"fillCircle\", params: {x, y, radius}}, " +
      "{type: \"beginPath\"}, {type: \"moveTo\", params: {x, y}}, {type: \"lineTo\", params: {x, y}}, {type: \"stroke\"}]}}) [craft-text-art]");
  }
  const asked = `${name}\n${description}`;
  for (const intent of INTENTS) {
    if (!intent.re.test(asked)) continue;
    if (intent.nodes.some((t) => types.has(t))) continue;
    const what = asked.match(intent.re)[0];
    const line = `the plugin is "${what}", but the screen uses none of ${intent.nodes.filter((t) => t !== "canvas").join(", ")}. Fix: ${intent.fix} [craft-intent]`;
    (intent.severity === "error" ? errors : warnings).push(line);
    break; // the most specific intent only
  }
  return { errors, warnings };
}

export async function checkElpian(program, { permissions = [], functions = ["get", "set"], name = "Plugin", description = "", design = true } = {}) {
  const { check } = await import("./check.mjs");
  const { validateRenders } = await import("./validate.mjs");
  const errors = [];
  const warnings = [];
  const notes = [];
  const run = await check(elpianBundle(program), {
    widget: false, collect: true, validate: false, plugin: { permissions, functions, name },
  });
  errors.push(...(run.errors || []));
  warnings.push(...(run.warnings || []).filter((w) => !/askHost\("(tool\.call|aseman\.call|aseman\.context)"\)/.test(w)));
  const trees = run.trees || [];
  if (!trees.length) errors.push("the screen never rendered: build it with App.create({state, view}) (or askHost('render', …))");
  else {
    const report = validateRenders(trees, { mode: "app", design, theme: run.theme }, run.paths, run.viewports);
    for (const i of report.issues) {
      const line = `${i.at || i.path}: ${i.message}${i.fix ? ` Fix: ${i.fix}` : ""} [${i.code}]`;
      if (i.severity === "error") errors.push(line);
      else if (i.severity === "info" && !DESIGN_WARNINGS.has(i.code)) notes.push(line);
      else warnings.push(line);
    }
    const craft = craftFindings(trees, { name, description });
    errors.push(...craft.errors);
    warnings.push(...craft.warnings);
  }
  if (!/\bApp\.create\s*\(/.test(program)) {
    warnings.push("the screen does not use App.create: build it with the SDK (state, view, app.handler) so it re-renders, keeps state and looks like the app");
  }
  const unique = (l) => [...new Set(l)];
  return { ui: "elpian", ok: errors.length === 0, errors: unique(errors), warnings: unique(warnings), notes: unique(notes).slice(0, 40), renders: trees.length };
}

// ── Web ────────────────────────────────────────────────────────────────────

/** The document with the frame's CSP, the starting env and the bridge first in its head. */
export function webDocument(html, env, extra = "") {
  const bridge = fs.readFileSync(path.join(here, "aseman-web-plugin.js"), "utf8");
  const inject =
    `<meta http-equiv="Content-Security-Policy" content="${WEB_PLUGIN_CSP}">` +
    `<script>window.__asemanInitialEnv=${JSON.stringify(env).replace(/</g, "\\u003c")};</script>` +
    `<script>${bridge}</script>${extra}`;
  const head = /<head[^>]*>/i.exec(html);
  if (head) return html.slice(0, head.index + head[0].length) + inject + html.slice(head.index + head[0].length);
  const doc = /<html[^>]*>/i.exec(html);
  if (doc) return html.slice(0, doc.index + doc[0].length) + `<head>${inject}</head>` + html.slice(doc.index + doc[0].length);
  return `<!doctype html><html><head>${inject}</head><body>${html}</body></html>`;
}

// Inside the plugin's document: what it does wrong, and its measurements,
// posted to the checker's host page around it.
const PROBE = `<script>(function(){
  var out = {errors: [], warnings: [], csp: []};
  function send(){
    try {
      var d = document.documentElement, b = document.body;
      out.width = innerWidth; out.height = innerHeight;
      out.scrollWidth = Math.max(d.scrollWidth, b ? b.scrollWidth : 0);
      out.scrollHeight = Math.max(d.scrollHeight, b ? b.scrollHeight : 0);
      out.text = b ? (b.innerText || "").trim().length : 0;
      out.canvases = document.querySelectorAll("canvas").length;
      out.media = document.querySelectorAll("svg, img, video, canvas").length;
      out.elements = b ? b.querySelectorAll("*").length : 0;
      parent.postMessage({__asemanCheck: out}, "*");
    } catch (e) {}
  }
  addEventListener("securitypolicyviolation", function(e){ out.csp.push((e.blockedURI || "inline") + " (" + e.violatedDirective + ")"); });
  addEventListener("error", function(e){
    if (e.target && e.target !== window) return; // a resource that failed to load (the policy reports it)
    out.errors.push(String((e.error && (e.error.stack || e.error.message)) || e.message || "an error"));
  }, true);
  addEventListener("unhandledrejection", function(e){ out.errors.push("unhandled rejection: " + String((e.reason && (e.reason.stack || e.reason.message)) || e.reason)); });
  var ce = console.error; console.error = function(){ out.warnings.push("console.error: " + Array.prototype.map.call(arguments, String).join(" ")); return ce.apply(console, arguments); };
  setInterval(send, 200);
  addEventListener("load", function(){ setTimeout(send, 50); });
})();</script>`;

// The checker's top page: the plugin in a frame the size of the viewport (as
// the app hosts it), answering its bridge like the plugin gate, and keeping
// the report in a JSON element that --dump-dom prints.
function hostPage(doc, vp, { permissions, functions }) {
  const json = (v) => JSON.stringify(v).replace(/</g, "\\u003c");
  return `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:#888}iframe{border:0;display:block;background:#fff}</style></head><body>
<iframe id="f" width="${vp.width}" height="${vp.height}"></iframe>
<script type="application/json" id="__aseman_check">{}</script>
<script>(function(){
  var perms = ${json(permissions)}, fns = ${json(functions)}, store = {};
  var report = {inner: null, requests: [], ready: false, errors: []};
  function allowed(ns, a){ return perms.indexOf(ns + "." + a) >= 0 || perms.indexOf(ns + ".*") >= 0; }
  function write(){ document.getElementById("__aseman_check").textContent = JSON.stringify(report).replace(/<\\//g, "<\\\\/"); }
  addEventListener("message", function(ev){
    var m = ev.data; if (!m || typeof m !== "object") return;
    if (m.__asemanCheck) { report.inner = m.__asemanCheck; write(); return; }
    if (m.aseman === "ready") { report.ready = true; write(); return; }
    if (m.aseman !== "request") return;
    var b = m.body || {}, reply = {aseman: "settle", id: m.id, ok: true, data: {}};
    if (m.op === "invoke") {
      var fn = b["function"];
      report.requests.push("call " + fn);
      if (fn === "get") reply.data = {value: Object.prototype.hasOwnProperty.call(store, b.args && b.args.key) ? store[b.args.key] : null};
      else if (fn === "set") { store[b.args && b.args.key] = b.args ? b.args.value : null; reply.data = {ok: true}; }
      else if (fns.indexOf(fn) < 0) { reply.ok = false; reply.error = "no backend function " + fn; report.errors.push("the page calls backend function \\"" + fn + "\\", which the backend does not declare in tools()"); }
    } else if (m.op === "call") {
      report.requests.push("api " + b.namespace + "." + b.action);
      if (!allowed(b.namespace, b.action)) { reply.ok = false; reply.error = b.namespace + "." + b.action + " is not declared"; report.errors.push("the page calls " + b.namespace + "." + b.action + ", which the plugin did not declare in permissions (it will be refused)"); }
    } else if (m.op === "context") {
      reply.data = {plugin: "p-check", name: "Check", scope: "account", space: "s-check", room: "", user: "u-check", display: "full"};
    } else { reply.ok = false; reply.error = "unknown op"; report.errors.push("unknown bridge op " + m.op); }
    write();
    setTimeout(function(){ ev.source.postMessage(reply, "*"); }, 5);
  });
  document.getElementById("f").srcdoc = ${json(doc)};
})();</script></body></html>`;
}

export function chromiumPath() {
  const candidates = [process.env.ASEMAN_CHROMIUM, "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome",
    "/opt/pw-browsers/chromium/chrome-linux64/chrome"].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  try {
    for (const d of fs.readdirSync("/opt/pw-browsers")) {
      const c = path.join("/opt/pw-browsers", d, "chrome-linux64", "chrome");
      if (d.startsWith("chromium-") && fs.existsSync(c)) return c;
    }
  } catch {
    /* none */
  }
  return "";
}

function chromium(bin, args, timeoutMs = 45000) {
  return new Promise((resolve) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: String(e.message) });
    });
  });
}

const VIEWPORTS = [
  { name: "phone", width: 360, height: 640 },
  { name: "desk", width: 1280, height: 800 },
];

export async function checkWeb(html, { permissions = [], functions = ["get", "set"], screenshots = "", mode = "light" } = {}) {
  const errors = [];
  const warnings = [];
  const notes = [];
  const shots = [];
  if (Buffer.byteLength(html) > MAX_WEB_DOCUMENT) errors.push(`the document is ${(Buffer.byteLength(html) / 1048576).toFixed(1)} MB: 6 MB at most, libraries included (minify, drop unused code)`);
  if (!/<html|<body|<head|<!doctype/i.test(html.slice(0, 2048))) errors.push("a web plugin is one HTML document (<!doctype html><html>…)");
  if (/<(script|link)[^>]+(src|href)\s*=\s*["']?(https?:)?\/\//i.test(html)) errors.push("the document loads scripts or styles from the network, which the app's frame blocks: inline them (bundle the libraries into the page)");
  if (!/--aseman-|Aseman\.env|Aseman\.onEnv/.test(html)) warnings.push("the page ignores the person's theme: use the --aseman-* CSS variables (or Aseman.onEnv) for colours, and support data-theme=\"dark\"");
  const bin = chromiumPath();
  if (!bin) {
    errors.push("no Chromium on this computer to load the page (set ASEMAN_CHROMIUM)");
    return { ui: "web", ok: false, errors, warnings, notes, screenshots: shots };
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "aseman-plugin-"));
  const flags = ["--headless=new", "--no-sandbox", "--disable-gpu-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
    "--hide-scrollbars", "--mute-audio", "--no-first-run", "--disable-extensions"];
  try {
    for (const vp of VIEWPORTS) {
      const env = { display: "full", theme: { ...SAMPLE_THEME, mode }, viewport: { width: vp.width, height: vp.height } };
      const file = path.join(dir, `${vp.name}.html`);
      fs.writeFileSync(file, hostPage(webDocument(html, env, PROBE), vp, { permissions, functions }));
      const url = `file://${file}`;
      // The window holds the frame (headless windows are at least 500 wide).
      const win = `--window-size=${Math.max(vp.width, 500)},${vp.height}`;
      const r = await chromium(bin, [...flags, win, "--virtual-time-budget=6000", "--dump-dom", url]);
      const m = /<script type="application\/json" id="__aseman_check">([\s\S]*?)<\/script>/.exec(r.stdout);
      const at = `${vp.name} ${vp.width}×${vp.height}`;
      let report;
      try {
        report = m ? JSON.parse(m[1]) : null;
      } catch {
        report = null;
      }
      if (!report || !report.inner) {
        errors.push(`${at}: the page did not finish loading in Chromium${r.code ? ` (exit ${r.code})` : ""}`);
        continue;
      }
      const out = report.inner;
      for (const e of [...out.errors, ...report.errors]) errors.push(`${at}: ${String(e).split("\n").slice(0, 3).join(" | ")}`);
      for (const c of out.csp) errors.push(`${at}: blocked by the frame's policy: ${c} — inline it; plugins never use the network (reach data through Aseman.plugin)`);
      for (const w of out.warnings) warnings.push(`${at}: ${w}`);
      if (!report.ready) errors.push(`${at}: the Aseman bridge did not start (a script before it failed?)`);
      if (!out.text && !out.media) errors.push(`${at}: the page draws nothing (no text, canvas, SVG or image)`);
      if (out.scrollWidth > out.width + 2) {
        (vp.name === "phone" ? errors : warnings).push(`${at}: the page is ${out.scrollWidth}px wide in a ${out.width}px window: make it responsive (no fixed widths; flex/grid with wrapping; canvas sized to its container)`);
      }
      if (vp.name === "phone" && out.elements > 4000) warnings.push(`${at}: ${out.elements} elements: keep the DOM small (virtualize long lists)`);
      notes.push(`${at}: ${out.text} characters of text, ${out.canvases} canvas(es), ${out.media} graphic(s), requests: ${[...new Set(report.requests)].join(", ") || "none"}`);
      if (screenshots) {
        fs.mkdirSync(screenshots, { recursive: true });
        const png = path.resolve(screenshots, `${vp.name}.png`);
        await chromium(bin, [...flags, win, "--virtual-time-budget=6000", `--screenshot=${png}`, url]);
        if (fs.existsSync(png)) shots.push(png);
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const unique = (l) => [...new Set(l)];
  return { ui: "web", ok: errors.length === 0, errors: unique(errors), warnings: unique(warnings), notes, screenshots: shots };
}

/** Checks a plugin: {ok, errors, warnings, notes, …}. */
export async function checkPlugin({ ui = "elpian", frontend, backend = "", permissions = [], name = "Plugin", description = "", screenshots = "" }) {
  const b = backendFunctions(backend);
  const functions = b.functions || [];
  const result = ui === "web"
    ? await checkWeb(frontend, { permissions, functions, screenshots })
    : await checkElpian(frontend, { permissions, functions, name, description });
  if (b.error) {
    result.errors.unshift(`backend: ${b.error}`);
    result.ok = false;
  }
  return result;
}

export function formatResult(r) {
  const lines = [`${r.ok ? "PASS" : "FAIL"} (${r.ui}): ${r.errors.length} error(s), ${r.warnings.length} warning(s)`];
  for (const e of r.errors) lines.push(`ERROR ${e}`);
  for (const w of r.warnings) lines.push(`WARN  ${w}`);
  for (const n of r.notes || []) lines.push(`NOTE  ${n}`);
  for (const s of r.screenshots || []) lines.push(`SHOT  ${s}`);
  return lines.join("\n");
}

async function main(argv) {
  const val = (n) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : undefined);
  const valued = new Set(["--ui", "--backend", "--permissions", "--name", "--description", "--screenshots"]);
  const file = argv.find((a, i) => !a.startsWith("--") && !(i > 0 && valued.has(argv[i - 1])));
  if (!file) {
    console.error("usage: plugin-check.mjs <frontend.js|index.html> [--ui elpian|web] [--backend backend.js] [--permissions a.b,c.*] [--name N] [--screenshots DIR] [--json]");
    return 2;
  }
  const frontend = fs.readFileSync(file, "utf8");
  const ui = val("--ui") || (/\.html?$/i.test(file) ? "web" : "elpian");
  const backend = val("--backend") ? fs.readFileSync(val("--backend"), "utf8") : "";
  const permissions = (val("--permissions") || "").split(",").map((s) => s.trim()).filter(Boolean);
  const r = await checkPlugin({ ui, frontend, backend, permissions, name: val("--name") || "Plugin", description: val("--description") || "", screenshots: val("--screenshots") || "" });
  console.log(argv.includes("--json") ? JSON.stringify(r) : formatResult(r));
  return r.ok ? 0 : 1;
}

// Run as a command (also through a symlink such as /usr/local/bin/aseman-plugin-check).
const invoked = (() => {
  try {
    return fs.realpathSync(process.argv[1] || "") === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();
if (invoked) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
    console.error(e && e.stack ? e.stack : e);
    process.exit(2);
  });
}
