#!/usr/bin/env node
// The Elpian headless driver: uses an Elpian App UI the way a person does,
// without a screen, so a coding agent can test it end to end. Like a
// headless browser, but for Elpian view trees.
//
// It runs the program on QuickJS (the engine the Aseman client runs it on)
// against a simulated Aseman host and the app's live server. A session reads
// the screen as a text outline in which every control has a stable ref
// (e1, e2 …), and acts on controls by ref, key or visible text: tap, type,
// select, toggle, swipe, drag, pinch, long-press… Each action calls the
// handler the client would call, with the event data the client sends, and
// obeys what the client obeys: disabled controls and touches that never
// arrive do nothing, taps on a label reach the control around it, text
// fields keep what was typed, tabs and expandable panels switch by
// themselves. Then it settles the requests the action made (the app's
// server for real; the space's agents and apps from mocks, which can also
// fail or stay pending) and answers with what changed on the screen, the
// requests, and the problems found: exceptions, error banners, server
// failures, renders that break on phones.
//
// Assertions (expect) check the screen, the app's state and the network.
// What a session did is a scenario (elpian/e2e/*.json): saved, it replays
// with `node drive.mjs run`, which the platform runs before an app is
// ready. Coverage names the controls no step has used yet.
//
//   node drive.mjs run [elpian/e2e …] [--bundle elpian/app.js] [--server URL | --start "node server.js" --port 8787] [--apps APPS.json] [--json]
//   node drive.mjs snapshot [--bundle …] [--server …] [--viewport phone|desk|WxH]
//
// drive-mcp.mjs serves sessions to OpenCode as tools (elpian_open, elpian_tap, …);
// elpian-cli.mjs (aseman-elpian) serves the same tools to Aseman agents on the shell.

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadQuickJS, typed, SAMPLE_ENV, BLOCKING } from "./check.mjs";
import { validate as validateTree } from "./validate.mjs";
import { TYPES, TAP_CONTROLS, PHONE } from "./schema.mjs";
import { bundle as bundleProject } from "./bundle.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const NODES = JSON.parse(fs.readFileSync(path.join(here, "nodes.json"), "utf8"));
const KNOWN = new Set([...NODES.elpian, ...NODES.html, ...NODES.kit]);

// ── environment ──────────────────────────────────────────────────────────

const DARK = {
  primary: "#D0BCFF", onPrimary: "#381E72", primaryContainer: "#4F378B", onPrimaryContainer: "#EADDFF",
  secondary: "#CCC2DC", onSecondary: "#332D41", secondaryContainer: "#4A4458", onSecondaryContainer: "#E8DEF8",
  tertiary: "#EFB8C8", onTertiary: "#492532", tertiaryContainer: "#633B48", onTertiaryContainer: "#FFD8E4",
  surface: "#141218", onSurface: "#E6E0E9", onSurfaceVariant: "#CAC4D0",
  surfaceContainerLowest: "#0F0D13", surfaceContainerLow: "#1D1B20", surfaceContainer: "#211F26", surfaceContainerHigh: "#2B2930", surfaceContainerHighest: "#36343B",
  inverseSurface: "#E6E0E9", onInverseSurface: "#322F35", outline: "#938F99", outlineVariant: "#49454F",
  error: "#F2B8B5", onError: "#601410", errorContainer: "#8C1D18", onErrorContainer: "#F9DEDC",
};
const THEMES = {
  light: SAMPLE_ENV.theme,
  dark: { mode: "dark", accent: SAMPLE_ENV.theme.accent, colors: DARK },
};
export const VIEWPORTS = {
  phone: { width: PHONE.width, height: PHONE.height },
  "phone-large": { width: 412, height: 915 },
  tablet: { width: 800, height: 1280 },
  desk: { width: 1280, height: 800 },
};

export function viewportOf(v) {
  let base = v;
  if (typeof v === "string") {
    const m = /^(\d+)\s*[x×]\s*(\d+)$/.exec(v.trim());
    base = m ? { width: Number(m[1]), height: Number(m[2]) } : VIEWPORTS[v];
  }
  if (!base || typeof base !== "object") throw new DriveError(`unknown viewport ${JSON.stringify(v)}: use phone, phone-large, tablet, desk, "WxH" or {width, height}`);
  const width = Number(base.width) > 0 ? Number(base.width) : PHONE.width;
  const height = Number(base.height) > 0 ? Number(base.height) : PHONE.height;
  return { width, height, sizeClass: width < 600 ? "compact" : width < 840 ? "medium" : "expanded", orientation: width > height ? "landscape" : "portrait" };
}

// A mistake in how the driver was asked (no such control, an ambiguous
// target, an action the control does not take): the tool answers with an
// error, the step fails.
export class DriveError extends Error {}

// ── reading view trees ───────────────────────────────────────────────────

const str = (v) => (v === undefined || v === null || typeof v === "object" ? "" : String(v));
const norm = (s) => String(s).toLowerCase().replace(/\s+/g, " ").trim();
const clip = (s, n = 60) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const J = JSON.stringify;
const num = (v, d = 0) => (Number.isFinite(Number(v)) && v !== "" && v !== null ? Number(v) : d);

// Nodes that only arrange others: left out of the outline unless they take
// events (their children are shown in their place).
const ARRANGE = new Set(Object.entries(TYPES).filter(([, t]) => t.category === "layout" || t.category === "motion").map(([k]) => k));
for (const t of ["div", "form", "fieldset", "nav", "ul", "ol", "li", "section", "figure", "picture", "Shimmer"]) ARRANGE.add(t);
ARRANGE.delete("Shimmer");
const TEXT_FIELDS = new Set(["TextField", "SearchBar", "input", "textarea"]);
const TAPPED_WHOLE = new Set(TAP_CONTROLS);
// Controls a person expects to do something: one without its event is dead.
const EXPECTS = { Button: "tap", IconButton: "tap", FAB: "tap", FloatingActionButton: "tap", button: "tap",
  Switch: "change", Checkbox: "change", Slider: "change", SegmentedButton: "change", NavigationBar: "change", TextField: "input", SearchBar: "input" };
// Nodes that get a ref even without events (they hold state a test reads).
const REFERABLE = new Set([...TAP_CONTROLS, "Expandable", "Tabs", "ListTile", "select", "input", "textarea", "button", "Callout", "DataGrid", "Stat", "Progress", "Gauge"]);
const OPTION_CONTROLS = { SegmentedButton: 1, NavigationBar: 1, Tabs: 1, Breadcrumbs: 1, Stepper: 1, Chat: 1 };
const SELECTS = new Set(["Chart", "DataGrid", "Heatmap", "Treemap", "Graph", "Timeline", "TreeView", "Leaderboard", "PivotTable", "Kanban", "Calendar", "Stepper", "Breadcrumbs", "Chat"]);

function ownLabel(node) {
  const p = node.props || {};
  switch (node.type) {
    case "Text": return str(p.text ?? p.data);
    case "Icon": return str(p.semanticLabel);
    case "Markdown": return str(p.text ?? p.content ?? p.markdown);
    case "TextField": case "SearchBar": case "input": case "textarea": return str(p.label ?? p.hint ?? p.placeholder);
    case "EmptyState": return str(p.title);
    case "Callout": return str(p.title ?? p.text);
    case "Tag": return str(p.text ?? p.label ?? p.value);
    case "Avatar": return str(p.name ?? p.label);
    case "Tooltip": return str(p.message);
    case "option": return str(p.text ?? p.label ?? p.value);
    case "Slider": return ""; // its label is a value suffix ("%")
    default: return str(p.text ?? p.label ?? p.title ?? p.tooltip ?? p.name ?? p.semanticLabel);
  }
}

// What an item of a list prop shows: {label, value} for a segment, tab,
// destination, step or crumb (strings are both).
function itemsOf(list) {
  return (Array.isArray(list) ? list : []).map((x, i) => {
    if (x && typeof x === "object") return { label: str(x.label ?? x.title ?? x.text ?? x.value ?? x.icon) || `#${i}`, value: x.value !== undefined ? x.value : x.label ?? x.title, badge: x.badge, raw: x };
    return { label: str(x), value: x, raw: x };
  });
}

function rowText(row) {
  if (row === null || typeof row !== "object") return str(row);
  return Object.entries(row).filter(([, v]) => v === null || typeof v !== "object").slice(0, 6).map(([k, v]) => `${k}=${clip(str(v), 30)}`).join(", ");
}

// ── the session ──────────────────────────────────────────────────────────

export class Session {
  // Opens a session: loads the bundle (or source) and renders the first
  // screen. opts: {bundle | source, dir, build, server, start, port, apps,
  // viewport, theme, display, mocks, cwd}.
  static async open(opts = {}) {
    const s = new Session(opts);
    try {
      await s.boot();
    } catch (e) {
      await s.close();
      throw e;
    }
    return s;
  }

  constructor(opts) {
    this.opts = opts;
    this.dir = path.resolve(opts.dir || opts.cwd || process.cwd());
    this.env = {
      ...SAMPLE_ENV,
      title: opts.title || SAMPLE_ENV.title,
      display: opts.display === "widget" ? "compact" : opts.display || "full",
      theme: THEMES[opts.theme || "light"] || THEMES.light,
      viewport: viewportOf(opts.viewport || "phone"),
    };
    if (this.env.display === "compact") this.env.widget = { size: opts.widgetSize || "medium", shape: "card" };
    this.apps = opts.apps || null;
    this.mocks = [];
    this.network = [];
    this.logs = [];
    this.problems = [];
    this.steps = [];
    this.refs = new Map();
    this.refCount = 0;
    this.ui = { typed: new Map(), expanded: new Map(), tabs: new Map() };
    this.coverage = { seen: new Map(), fired: new Set() };
    this.issueSeen = new Set();
    this.clock = 0;
    this.history = [];
    for (const m of opts.mocks || []) this.addMock(m);
  }

  // ── lifecycle ──

  async boot() {
    const o = this.opts;
    if (o.build) bundleProject(this.dir);
    this.bundlePath = o.source ? null : path.resolve(this.dir, o.bundle || "elpian/app.js");
    if (this.bundlePath && !fs.existsSync(this.bundlePath)) throw new DriveError(`no bundle at ${this.bundlePath}: build it (node vendor/aseman-elpian/bundle.mjs .) or pass build: true`);
    if (!this.apps) {
      const f = path.join(this.dir, "APPS.json");
      if (fs.existsSync(f)) try { this.apps = JSON.parse(fs.readFileSync(f, "utf8")); } catch { /* none */ }
    }
    this.notes = [];
    if (o.start) {
      const port = o.port || jobPort(this.dir) || 8787;
      this.child = await startServer(o.start, this.dir, port);
      this.server = `http://127.0.0.1:${port}`;
      this.notes.push(`started the server (${o.start}) on ${this.server}`);
    } else if (o.server) {
      this.server = String(o.server);
    } else if (jobPort(this.dir)) {
      this.server = `http://127.0.0.1:${jobPort(this.dir)}`;
    }
    if (this.server && !(await reachable(this.server))) {
      this.notes.push(`the app's server ${this.server} does not answer: start it (or pass start: "<command>") or requests to it fail`);
    }
    this.source = o.source || fs.readFileSync(this.bundlePath, "utf8");
    await this.load();
  }

  async load() {
    const QuickJS = await loadQuickJS();
    const module = await QuickJS.getQuickJS();
    this.runtime = module.newRuntime();
    this.runtime.setMemoryLimit(128 << 20);
    this.runtime.setMaxStackSize(1 << 20);
    this.deadline = Infinity;
    this.runtime.setInterruptHandler(() => Date.now() > this.deadline);
    this.vm = this.runtime.newContext();
    this.tree = null;
    this.renders = 0;
    this.queue = [];
    this.held = [];
    this.timers = [];
    this.hint = null;
    this.ui = { typed: new Map(), expanded: new Map(), tabs: new Map() };
    const vm = this.vm;
    const askHost = vm.newFunction("askHost", (apiH, payloadH) => {
      const api = vm.getString(apiH);
      const payload = payloadH === undefined ? "" : vm.dump(payloadH);
      let parsed = payload;
      if (typeof payload === "string") try { parsed = JSON.parse(payload); } catch { parsed = payload; }
      return vm.newString(J(typed(this.host(api, parsed))));
    });
    vm.setProp(vm.global, "askHost", askHost);
    askHost.dispose();
    this.step = { problems: [], requests: [] };
    const boot = this.evaluate(this.source, "app.js");
    if (boot.error) this.problem("exception", `the program failed while starting: ${boot.error}`);
    await this.settle();
    if (!this.tree) this.problem("exception", "the program never rendered (call App.create({view}))");
    this.index();
    this.validateScreen();
  }

  async close() {
    try {
      if (this.vm) this.vm.dispose();
      if (this.runtime) this.runtime.dispose();
    } catch { /* already gone */ }
    this.vm = null;
    this.runtime = null;
    if (this.child) {
      stopServer(this.child);
      this.child = null;
    }
  }

  // Runs the program again from the start (the server keeps its data): what
  // a person sees opening the app again.
  async reload() {
    try {
      this.vm.dispose();
      this.runtime.dispose();
    } catch { /* gone */ }
    if (this.opts.build) bundleProject(this.dir);
    if (this.bundlePath) this.source = fs.readFileSync(this.bundlePath, "utf8");
    await this.load();
  }

  // ── the host the program talks to ──

  host(api, parsed) {
    switch (api) {
      case "render":
        this.tree = parsed;
        this.renders++;
        return true;
      case "aseman.env":
      case "env.get":
        return this.env;
      case "aseman.compact":
        this.hint = parsed;
        return true;
      case "aseman.expand":
        this.logs.push({ at: this.clock, text: "(the app asked to open in full)" });
        return true;
      case "setInterval":
      case "setTimeout": {
        const handler = parsed && (parsed.handler || parsed.fn);
        if (!handler) return null;
        const ms = Math.max(1, num(parsed.ms, 1000));
        const id = (this.timerIds = (this.timerIds || 0) + 1);
        this.timers.push({ id, handler, ms, due: this.clock + ms, repeat: api === "setInterval" });
        return id;
      }
      case "clearInterval":
      case "clearTimeout": {
        const id = parsed && typeof parsed === "object" ? parsed.id : parsed;
        this.timers = this.timers.filter((t) => t.id !== num(id, -1));
        return true;
      }
      case "println": {
        const t = typeof parsed === "string" ? parsed : J(parsed);
        this.logs.push({ at: this.clock, text: t });
        if (t.startsWith("app error:")) this.problem("app-error", `the app shows an error banner: ${t.slice(10).trim()}`);
        else if (t.startsWith("app threw:")) {
          const [first, ...frames] = t.slice(10).trim().split("\n");
          const at = frames.map((f) => f.trim()).find((f) => f.startsWith("at ")) || "";
          this.problem("exception", `the program threw ${first}${at ? ` (${at})` : ""} — a bug, not a failed request`);
        }
        else if (t.startsWith("view error:")) {
          const [first, ...frames] = t.slice(11).trim().split("\n");
          const at = frames.map((f) => f.trim()).find((f) => f.startsWith("at ")) || "";
          this.problem("exception", `the view threw: ${first}${at ? ` (${at})` : ""}`);
        }
        return true;
      }
      case "aseman.request":
        if (!parsed || !parsed.id || !(parsed.op || parsed.path !== undefined)) {
          this.problem("host", `aseman.request without id and op/path: ${J(parsed)}`);
          return { error: "bad request" };
        }
        this.queue.push(parsed);
        return { accepted: true };
      default:
        this.problem("host", `askHost("${api}") is not an Aseman host API: use the SDK (Aseman.*)`);
        return null;
    }
  }

  evaluate(code, name = "drive.js") {
    this.deadline = Date.now() + (this.opts.millis || 10000);
    try {
      const result = this.vm.evalCode(code, name);
      if (result.error) {
        const err = this.vm.dump(result.error);
        result.error.dispose();
        return { error: typeof err === "object" && err ? `${err.name || "Error"}: ${err.message}${err.stack ? "\n" + String(err.stack).split("\n").slice(0, 4).join("\n") : ""}` : String(err) };
      }
      const value = this.vm.dump(result.value);
      result.value.dispose();
      return { value };
    } finally {
      this.deadline = Infinity;
    }
  }

  problem(kind, message) {
    const p = { kind, message, after: this.history.slice(-4).join(" → ") };
    if (this.problems.some((x) => x.kind === kind && x.message === message)) {
      if (this.step && !this.step.problems.some((x) => x.message === message)) this.step.problems.push(p);
      return;
    }
    this.problems.push(p);
    if (this.step) this.step.problems.push(p);
  }

  // ── requests: the app's server, the space, mocks ──

  addMock(m) {
    if (!m || typeof m !== "object") throw new DriveError("a mock is an object: {op | path, …answer}");
    if (!m.op && m.path === undefined) throw new DriveError(`a mock names op (ask, call, agents, tools, microtools, context, show) or path (the app's server): ${J(m)}`);
    this.mocks.push({ ...m, used: 0 });
  }

  findMock(req) {
    for (let i = this.mocks.length - 1; i >= 0; i--) {
      const m = this.mocks[i];
      if (m.times !== undefined && m.used >= m.times) continue;
      if (req.target === "app") {
        if (m.path === undefined) continue;
        if (!pathMatches(m.path, req.path)) continue;
        if (m.method && String(m.method).toUpperCase() !== String(req.method || "GET").toUpperCase()) continue;
      } else {
        if (m.op !== req.op) continue;
        const b = req.body || {};
        if (m.agent && m.agent !== b.agent) continue;
        if (m.tool && m.tool !== b.tool) continue;
        if (m.microtool && m.microtool !== b.microtool) continue;
      }
      if (m.match) {
        const hay = J(req.body ?? "") + " " + J(req.query ?? "");
        if (!textMatches(m.match, hay)) continue;
      }
      return m;
    }
    return null;
  }

  mockAnswer(m, req) {
    const status = num(m.status, m.error ? 500 : 200);
    if (req.target === "app") {
      const json = m.json !== undefined ? m.json : m.text !== undefined ? tryJSON(m.text) : {};
      const text = m.text !== undefined ? String(m.text) : J(json);
      return { ok: true, status: 200, data: { status, ok: status < 400, json, text, contentType: m.text !== undefined && json === null ? "text/plain" : "application/json" } };
    }
    if (m.error || status >= 400) return { ok: false, status, error: String(m.error || `HTTP ${status}`) };
    switch (req.op) {
      case "ask": return { ok: true, status, data: { agent: (req.body || {}).agent, reply: typeof m.reply === "string" ? m.reply : J(m.reply ?? "") } };
      case "call": return { ok: true, status, data: { result: m.result } };
      default: return { ok: true, status, data: m.data !== undefined ? m.data : m.result };
    }
  }

  async answer(req) {
    if (req.target === "app") {
      if (!this.server) {
        this.problem("network", `the app requested ${req.method || "GET"} /${req.path} but no server is connected (open with server or start)`);
        return { ok: false, status: 0, error: "no server" };
      }
      try {
        const url = new URL(String(req.path || ""), this.server.replace(/\/?$/, "/"));
        for (const [k, v] of Object.entries(req.query || {})) url.searchParams.set(k, typeof v === "string" ? v : J(v));
        const res = await fetch(url, {
          method: req.method || "GET",
          headers: { "Content-Type": "application/json", "X-Aseman-User": SAMPLE_ENV.user.id, ...(req.headers || {}) },
          body: req.body !== undefined && (req.method || "GET") !== "GET" ? (typeof req.body === "string" ? req.body : J(req.body)) : undefined,
          signal: AbortSignal.timeout(Math.min(num(req.timeoutMs, 30000), 60000)),
        });
        const text = await res.text();
        if (res.status >= 500) this.problem("server", `the app's server answered ${req.method || "GET"} /${req.path} with HTTP ${res.status}: ${text.slice(0, 300)}`);
        return { ok: true, status: 200, data: { status: res.status, ok: res.ok, json: tryJSON(text), text, contentType: res.headers.get("content-type") || "" } };
      } catch (e) {
        this.problem("network", `the app's server did not answer ${req.method || "GET"} /${req.path}: ${e.message}`);
        return { ok: false, status: 0, error: e.message };
      }
    }
    const agents = (this.apps && this.apps.agents) || [{ id: "a1", name: "assistant", description: "sample agent" }];
    const tools = (this.apps && this.apps.apps) || [];
    switch (req.op) {
      case "context":
        return { ok: true, status: 200, data: { space: SAMPLE_ENV.space, user: SAMPLE_ENV.user, room: SAMPLE_ENV.room } };
      case "agents":
        return { ok: true, status: 200, data: { agents } };
      case "tools":
        return { ok: true, status: 200, data: { tools: tools.map((t) => ({ name: t.name, id: t.bot_id, microtools: t.microtools || [] })) } };
      case "microtools": {
        const t = tools.find((x) => x.name === (req.query || {}).tool);
        return { ok: true, status: 200, data: { microtools: (t && t.microtools) || [] } };
      }
      case "call": {
        const b = req.body || {};
        const t = tools.find((x) => x.name === b.tool);
        if (tools.length && !t) return { ok: false, status: 404, error: `no app "${b.tool}" in this space (APPS.json)` };
        return { ok: true, status: 200, data: { result: `Sample result of ${b.tool}.${b.microtool} (mock it: elpian_mock {op: "call", tool, microtool, result})` } };
      }
      case "ask": {
        const b = req.body || {};
        if (this.apps && this.apps.agents && !agents.some((a) => a.name === b.agent || a.id === b.agent)) return { ok: false, status: 404, error: `no agent "${b.agent}" in this space (APPS.json)` };
        const reply = /json/i.test(String(b.prompt || ""))
          ? "```json\n{\"ok\": true, \"items\": []}\n```"
          : "```openui\n{\"c\":\"Card\",\"p\":{\"title\":\"Sample\"},\"children\":[{\"c\":\"Markdown\",\"p\":{\"content\":\"**Sample** answer\"}}]}\n```";
        return { ok: true, status: 200, data: { agent: b.agent, reply } };
      }
      case "show":
        return { ok: true, status: 200, data: { ok: true } };
      default:
        this.problem("host", `unknown Aseman op "${req.op}" (use context, tools, microtools, call, agents, ask, show)`);
        return { ok: false, status: 404, error: "no such op" };
    }
  }

  // Answers every request the program made (and those its answers make),
  // except the ones a mock holds.
  async settle() {
    for (let round = 0; round < 50 && this.queue.length; round++) {
      const batch = this.queue.splice(0);
      for (const req of batch) {
        const m = this.findMock(req);
        if (m && m.hold) {
          m.used++;
          this.held.push({ req, mock: m });
          this.logRequest(req, null, true, true);
          continue;
        }
        if (m) m.used++;
        const t0 = Date.now();
        const result = m ? this.mockAnswer(m, req) : await this.answer(req);
        this.deliver(req, result, !!m, Date.now() - t0);
      }
    }
  }

  deliver(req, result, mocked, ms = 0) {
    this.logRequest(req, result, mocked, false, ms);
    const r = this.evaluate(`__asemanSettle(${J(J({ id: req.id, ...result }))})`, "settle.js");
    if (r.error) this.problem("exception", `after the host answered ${req.op || "/" + req.path}: ${r.error}`);
  }

  logRequest(req, result, mocked, held, ms = 0) {
    const what = req.target === "app" ? `${req.method || "GET"} /${req.path}` : `${req.op}${req.body && (req.body.agent || req.body.tool) ? ` ${req.body.agent || [req.body.tool, req.body.microtool].filter(Boolean).join(".")}` : ""}`;
    const status = held ? "held" : result.ok === false ? `failed ${result.status || ""} ${result.error || ""}`.trim() : req.target === "app" ? String(result.data && result.data.status) : "ok";
    const entry = { n: this.network.length + 1, target: req.target, what, op: req.op, path: req.path, method: req.method || (req.target === "app" ? "GET" : "POST"), body: req.body, status,
      code: held ? 0 : req.target === "app" && result.ok !== false ? result.data.status : result.ok === false ? result.status : 200, mocked, ms, after: this.history[this.history.length - 1] || "open" };
    const existing = held ? null : this.network.find((x) => x.reqId === req.id);
    if (existing) Object.assign(existing, { status: entry.status, code: entry.code, ms });
    else this.network.push({ ...entry, reqId: req.id });
    if (this.step) this.step.requests.push(entry);
  }

  // Lets held requests through: all, or those matching {op | path}.
  async release(filter) {
    const keep = [];
    const go = [];
    for (const h of this.held) {
      const f = filter && typeof filter === "object" ? filter : null;
      const hit = !f || (f.path !== undefined ? h.req.target === "app" && pathMatches(f.path, h.req.path) : f.op ? h.req.op === f.op : true);
      (hit ? go : keep).push(h);
    }
    this.held = keep;
    for (const { req, mock } of go) {
      const m = { ...mock, hold: false };
      this.deliver(req, mock.reply === undefined && mock.result === undefined && mock.json === undefined && mock.text === undefined && mock.data === undefined && !mock.error && !mock.status
        ? await this.answer(req) : this.mockAnswer(m, req), true);
    }
    await this.settle();
    return go.length;
  }

  // Moves the program's clock: timers due by then fire, in order.
  async advance(ms) {
    const until = this.clock + Math.max(0, num(ms));
    for (let n = 0; n < 1000; n++) {
      const next = this.timers.filter((t) => t.due <= until).sort((a, b) => a.due - b.due)[0];
      if (!next) break;
      this.clock = next.due;
      if (next.repeat) next.due += next.ms;
      else this.timers = this.timers.filter((t) => t !== next);
      const r = this.evaluate(`typeof globalThis[${J(next.handler)}] === "function" && globalThis[${J(next.handler)}]()`, "timer.js");
      if (r.error) this.problem("exception", `the timer ${next.handler} threw: ${r.error}`);
      await this.settle();
    }
    this.clock = until;
  }

  // ── the screen ──

  // Walks the latest render as the person sees it: entries for every node
  // shown, with what it shows, its events and whether touches reach it.
  index() {
    const entries = [];
    const walk = (node, parent, blocked) => {
      if (node === null || node === undefined || typeof node !== "object" || Array.isArray(node)) return;
      const p = node.props || {};
      const e = { node, type: node.type, key: node.key !== undefined && node.key !== null ? String(node.key) : null, props: p, parent, children: [],
        events: node.events && typeof node.events === "object" ? node.events : {}, label: ownLabel(node), blocked };
      e.disabled = p.disabled === true || p.enabled === false;
      e.uiKey = e.key !== null ? `k:${e.key}` : `${e.type}|${e.label}`;
      entries.push(e);
      if (parent) parent.children.push(e);
      let inner = blocked;
      if (p.style && (p.style.pointerEvents === "none" || p.style["pointer-events"] === "none")) inner = "touches pass through it (style.pointerEvents: none)";
      else if (TAPPED_WHOLE.has(e.type) && !blocked) inner = `it is inside a ${e.type}, which takes the touches (put the event on the ${e.type})`;
      for (const c of this.visibleChildren(e)) walk(c, e, inner);
    };
    walk(this.tree, null, null);
    for (let i = entries.length - 1; i >= 0; i--) {
      const e = entries[i];
      const parts = [e.label, ...e.children.map((c) => c.deep)].filter(Boolean);
      e.deep = clip(parts.join(" "), 160);
      e.text = TEXT_FIELDS.has(e.type) ? this.fieldValue(e) : "";
    }
    // Stable refs: one per control (by key, else type, label and order).
    const seen = new Map();
    for (const e of entries) {
      const base = e.key !== null ? `k:${e.key}` : `${e.type}|${norm(e.label || (Object.keys(e.events).length ? e.deep : ""))}`;
      const n = seen.get(base) || 0;
      seen.set(base, n + 1);
      e.nth = n;
      e.dkey = n ? `${base}#${n}` : base;
      e.hasEvents = Object.keys(e.events).length > 0;
      if (e.hasEvents || REFERABLE.has(e.type) || e.key !== null || SELECTS.has(e.type)) {
        if (!this.refs.has(e.dkey)) this.refs.set(e.dkey, `e${++this.refCount}`);
        e.ref = this.refs.get(e.dkey);
      }
    }
    this.entries = entries;
    this.byRef = new Map(entries.filter((e) => e.ref).map((e) => [e.ref, e]));
    this.noteCoverage();
    return entries;
  }

  visibleChildren(e) {
    const kids = Array.isArray(e.node.children) ? e.node.children : e.node.children ? [e.node.children] : [];
    const p = e.props;
    switch (e.type) {
      case "IndexedStack": return [kids[num(p.index, 0)]];
      case "AnimatedCrossFade": return [kids[p.showFirst === false ? 1 : 0]];
      case "Tabs": return [kids[this.ui.tabs.has(e.uiKey) ? this.ui.tabs.get(e.uiKey) : num(p.selected, 0)]];
      case "Expandable": return (this.ui.expanded.has(e.uiKey) ? this.ui.expanded.get(e.uiKey) : !!p.expanded) ? kids : [];
      default: return kids;
    }
  }

  // What a text field shows: what was typed into it, until the program
  // gives it another value.
  fieldValue(e) {
    const rec = this.ui.typed.get(e.uiKey);
    const v = str(e.props.value);
    if (rec && rec.base === v) return rec.text;
    if (rec) this.ui.typed.delete(e.uiKey);
    return v;
  }

  // The screen as an outline: one line per thing a person sees or uses.
  outline() {
    const lines = [];
    const visit = (e, depth) => {
      const shown = !(ARRANGE.has(e.type) && !e.hasEvents);
      if (shown && (!e.parent || !TAPPED_WHOLE.has(e.parent.type) || e.hasEvents)) {
        lines.push({ e, text: `${"  ".repeat(depth)}- ${this.describe(e)}` });
        for (const extra of this.details(e)) lines.push({ e, text: `${"  ".repeat(depth + 1)}${extra}` });
      }
      const inner = shown ? depth + 1 : depth;
      if (TAPPED_WHOLE.has(e.type)) {
        for (const c of e.children) if (c.hasEvents || c.children.some((g) => g.hasEvents)) visit(c, inner);
        return;
      }
      for (const c of e.children) visit(c, inner);
    };
    if (this.entries && this.entries[0]) visit(this.entries[0], 0);
    return lines;
  }

  describe(e) {
    const p = e.props;
    const bits = [e.type];
    if (e.ref) bits.push(`[${e.ref}]`);
    let label = e.label;
    if (!label && e.hasEvents && e.deep) label = e.deep;
    if (!label && TAPPED_WHOLE.has(e.type)) label = e.deep;
    if (label) bits.push(J(clip(label, e.type === "Markdown" || e.type === "Text" ? 140 : 60)));
    const flag = (cond, word) => cond && bits.push(word);
    switch (e.type) {
      case "TextField": case "SearchBar": case "input": case "textarea":
        bits.push(`value=${J(e.text)}`);
        if (p.error) bits.push(`error=${J(str(p.error))}`);
        if (p.obscureText) bits.push("obscured");
        break;
      case "Switch": case "Checkbox":
        bits.push(p.value === true || p.checked === true ? "on" : "off");
        break;
      case "Radio":
        bits.push(`value=${J(p.value)}`);
        flag(p.value !== undefined && p.value === p.groupValue, "selected");
        break;
      case "Slider": case "Rating":
        bits.push(`value=${p.value ?? 0} (${p.min ?? (e.type === "Rating" ? 1 : 0)}..${p.max ?? (e.type === "Rating" ? 5 : 1)})`);
        break;
      case "SegmentedButton": {
        const sel = [].concat(p.selected !== undefined ? p.selected : p.value).map(str);
        bits.push("options: " + itemsOf(p.segments || p.items).map((s) => s.label + (sel.includes(str(s.value)) ? "*" : "")).join(" | "));
        break;
      }
      case "NavigationBar": {
        const sel = num(p.selected ?? p.value, 0);
        bits.push("items: " + itemsOf(p.items || p.destinations).map((s, i) => s.label + (i === sel ? "*" : "") + (s.badge !== undefined && s.badge !== null && s.badge !== false ? ` (${s.badge})` : "")).join(" | "));
        break;
      }
      case "Tabs": {
        const sel = this.ui.tabs.has(e.uiKey) ? this.ui.tabs.get(e.uiKey) : num(p.selected, 0);
        bits.push("tabs: " + itemsOf(p.tabs || p.items).map((s, i) => s.label + (i === sel ? "*" : "")).join(" | "));
        break;
      }
      case "Expandable":
        bits.push((this.ui.expanded.has(e.uiKey) ? this.ui.expanded.get(e.uiKey) : !!p.expanded) ? "open" : "closed");
        break;
      case "Pagination":
        bits.push(`page ${p.page ?? p.value ?? 1} of ${p.pages ?? Math.ceil(num(p.total, 0) / 10)}`);
        break;
      case "Stepper":
        bits.push("steps: " + itemsOf(p.steps || p.items).map((s, i) => s.label + (i === num(p.current, -1) ? "*" : "")).join(" → "));
        break;
      case "Breadcrumbs":
        bits.push(itemsOf(p.items).map((s) => s.label).join(" › "));
        break;
      case "Stat": case "Gauge": case "Progress":
        if (p.value !== undefined) bits.push(`value=${J(p.value)}${p.format ? ` (${p.format})` : ""}`);
        if (p.delta !== undefined) bits.push(`delta=${p.delta}`);
        break;
      case "Callout":
        if (p.severity || p.status) bits.push(String(p.severity || p.status));
        if (p.title && p.text) bits.push(J(clip(str(p.text), 120)));
        break;
      case "ListTile":
        if (p.subtitle) bits.push(`— ${J(clip(str(p.subtitle), 60))}`);
        if (p.trailingText) bits.push(`trailing=${J(str(p.trailingText))}`);
        break;
      case "Calendar":
        bits.push(`month=${p.month || "current"}${p.selected ? ` selected=${p.selected}` : ""}, ${(p.events || []).length} events`);
        break;
      case "Chat": {
        const ms = p.messages || [];
        bits.push(`${ms.length} messages${p.typing ? ", typing…" : ""}`);
        break;
      }
      case "Image":
        bits.push(J(clip(str(p.alt || p.src), 50)));
        break;
      case "Canvas": case "CachedCanvas":
        bits.push(`${(p.commands || []).length} commands`);
        break;
      case "EmptyState":
        if (p.text) bits.push(`— ${J(clip(str(p.text), 60))}`);
        if (p.action) bits.push(`action=${J(str(p.action))}`);
        break;
      case "Countdown": case "Clock": case "QRCode": case "Tag": case "Avatar":
        break;
      default:
        if (!label && p.value !== undefined && (typeof p.value !== "object" || p.value === null)) bits.push(`value=${J(p.value)}`);
    }
    if (p.icon && typeof p.icon === "string" && !["Icon"].includes(e.type)) bits.push(`icon=${p.icon}`);
    else if (e.type === "Icon" && p.icon) bits.push(`icon=${p.icon}`);
    if (e.type !== "SegmentedButton" && e.type !== "NavigationBar" && e.type !== "Tabs" && e.type !== "Radio") flag(p.selected === true, "selected");
    flag(p.loading === true, "loading");
    flag(e.disabled, "disabled");
    if (e.hasEvents) bits.push(`(on: ${Object.keys(e.events).join(", ")})`);
    else if (EXPECTS[e.type]) bits.push(`(no ${EXPECTS[e.type]} handler)`);
    if (e.blocked && e.hasEvents) bits.push(`[unreachable: ${e.blocked}]`);
    return bits.join(" ");
  }

  // Lines under a node: the rows of a table or list view, the cards of a
  // board, the last messages of a chat.
  details(e) {
    const p = e.props;
    const out = [];
    const rowsOf = (rows, n = 6) => {
      const list = Array.isArray(rows) ? rows : [];
      list.slice(0, n).forEach((r, i) => out.push(`· row ${i}: ${rowText(r)}`));
      if (list.length > n) out.push(`· … ${list.length - n} more rows (${list.length} in all)`);
      if (!list.length) out.push(`· (no rows${p.emptyText ? `: ${J(str(p.emptyText))}` : ""})`);
    };
    switch (e.type) {
      case "DataGrid": case "Leaderboard": case "Timeline": case "PivotTable": rowsOf(p.data || p.items || p.rows); break;
      case "Chart": rowsOf(p.data || p.values, 4); break;
      case "Kanban":
        for (const c of itemsOf(p.columns)) out.push(`· column ${J(c.label)}: ${((c.raw && (c.raw.cards || c.raw.items)) || []).map((k) => J(str(k && typeof k === "object" ? k.title ?? k.label : k))).join(", ") || "(empty)"}`);
        break;
      case "Chat":
        for (const m of (p.messages || []).slice(-4)) out.push(`· ${str(m.role || m.from || m.name)}: ${J(clip(str(m.text), 100))}`);
        if (Array.isArray(p.suggestions) && p.suggestions.length) out.push(`· suggestions: ${p.suggestions.map((s) => J(str(s && typeof s === "object" ? s.text ?? s.label : s))).join(" | ")}`);
        break;
      case "KeyValue":
        for (const it of (p.items || []).slice(0, 8)) out.push(`· ${str(it.label ?? it.key)}: ${str(it.value)}`);
        if (!p.items && p.data && typeof p.data === "object") for (const [k, v] of Object.entries(p.data).slice(0, 8)) out.push(`· ${k}: ${str(v)}`);
        break;
      case "select":
        out.push(`· options: ${e.children.filter((c) => c.type === "option").map((c) => J(c.label)).join(" | ")}`);
        break;
    }
    return out;
  }

  snapshotText() {
    const v = this.env.viewport;
    const head = `Screen ${v.width}×${v.height} (${v.sizeClass}, ${this.env.theme.mode}${this.env.display === "compact" ? ", phone widget" : ""}) · render ${this.renders}` +
      (this.held.length ? ` · ${this.held.length} request(s) held` : "") + (this.queue.length ? ` · ${this.queue.length} pending` : "");
    const lines = this.outline().map((l) => l.text);
    return [head, ...(lines.length ? lines : ["(nothing on screen)"])].join("\n");
  }

  // ── finding controls ──

  // A target: a ref ("e12"), a selector {ref, key, type, text, icon, nth,
  // within}, or a string (a ref, else the visible text of the control).
  resolve(target, { many = false, prefer = "events" } = {}) {
    if (target === undefined || target === null || target === "") throw new DriveError("name the control: a ref (e12), {key}, {text}, {type, text} or the text it shows");
    let sel = target;
    if (typeof target === "string") sel = /^e\d+$/.test(target.trim()) ? { ref: target.trim() } : { text: target };
    if (typeof sel !== "object") throw new DriveError(`a target is a ref, a selector object or text: ${J(target)}`);
    let pool = this.entries || [];
    if (sel.within) {
      const scope = this.resolve(sel.within, { prefer: "any" });
      const inside = new Set();
      const add = (e) => { inside.add(e); e.children.forEach(add); };
      add(scope);
      pool = pool.filter((e) => inside.has(e) && e !== scope);
    }
    if (sel.ref) {
      const e = this.byRef.get(sel.ref);
      if (!e) {
        const gone = [...this.refs.entries()].find(([, r]) => r === sel.ref);
        throw new DriveError(gone ? `${sel.ref} (${gone[0].replace(/^k:/, "key ")}) is not on the screen now: take a new snapshot` : `no control ${sel.ref}: take a snapshot to see the refs`);
      }
      return many ? [e] : e;
    }
    let hits = pool.filter((e) => {
      if (sel.key !== undefined && e.key !== String(sel.key)) return false;
      if (sel.type && e.type !== sel.type) return false;
      if (sel.icon && e.props.icon !== sel.icon) return false;
      return true;
    });
    if (sel.text !== undefined) {
      const want = norm(sel.text);
      const own = (e) => [e.label, e.text, e.type === "Icon" || e.type === "IconButton" ? e.props.icon : "", e.props.tooltip].filter(Boolean).map(norm);
      const exact = hits.filter((e) => own(e).includes(want));
      const deepExact = hits.filter((e) => e.hasEvents && norm(e.deep) === want);
      const contains = hits.filter((e) => own(e).some((s) => s.includes(want)));
      const deepContains = hits.filter((e) => e.hasEvents && norm(e.deep).includes(want));
      hits = exact.length ? exact : deepExact.length ? deepExact : contains.length ? contains : deepContains;
      if (!hits.length && typeof target === "string") {
        // The option of a control (a destination, a segment, a tab), or a
        // node type named on its own.
        const opts = pool.filter((e) => OPTION_CONTROLS[e.type] && this.optionsOf(e).some((o) => norm(o.label) === want));
        if (opts.length === 1) {
          this.optionHit = { entry: opts[0], option: this.optionsOf(opts[0]).find((o) => norm(o.label) === want).label };
          return many ? opts : opts[0];
        }
        if (TYPES[target.trim()] || KNOWN.has(target.trim())) hits = pool.filter((e) => e.type === target.trim());
      }
    }
    if (!hits.length) throw new DriveError(`nothing on the screen matches ${J(sel)}${this.suggest(sel)}`);
    if (many) return hits;
    if (sel.nth !== undefined) {
      const h = hits[num(sel.nth, 0)];
      if (!h) throw new DriveError(`${J(sel)}: only ${hits.length} match`);
      return h;
    }
    if (hits.length > 1 && prefer === "events") {
      // A label and the control it labels: the innermost control that acts.
      const acting = hits.filter((e) => e.hasEvents || TAPPED_WHOLE.has(e.type) || TEXT_FIELDS.has(e.type));
      const leaves = (acting.length ? acting : hits).filter((e, _, all) => !all.some((o) => o !== e && isAncestor(e, o)));
      if (leaves.length === 1) return leaves[0];
      hits = leaves.length ? leaves : hits;
    }
    if (hits.length > 1) {
      throw new DriveError(`${J(sel)} matches ${hits.length} controls: pick one by ref, or add nth (0-based) or within:\n` +
        hits.slice(0, 12).map((e, i) => `  nth ${i}: ${this.describe(e)}`).join("\n"));
    }
    return hits[0];
  }

  optionsOf(e) {
    const p = e.props;
    switch (e.type) {
      case "SegmentedButton": return itemsOf(p.segments || p.items);
      case "NavigationBar": return itemsOf(p.items || p.destinations);
      case "Tabs": return itemsOf(p.tabs || p.items);
      case "Breadcrumbs": return itemsOf(p.items);
      case "Stepper": return itemsOf(p.steps || p.items);
      case "Chat": return itemsOf(p.suggestions);
      default: return [];
    }
  }

  suggest(sel) {
    const want = sel.text !== undefined ? norm(sel.text) : "";
    const pool = (this.entries || []).filter((e) => e.ref && (e.hasEvents || REFERABLE.has(e.type)));
    const near = want ? pool.filter((e) => want.split(" ").some((w) => w.length > 2 && norm(`${e.label} ${e.deep}`).includes(w))) : [];
    const list = (near.length ? near : pool).slice(0, 10).map((e) => `  ${this.describe(e)}`);
    return list.length ? `. ${near.length ? "Close" : "Controls on the screen"}:\n${list.join("\n")}` : ". The screen has no controls: take a snapshot.";
  }

  // A selector that finds the same control again in a replay.
  selectorOf(e) {
    if (e.key !== null) return { key: e.key };
    const label = e.label || (e.hasEvents ? e.deep : "");
    const sel = label ? { type: e.type, text: label } : { type: e.type };
    const same = (this.entries || []).filter((o) => o.type === e.type && (label ? (o.label || (o.hasEvents ? o.deep : "")) === label : true));
    if (same.length > 1) sel.nth = same.indexOf(e);
    return sel;
  }

  // ── events ──

  clientEvent(e, event, fields = {}, data = {}) {
    const id = e.key || "element_1";
    return { ...data, type: event, eventType: event, target: id, currentTarget: id, timestamp: new Date(Date.UTC(2026, 0, 1, 9) + this.clock).toISOString().replace("Z", ""), phase: "atTarget", data, ...fields };
  }

  pointer(e, event, x, y, dx = 0, dy = 0, data = {}) {
    return this.clientEvent(e, event, { position: { x: 16 + x, y: 120 + y }, localPosition: { x, y }, delta: { x: dx, y: dy }, buttons: 1, pressure: 1, distance: 0, pointerId: 1 }, data);
  }

  // Runs the handler a node names for an event: false when it could not.
  fire(e, event, sample) {
    const name = e.events[event];
    if (typeof name !== "string" || !name) {
      this.problem("exception", `${this.describe(e)}: events.${event} must name a global function`);
      return false;
    }
    const isFn = this.evaluate(`typeof globalThis[${J(name)}] === "function"`);
    if (isFn.value !== true) {
      this.problem("exception", `${this.nameOf(e)}: events.${event} names "${name}", which is not a global function`);
      return false;
    }
    this.cover(e, event);
    const r = this.evaluate(`globalThis[${J(name)}](${J(typed(sample))})`, "event.js");
    if (r.error) {
      this.problem("exception", `${this.nameOf(e)}: handler ${name} (${event}) threw: ${r.error}`);
      return false;
    }
    return true;
  }

  // The nearest node from e up that takes one of the events (a touch on a
  // label reaches the control around it); a whole-tapped control stops it.
  bubble(e, events) {
    for (let x = e; x; x = x.parent) {
      if (events.some((ev) => x.events[ev])) return x;
      if (x !== e && TAPPED_WHOLE.has(x.type)) return null;
      if (x === e && TAPPED_WHOLE.has(x.type) && !TEXT_FIELDS.has(x.type)) return null;
    }
    return null;
  }

  // A control as a note names it: its type and what it shows, else its key.
  nameOf(e) {
    const label = e.label || e.deep || "";
    return label ? `${e.type} ${J(clip(label))}` : e.key !== null ? `${e.type} (key ${e.key})` : e.type;
  }

  refuse(e, why) {
    return { done: false, note: `${this.describe(e)}: ${why}` };
  }

  reachable(e) {
    if (e.disabled) return "it is disabled: nothing happens when a person touches it";
    if (e.blocked) return `a touch never reaches it: ${e.blocked}`;
    return null;
  }

  // ── actions (each returns {done, note, fired}) ──

  tap(e, { kind = "tap" } = {}) {
    const p = e.props;
    if (kind === "tap") {
      if (e.type === "Expandable" && !e.hasEvents) {
        const open = !(this.ui.expanded.has(e.uiKey) ? this.ui.expanded.get(e.uiKey) : !!p.expanded);
        this.ui.expanded.set(e.uiKey, open);
        return { done: true, note: `${open ? "opened" : "closed"} ${this.nameOf(e)}` };
      }
      if ((e.type === "Switch" || e.type === "Checkbox") && e.events.change) return this.toggle(e);
      if (e.type === "Chip" && !e.events.tap && !e.events.click && e.events.change) return this.toggle(e);
      if (e.type === "Radio" && e.events.change) return this.choose(e, p.value);
      if (e.type === "EmptyState" && e.events.action && !e.events.tap) {
        const why = this.reachable(e);
        if (why) return this.refuse(e, why);
        return { done: this.fire(e, "action", this.clientEvent(e, "action")), note: `tapped the action ${J(str(p.action))}` };
      }
      if (["SegmentedButton", "NavigationBar", "Tabs", "Pagination", "Stepper", "Breadcrumbs", "Carousel", "Slider", "Rating", "select"].includes(e.type) && !e.events.tap) {
        throw new DriveError(`${this.describe(e)}: choose one of its options with elpian_select (value: the option's label or index)`);
      }
      if (TEXT_FIELDS.has(e.type) && !e.events.tap) return { done: true, note: `focused ${this.nameOf(e)} (type into it with elpian_type)` };
    }
    const events = kind === "tap" ? ["tap", "click"] : kind === "double_tap" ? ["doubletap"] : ["longpress", "longpressstart"];
    const at = this.bubble(e, events);
    if (!at) {
      if (EXPECTS[e.type] === "tap" && kind === "tap") {
        this.problem("dead-control", `${this.nameOf(e)} does nothing when tapped: it has no tap handler`);
        return this.refuse(e, "nothing happens: it has no tap handler (a dead control)");
      }
      return this.refuse(e, `nothing happens: neither it nor anything around it handles ${events[0]}`);
    }
    const why = this.reachable(at);
    if (why) return this.refuse(at, why);
    const fired = [];
    const run = (ev, sample) => {
      if (!at.events[ev]) return true;
      fired.push(ev);
      return this.fire(at, ev, sample);
    };
    let ok = true;
    if (kind === "tap") {
      ok = run("tapdown", this.pointer(at, "tapdown", 24, 20)) && run("tapup", this.pointer(at, "tapup", 24, 20)) &&
        (at.events.tap ? run("tap", this.clientEvent(at, "tap")) : run("click", this.clientEvent(at, "click")));
    } else if (kind === "double_tap") {
      ok = run("doubletap", this.clientEvent(at, "doubletap"));
    } else {
      ok = run("longpressstart", this.pointer(at, "longpressstart", 24, 20)) && run("longpress", this.clientEvent(at, "longpress")) &&
        run("longpressend", this.pointer(at, "longpressend", 24, 20));
    }
    return { done: ok, fired, on: at, note: `${kind.replace("_", " ")} ${this.nameOf(at)}${at !== e ? ` (the touch on ${this.nameOf(e)} reached it)` : ""}` };
  }

  type(e, text, { clear = true, submit = false, keystrokes = false } = {}) {
    let f = e;
    if (!TEXT_FIELDS.has(f.type)) {
      const inner = [];
      const find = (x) => { if (TEXT_FIELDS.has(x.type)) inner.push(x); x.children.forEach(find); };
      find(e);
      f = inner.length === 1 ? inner[0] : null;
      for (let x = e.parent; !f && x; x = x.parent) if (TEXT_FIELDS.has(x.type)) f = x;
      if (!f) throw new DriveError(`${this.describe(e)} is not a text field${inner.length > 1 ? " (it holds several: target one)" : ""}`);
    }
    const why = this.reachable(f);
    if (why) return this.refuse(f, why);
    const before = str(f.props.value);
    const value = (clear ? "" : this.fieldValue(f)) + String(text ?? "");
    const fired = [];
    if (f.events.input) {
      const steps = keystrokes ? Array.from({ length: value.length }, (_, i) => value.slice(0, i + 1)) : [value];
      if (keystrokes && clear && !value.length) steps.push("");
      for (const v of steps.length ? steps : [value]) {
        fired.push("input");
        if (!this.fire(f, "input", this.clientEvent(f, "input", { value: v, inputType: "text" }, { value: v }))) return { done: false, fired };
      }
    } else if (f.events.change) {
      fired.push("change");
      if (!this.fire(f, "change", this.clientEvent(f, "change", {}, { value }))) return { done: false, fired };
    } else {
      this.problem("dead-control", `${this.nameOf(f)} has no input handler: the program never sees what is typed`);
    }
    this.ui.typed.set(f.uiKey, { text: value, base: before });
    let note = `typed ${J(value)} into ${this.nameOf(f)}`;
    if (submit) {
      const s = this.submit(f, value);
      fired.push(...(s.fired || []));
      note += s.done ? " and submitted" : `; ${s.note}`;
      if (!s.done && s.failed) return { done: false, fired, note };
    }
    return { done: true, fired, note, on: f };
  }

  submit(f, value) {
    if (!f.events.submit) return { done: false, note: "submit: it has no submit handler (enter does nothing)" };
    const v = value !== undefined ? value : this.fieldValue(f);
    const ok = this.fire(f, "submit", this.clientEvent(f, "submit", { value: v }, { value: v }));
    return { done: ok, failed: !ok, fired: ["submit"], note: ok ? `submitted ${this.nameOf(f)}` : "submit failed" };
  }

  toggle(e, on) {
    const p = e.props;
    if (e.type === "Expandable") {
      const open = on === undefined ? !(this.ui.expanded.has(e.uiKey) ? this.ui.expanded.get(e.uiKey) : !!p.expanded) : !!on;
      this.ui.expanded.set(e.uiKey, open);
      return { done: true, note: `${open ? "opened" : "closed"} Expandable ${J(e.label)}` };
    }
    if (!["Switch", "Checkbox", "Chip", "input"].includes(e.type)) throw new DriveError(`${this.describe(e)} is not a switch, checkbox, filter chip or expandable panel`);
    const current = e.type === "Chip" ? p.selected === true : p.value === true || p.checked === true;
    const next = on === undefined ? !current : !!on;
    if (!e.events.change) {
      if (EXPECTS[e.type]) this.problem("dead-control", `${this.nameOf(e)} does nothing when toggled: it has no change handler`);
      return this.refuse(e, "nothing happens: it has no change handler");
    }
    const why = this.reachable(e);
    if (why) return this.refuse(e, why);
    if (next === current && on !== undefined) return { done: true, note: `${this.nameOf(e)} is already ${next ? "on" : "off"}` };
    return { done: this.fire(e, "change", this.clientEvent(e, "change", {}, { value: next })), fired: ["change"], note: `switched ${this.nameOf(e)} ${next ? "on" : "off"}` };
  }

  // Picks an option of a control: a segment, a destination, a tab, a page,
  // a slider value, a radio, a row of a table, a day of a calendar, …
  choose(e, option) {
    const p = e.props;
    const why = this.reachable(e);
    const pick = (items, opt, { index = true } = {}) => {
      if (typeof opt === "number" && index && opt >= 0 && opt < items.length && Number.isInteger(opt)) return opt;
      const w = norm(str(opt));
      let i = items.findIndex((s) => norm(s.label) === w);
      if (i < 0) i = items.findIndex((s) => norm(str(s.value)) === w);
      if (i < 0 && w) i = items.findIndex((s) => norm(s.label).includes(w));
      if (i < 0) throw new DriveError(`${this.describe(e)} has no option ${J(opt)}: ${items.map((s) => J(s.label)).join(", ")}`);
      return i;
    };
    const change = (value, extra = {}, note) => {
      if (why) return this.refuse(e, why);
      if (!e.events.change) {
        if (EXPECTS[e.type]) this.problem("dead-control", `${this.nameOf(e)} does nothing when changed: it has no change handler`);
        return { done: e.type === "Tabs" || e.type === "Carousel", note: `${note} (the program has no change handler)` };
      }
      return { done: this.fire(e, "change", this.clientEvent(e, "change", {}, { value, ...extra })), fired: ["change"], note };
    };
    const select = (data, note) => {
      if (why) return this.refuse(e, why);
      if (!e.events.select) return this.refuse(e, "nothing happens: it has no select handler");
      return { done: this.fire(e, "select", this.clientEvent(e, "select", {}, data)), fired: ["select"], note };
    };
    switch (e.type) {
      case "SegmentedButton": {
        const items = itemsOf(p.segments || p.items);
        const i = pick(items, option);
        const v = str(items[i].value);
        if (p.multi) {
          const cur = [].concat(p.selected ?? p.value ?? []).map(str);
          const next = cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v];
          return change(items.map((s) => str(s.value)).filter((x) => next.includes(x)), {}, `chose ${J(items[i].label)} in ${e.type}`);
        }
        return change(v, {}, `chose ${J(items[i].label)} in ${e.type}`);
      }
      case "NavigationBar": {
        const items = itemsOf(p.items || p.destinations);
        const i = pick(items, option);
        return change(i, {}, `went to ${J(items[i].label)} on the NavigationBar`);
      }
      case "Tabs": {
        const items = itemsOf(p.tabs || p.items);
        const i = pick(items, option);
        if (why) return this.refuse(e, why);
        this.ui.tabs.set(e.uiKey, i);
        const r = change(i, { label: items[i].label }, `opened the tab ${J(items[i].label)}`);
        return { ...r, done: r.done !== false };
      }
      case "Carousel": {
        const n = (Array.isArray(p.items) ? p.items.length : 0) || (e.node.children || []).length;
        const i = num(option, -1);
        if (i < 0 || i >= n) throw new DriveError(`${this.describe(e)} has slides 0..${n - 1}`);
        return change(i, {}, `showed slide ${i}`);
      }
      case "Pagination": {
        const pages = num(p.pages, Math.ceil(num(p.total, 0) / 10)) || 1;
        const n = num(option, NaN);
        if (!(n >= 1 && n <= pages)) throw new DriveError(`${this.describe(e)}: a page from 1 to ${pages}`);
        return change(n, {}, `went to page ${n}`);
      }
      case "Slider": case "Rating": {
        const min = num(p.min, e.type === "Rating" ? 1 : 0);
        const max = num(p.max, e.type === "Rating" ? 5 : 1);
        let v = num(option, NaN);
        if (!Number.isFinite(v)) throw new DriveError(`${this.describe(e)}: a number from ${min} to ${max}`);
        v = Math.min(max, Math.max(min, v));
        if (p.divisions || p.step) {
          const step = p.step ? num(p.step, 1) : (max - min) / num(p.divisions, 1);
          v = min + Math.round((v - min) / step) * step;
        }
        return change(v, {}, `set ${this.nameOf(e)} to ${v}`);
      }
      case "Radio":
        if (option !== undefined && str(option) !== str(p.value)) throw new DriveError(`${this.describe(e)} is the option ${J(p.value)}: target the Radio of ${J(option)}`);
        return change(p.value, {}, `chose the radio ${J(p.value)}`);
      case "Switch": case "Checkbox": case "Chip":
        return this.toggle(e, option === undefined ? undefined : option === true || option === "true" || option === "on");
      case "select": {
        const opts = e.children.filter((c) => c.type === "option").map((c) => ({ label: c.label, value: c.props.value ?? c.label }));
        const i = pick(opts, option, { index: false });
        return change(opts[i].value, {}, `chose ${J(opts[i].label)}`);
      }
      case "Stepper": {
        const items = itemsOf(p.steps || p.items);
        const i = pick(items, option);
        return select({ index: i, step: items[i].raw }, `chose the step ${J(items[i].label)}`);
      }
      case "Breadcrumbs": {
        const items = itemsOf(p.items);
        const i = pick(items, option);
        return select({ index: i, label: items[i].label }, `went to ${J(items[i].label)}`);
      }
      case "Chat": {
        const items = itemsOf(p.suggestions);
        const i = pick(items, option, { index: false });
        return select({ text: items[i].label }, `chose the suggestion ${J(items[i].label)}`);
      }
      case "Calendar": {
        const s = str(option);
        if (/^\d{4}-\d{2}$/.test(s)) return change(undefined, { month: s }, `showed the month ${s}`);
        if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) throw new DriveError(`${this.describe(e)}: a day (yyyy-MM-dd) or a month (yyyy-MM)`);
        return select({ date: s, events: (p.events || []).filter((ev) => str(ev.date || ev.start).startsWith(s)) }, `chose the day ${s}`);
      }
      case "Kanban": {
        const cols = Array.isArray(p.columns) ? p.columns : [];
        const want = option && typeof option === "object" ? option.card : option;
        for (let c = 0; c < cols.length; c++) {
          const cards = cols[c].cards || cols[c].items || [];
          const i = cards.findIndex((k) => norm(str(k && typeof k === "object" ? k.title ?? k.label : k)) === norm(str(want)));
          if (i >= 0) return select({ column: c, index: i, card: cards[i], columnId: cols[c].id ?? cols[c].title }, `opened the card ${J(str(want))}`);
        }
        throw new DriveError(`${this.describe(e)} has no card ${J(want)}`);
      }
      default: {
        if (!SELECTS.has(e.type) && !e.events.select) throw new DriveError(`${this.describe(e)} has no options to choose: use elpian_tap, elpian_type or elpian_toggle`);
        const rows = p.data || p.items || p.rows || p.values || [];
        let i = typeof option === "number" ? option : -1;
        if (i < 0) {
          const w = norm(str(option));
          i = rows.findIndex((r) => r && typeof r === "object" && Object.values(r).some((v) => norm(str(v)) === w));
          if (i < 0) i = rows.findIndex((r) => norm(rowText(r)).includes(w));
        }
        if (i < 0 || i >= rows.length) throw new DriveError(`${this.describe(e)} has no row ${J(option)} (${rows.length} rows: pass an index or a cell's text)`);
        return select({ index: i, row: rows[i] }, `chose row ${i} (${clip(rowText(rows[i]), 50)})`);
      }
    }
  }

  // Gestures that follow the finger, swipes, drags and drops.
  gesture(e, kind, o = {}) {
    if (kind === "tap" || kind === "double_tap" || kind === "long_press") return this.tap(e, { kind });
    const seqRun = (at, seq) => {
      const why = this.reachable(at);
      if (why) return this.refuse(at, why);
      const fired = [];
      for (const [ev, sample] of seq) {
        if (!at.events[ev]) continue;
        fired.push(ev);
        if (!this.fire(at, ev, sample)) return { done: false, fired };
      }
      return { done: true, fired, on: at };
    };
    switch (kind) {
      case "swipe": {
        const dir = String(o.direction || "left").toLowerCase();
        if (!["left", "right", "up", "down"].includes(dir)) throw new DriveError("direction: left, right, up or down");
        const ev = `swipe${dir}`;
        const at = this.bubble(e, [ev, "dismiss", "dismissed"]) || (e.type === "Carousel" ? e : null);
        if (!at) return this.refuse(e, `nothing happens: nothing here handles ${ev}`);
        if (at.type === "Carousel" && !at.events[ev]) {
          const cur = num(at.props.value, 0);
          return this.choose(at, Math.max(0, cur + (dir === "left" ? 1 : -1)));
        }
        if (at.type === "Dismissible" && !at.events[ev]) {
          const data = { direction: dir === "left" ? "endToStart" : dir === "right" ? "startToEnd" : dir === "up" ? "up" : "down" };
          const r = seqRun(at, [["dismissed", this.clientEvent(at, "dismissed", {}, data)], ["dismiss", this.clientEvent(at, "dismiss", {}, data)]]);
          return { ...r, note: `swiped ${dir} to dismiss ${J(clip(at.deep || ""))}` };
        }
        const v = { left: { x: -900, y: 0 }, right: { x: 900, y: 0 }, up: { x: 0, y: -900 }, down: { x: 0, y: 900 } }[dir];
        const r = seqRun(at, [[ev, this.clientEvent(at, ev, { velocity: v, scale: 1, rotation: 0, focalPoint: { x: 0, y: 0 } })]]);
        return { ...r, note: `swiped ${dir} on ${this.nameOf(at)}` };
      }
      case "drag": {
        if (o.to && (typeof o.to === "string" || o.to.ref || o.to.key || o.to.text)) return this.drop(e, this.resolve(o.to, { prefer: "any" }));
        const from = o.from || { x: 20, y: 20 };
        const to = o.to || { x: from.x + 120, y: from.y + 80 };
        const n = Math.max(1, Math.min(50, num(o.steps, 4)));
        const at = this.bubble(e, ["dragstart", "drag", "dragend", "pointerdown", "pointermove", "pointerup"]);
        if (!at) return this.refuse(e, "nothing happens: nothing here follows a drag (dragstart/drag/dragend or pointer events)");
        const pts = Array.from({ length: n + 1 }, (_, i) => ({ x: from.x + ((to.x - from.x) * i) / n, y: from.y + ((to.y - from.y) * i) / n }));
        const seq = [];
        const usesDrag = at.events.dragstart || at.events.drag || at.events.dragend;
        const [s, mv, end] = usesDrag ? ["dragstart", "drag", "dragend"] : ["pointerdown", "pointermove", "pointerup"];
        seq.push([s, this.pointer(at, s, pts[0].x, pts[0].y)]);
        for (let i = 1; i <= n; i++) seq.push([mv, this.pointer(at, mv, pts[i].x, pts[i].y, pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)]);
        seq.push([end, this.pointer(at, end, to.x, to.y, 0, 0, usesDrag ? { velocity: { x: (to.x - from.x) * 2, y: (to.y - from.y) * 2 } } : {})]);
        const r = seqRun(at, seq);
        return { ...r, note: `dragged on ${this.nameOf(at)} from (${from.x}, ${from.y}) to (${to.x}, ${to.y}) in ${n} moves` };
      }
      case "pinch": {
        const scale = num(o.scale, 1.5);
        const rotation = num(o.rotation, 0);
        const at = this.bubble(e, ["scalestart", "scaleupdate", "scaleend", "pinchstart", "pinchupdate", "pinchend", "rotatestart", "rotateupdate", "rotateend"]);
        if (!at) return this.refuse(e, "nothing happens: nothing here handles pinch or scale events");
        const g = (ev, s, r) => this.clientEvent(at, ev, { velocity: { x: 0, y: 0 }, scale: s, rotation: r, focalPoint: { x: 180, y: 260 } }, { localFocalPoint: { x: 164, y: 140 } });
        const seq = [];
        for (const pre of ["scale", "pinch", "rotate"]) {
          if (!at.events[`${pre}start`] && !at.events[`${pre}update`] && !at.events[`${pre}end`]) continue;
          seq.push([`${pre}start`, g(`${pre}start`, 1, 0)]);
          for (let i = 1; i <= 3; i++) seq.push([`${pre}update`, g(`${pre}update`, 1 + ((scale - 1) * i) / 3, (rotation * i) / 3)]);
          seq.push([`${pre}end`, g(`${pre}end`, 1, 0)]);
        }
        const r = seqRun(at, seq);
        return { ...r, note: `pinched ${at.type} to ×${scale}${rotation ? `, rotated ${rotation} rad` : ""}` };
      }
      case "hover": {
        const at = this.bubble(e, ["pointerenter", "pointerhover", "pointerexit", "hover"]);
        if (!at) return this.refuse(e, "nothing happens: nothing here handles hover");
        const r = seqRun(at, [["pointerenter", this.pointer(at, "pointerenter", 10, 10)], ["hover", this.clientEvent(at, "hover", {}, { hovering: true })],
          ["pointerhover", this.pointer(at, "pointerhover", 12, 12)], ["pointerexit", this.pointer(at, "pointerexit", 400, 400)], ["hover", this.clientEvent(at, "hover", {}, { hovering: false })]]);
        return { ...r, note: `hovered over ${at.type}` };
      }
      case "move": {
        if (e.type !== "Kanban") throw new DriveError("move takes a Kanban: {card, to: column}");
        const cols = Array.isArray(e.props.columns) ? e.props.columns : [];
        const title = (c) => norm(str(c.title ?? c.label ?? c.id));
        const to = cols.findIndex((c) => title(c) === norm(str(o.to)) || str(c.id) === str(o.to));
        if (to < 0) throw new DriveError(`${this.describe(e)} has no column ${J(o.to)}`);
        for (let c = 0; c < cols.length; c++) {
          const cards = cols[c].cards || cols[c].items || [];
          const i = cards.findIndex((k) => norm(str(k && typeof k === "object" ? k.title ?? k.label : k)) === norm(str(o.card)));
          if (i < 0) continue;
          if (c === to) return { done: true, note: `the card ${J(o.card)} is already in ${J(o.to)}` };
          const r = seqRun(e, [["move", this.clientEvent(e, "move", {}, { card: cards[i], from: c, to, index: (cols[to].cards || cols[to].items || []).length, fromId: cols[c].id ?? cols[c].title, toId: cols[to].id ?? cols[to].title })]]);
          if (!e.events.move) return this.refuse(e, "nothing happens: it has no move handler");
          return { ...r, note: `moved the card ${J(o.card)} to ${J(o.to)}` };
        }
        throw new DriveError(`${this.describe(e)} has no card ${J(o.card)}`);
      }
      case "link": {
        const at = this.bubble(e, ["link"]);
        if (!at) return this.refuse(e, "nothing happens: it has no link handler");
        const r = seqRun(at, [["link", this.clientEvent(at, "link", {}, { href: String(o.href || "") })]]);
        return { ...r, note: `followed the link ${o.href}` };
      }
      case "remove": {
        if (!e.events.remove) return this.refuse(e, "nothing happens: it has no remove handler");
        const r = seqRun(e, [["remove", this.clientEvent(e, "remove")]]);
        return { ...r, note: `removed the chip ${J(e.label)}` };
      }
      default:
        throw new DriveError(`unknown gesture ${J(kind)}: tap, double_tap, long_press, swipe, drag, pinch, hover, move, link, remove`);
    }
  }

  // Drags a Draggable onto a DragTarget (or a node with drag events onto
  // another place).
  drop(src, dst) {
    const drag = this.bubble(src, ["dragstart", "drag", "dragend", "dragcomplete"]) || src;
    let target = dst;
    while (target && !target.events.accept && target.type !== "DragTarget") target = target.parent;
    if (!target) throw new DriveError(`${this.describe(dst)} does not accept drops (a DragTarget with accept)`);
    const why = this.reachable(drag) || this.reachable(target);
    if (why) return this.refuse(drag, why);
    const data = drag.props.data;
    const fired = [];
    const run = (at, ev, sample) => {
      if (!at.events[ev]) return true;
      fired.push(ev);
      return this.fire(at, ev, sample);
    };
    const ok = run(drag, "dragstart", this.pointer(drag, "dragstart", 10, 10, 0, 0, { data })) &&
      run(target, "dragover", this.clientEvent(target, "dragover", {}, { data })) &&
      run(target, "accept", this.clientEvent(target, "accept", {}, { data })) &&
      run(drag, "dragend", this.pointer(drag, "dragend", 40, 40, 0, 0, { data, wasAccepted: true, velocity: { x: 0, y: 0 } })) &&
      run(drag, "dragcomplete", this.clientEvent(drag, "dragcomplete", {}, { data }));
    return { done: ok, fired, note: `dropped ${this.nameOf(drag)} on ${this.nameOf(target)}` };
  }

  // ── a step: an action, a wait, an assertion… ──

  // Runs one step (the unit of a scenario and of every tool) and answers
  // with what happened. step: {do, target, …} or {expect: {…}}.
  async run(step) {
    if (!step || typeof step !== "object") throw new DriveError("a step is {do: \"tap\", target: …} or {expect: {…}}");
    if (step.expect) {
      const r = await this.expect(step.expect);
      this.record({ expect: this.portableExpect(step.expect) });
      return r;
    }
    let kind = step.do;
    const before = this.outline().map((l) => l.text.trim());
    this.step = { problems: [], requests: [] };
    let r;
    let entry = null;
    let target;
    this.optionHit = null;
    // Tapping an option's label (a destination, a segment, a tab) picks it.
    if ((kind === "tap" || kind === "select") && step.target !== undefined && step.value === undefined && step.option === undefined) {
      const e = this.resolve(step.target);
      if (this.optionHit && this.optionHit.entry === e) {
        step = { ...step, do: "select", target: e.ref, value: this.optionHit.option };
        kind = "select";
      }
    }
    switch (kind) {
      case "tap": case "double_tap": case "long_press": case "swipe": case "drag": case "pinch": case "hover": case "move": case "link": case "remove":
        entry = this.resolve(step.target);
        target = this.selectorOf(entry);
        r = this.gesture(entry, kind, step);
        break;
      case "type": case "clear":
        entry = this.resolve(step.target, { prefer: "events" });
        target = this.selectorOf(entry);
        r = this.type(entry, kind === "clear" ? "" : step.text, { clear: kind === "clear" || step.clear !== false, submit: !!step.submit, keystrokes: !!step.keystrokes });
        break;
      case "submit": {
        entry = this.resolve(step.target);
        target = this.selectorOf(entry);
        const f = TEXT_FIELDS.has(entry.type) ? entry : null;
        if (!f) throw new DriveError(`${this.describe(entry)} is not a text field`);
        r = this.submit(f);
        break;
      }
      case "select":
        entry = this.resolve(step.target);
        target = this.selectorOf(entry);
        r = this.choose(entry, step.value !== undefined ? step.value : step.option);
        break;
      case "toggle":
        entry = this.resolve(step.target);
        target = this.selectorOf(entry);
        r = this.toggle(entry, step.on);
        break;
      case "fire": {
        entry = this.resolve(step.target);
        target = this.selectorOf(entry);
        if (!step.event) throw new DriveError("fire needs event (the event name in the node's events)");
        if (!entry.events[step.event]) throw new DriveError(`${this.describe(entry)} has no ${step.event} handler`);
        const why = this.reachable(entry);
        r = why ? this.refuse(entry, why) : { done: this.fire(entry, step.event, this.clientEvent(entry, step.event, step.fields || {}, step.data || {})), fired: [step.event], note: `fired ${step.event} on ${entry.type}` };
        break;
      }
      case "wait":
        r = await this.wait(step);
        break;
      case "env":
        r = await this.setEnv(step);
        break;
      case "mock":
        if (step.clear) this.mocks = [];
        for (const m of [].concat(step.mocks || step.mock || [])) this.addMock(m);
        r = { done: true, note: `${this.mocks.length} mock(s) in place` };
        break;
      case "setState": {
        if (!step.patch || typeof step.patch !== "object") throw new DriveError("setState needs patch: {field: value}");
        const x = this.evaluate(`(function(){var a=(globalThis.__asemanApps||[])[0]; if(!a) return false; a.set(${J(step.patch)}); return true;})()`);
        if (x.error) this.problem("exception", `setting the state threw: ${x.error}`);
        r = { done: x.value === true, note: x.value === true ? "set the app's state (not something a person can do: prefer actions)" : "no App.create app to set" };
        break;
      }
      case "reload":
        await this.reload();
        r = { done: true, note: "opened the app again (a fresh run of the program; the server keeps its data)" };
        break;
      default:
        throw new DriveError(`unknown step ${J(kind)}: tap, double_tap, long_press, type, clear, submit, select, toggle, swipe, drag, pinch, hover, move, link, remove, fire, wait, env, mock, setState, reload — or {expect}`);
    }
    if (r.done !== false && step.settle !== false && kind !== "wait") await this.settle();
    this.history.push(r.note ? clip(r.note, 70) : kind);
    this.lastStep = this.step;
    this.index();
    this.validateScreen();
    const after = this.outline().map((l) => l.text.trim());
    if (r.done !== false) {
      const rec = { do: kind };
      if (target) rec.target = target;
      for (const k of ["text", "submit", "keystrokes", "value", "option", "on", "direction", "from", "to", "steps", "scale", "rotation", "card", "href", "event", "data", "fields", "ms", "release", "until", "viewport", "theme", "display", "patch", "mocks", "mock", "clear", "settle"]) {
        if (step[k] !== undefined) rec[k] = k === "to" && kind === "drag" && !(typeof step.to === "object" && "x" in step.to) ? this.portableTarget(step.to) : step[k];
      }
      if (kind === "type" && step.clear === false) rec.clear = false;
      if (kind === "mock" && step.mocks === undefined && step.mock === undefined && !step.clear) delete rec.mocks;
      this.record(rec);
    }
    return this.report(kind, r, before, after);
  }

  record(step) {
    this.steps.push(step);
  }

  portableTarget(t) {
    try {
      return this.selectorOf(this.resolve(t, { prefer: "any" }));
    } catch {
      return t;
    }
  }

  portableExpect(x) {
    const out = { ...x };
    if (x.target !== undefined) {
      try {
        const hits = this.resolve(x.target, { many: true });
        if (hits.length === 1) out.target = this.selectorOf(hits[0]);
        else if (typeof x.target === "string" && /^e\d+$/.test(x.target)) out.target = this.selectorOf(hits[0]);
      } catch {
        // A target that is not there (expecting absence): keep it portable.
        if (typeof x.target === "string" && /^e\d+$/.test(x.target)) {
          const k = [...this.refs.entries()].find(([, r]) => r === x.target);
          if (k) out.target = k[0].startsWith("k:") ? { key: k[0].slice(2).replace(/#\d+$/, "") } : { type: k[0].split("|")[0], text: k[0].split("|")[1].replace(/#\d+$/, "") };
        }
      }
    }
    return out;
  }

  report(kind, r, before, after) {
    const out = [];
    out.push(`${r.done === false ? "✗" : "✓"} ${r.note || kind}`);
    const reqs = this.step.requests;
    if (reqs.length) out.push(`requests: ${reqs.map((q) => `${q.what} → ${q.status}${q.mocked ? " (mock)" : ""}`).join(" · ")}`);
    const changes = diffLines(before, after);
    if (!changes.length) out.push(r.done === false ? "the screen did not change" : "screen: no visible change");
    else if (changes.length > 40) out.push(`the screen changed (${changes.length} lines): the new screen is\n${this.snapshotText()}`);
    else out.push(`screen changes:\n${changes.join("\n")}`);
    if (this.held.length) out.push(`held requests: ${this.held.map((h) => h.req.target === "app" ? `${h.req.method || "GET"} /${h.req.path}` : h.req.op).join(", ")} (elpian_wait with release: true lets them through)`);
    const probs = this.step.problems;
    out.push(probs.length ? `PROBLEMS:\n${probs.map((p) => `  [${p.kind}] ${p.message}`).join("\n")}` : "problems: none");
    return { ok: r.done !== false && !probs.some((p) => FAILING.has(p.kind)), done: r.done !== false, text: out.join("\n"), problems: probs, requests: reqs };
  }

  // The latest render against the UI DSL schema: errors (and what breaks
  // touch or phones) are problems, each reported once.
  validateScreen() {
    if (!this.tree || this.opts.validate === false) return;
    let issues;
    try {
      issues = validateTree(this.tree, { mode: this.env.display === "compact" ? "widget" : "app", theme: this.env.theme, viewport: this.env.viewport, design: false }).issues;
    } catch (e) {
      this.problem("render", `the validator could not read the render: ${e.message}`);
      return;
    }
    for (const i of issues) {
      if (!((i.severity === "error" && i.code !== "widget-events") || BLOCKING.has(i.code))) continue;
      if (["type-unknown", "type-missing"].includes(i.code)) continue;
      const id = `${i.code}|${i.path}|${i.message}`;
      if (this.issueSeen.has(id)) continue;
      this.issueSeen.add(id);
      this.problem("render", `${i.at || i.path}: ${i.message}${i.fix ? ` Fix: ${i.fix}` : ""} [${i.code}]`);
    }
    const walk = (n) => {
      if (!n || typeof n !== "object") return;
      if (n.type && !KNOWN.has(n.type)) this.problem("render", `node type "${n.type}" is not drawn by the Elpian engine (see ELPIAN.md / nodes.json)`);
      (Array.isArray(n.children) ? n.children : []).forEach(walk);
    };
    walk(this.tree);
  }

  // ── waiting ──

  async wait({ ms, release, until, timeoutMs } = {}) {
    const notes = [];
    if (release) {
      const n = await this.release(release === true ? null : release);
      notes.push(`let ${n} held request(s) through`);
    }
    await this.settle();
    if (ms) {
      await this.advance(ms);
      notes.push(`${ms} ms passed`);
    }
    if (until) {
      const limit = this.clock + num(timeoutMs, 120000);
      let r = await this.expect(until, { quiet: true });
      while (!r.ok && this.clock < limit) {
        const next = this.timers.map((t) => t.due).sort((a, b) => a - b)[0];
        if (next === undefined || next > limit) break;
        await this.advance(next - this.clock);
        r = await this.expect(until, { quiet: true });
      }
      if (!r.ok) {
        this.index();
        return { done: false, note: `waited, but ${r.text.replace(/^✗ /, "")}` };
      }
      notes.push("the expected screen arrived");
    }
    return { done: true, note: notes.join("; ") || "settled every pending request" };
  }

  async setEnv({ viewport, theme, display, widgetSize } = {}) {
    if (viewport) this.env.viewport = viewportOf(viewport);
    if (theme) {
      if (!THEMES[theme]) throw new DriveError("theme: light or dark");
      this.env.theme = THEMES[theme];
    }
    if (display) {
      const d = display === "widget" ? "compact" : display;
      if (!["full", "compact", "sheet"].includes(d)) throw new DriveError("display: full, widget (compact) or sheet");
      this.env.display = d;
      if (d === "compact") this.env.widget = { size: widgetSize || "medium", shape: "card" };
      else delete this.env.widget;
    }
    const r = this.evaluate(`typeof __asemanEnv === "function" && __asemanEnv(${J(J(typed(this.env)))})`, "env.js");
    if (r.error) this.problem("exception", `the app threw when the screen changed: ${r.error}`);
    const v = this.env.viewport;
    return { done: !r.error, note: `the screen is now ${v.width}×${v.height} (${v.sizeClass}), ${this.env.theme.mode}${this.env.display === "compact" ? ", as the phone widget" : ""}` };
  }

  // ── assertions ──

  // Checks the screen, the state and the network. expect: {text, noText,
  // target + exists/count/value/on/selected/disabled/label/props, state,
  // request, problems, errorBanner}.
  async expect(x, { quiet = false } = {}) {
    if (!x || typeof x !== "object") throw new DriveError("expect is an object: {text}, {target, value}, {state}, {request}, …");
    const results = [];
    const check = (ok, msg) => results.push({ ok: !!ok, msg });
    this.index();
    const screen = norm(this.snapshotText());
    for (const t of [].concat(x.text ?? [])) check(screen.includes(norm(t)), `the screen shows ${J(t)}`);
    for (const t of [].concat(x.noText ?? [])) check(!screen.includes(norm(t)), `the screen does not show ${J(t)}`);
    if (x.target !== undefined) {
      let hits = [];
      try {
        hits = this.resolve(x.target, { many: true });
      } catch (e) {
        if (!(e instanceof DriveError)) throw e;
      }
      const want = x.exists === undefined ? true : !!x.exists;
      if (x.count !== undefined) check(hits.length === num(x.count, -1), `${J(x.target)} appears ${x.count} time(s) (found ${hits.length})`);
      else check(want ? hits.length > 0 : hits.length === 0, `${J(x.target)} is ${want ? "" : "not "}on the screen`);
      const e = hits[0];
      if (e && want) {
        if (hits.length > 1 && x.count === undefined && (x.value !== undefined || x.on !== undefined || x.label !== undefined || x.props)) {
          check(false, `${J(x.target)} matches ${hits.length} controls: make the target unique (ref, key, nth)`);
        }
        const p = e.props;
        if (x.value !== undefined) {
          const v = TEXT_FIELDS.has(e.type) ? e.text : p.value !== undefined ? p.value : p.selected;
          check(J(v) === J(x.value) || str(v) === str(x.value), `${this.nameOf(e)} has value ${J(x.value)} (it has ${J(v)})`);
        }
        if (x.on !== undefined) {
          const v = e.type === "Chip" ? p.selected === true : e.type === "Expandable" ? (this.ui.expanded.has(e.uiKey) ? this.ui.expanded.get(e.uiKey) : !!p.expanded) : p.value === true || p.checked === true;
          check(v === !!x.on, `${this.nameOf(e)} is ${x.on ? "on" : "off"}`);
        }
        if (x.selected !== undefined) {
          let v;
          if (e.type === "NavigationBar") v = itemsOf(p.items || p.destinations)[num(p.selected ?? p.value, 0)]?.label;
          else if (e.type === "Tabs") v = itemsOf(p.tabs || p.items)[this.ui.tabs.has(e.uiKey) ? this.ui.tabs.get(e.uiKey) : num(p.selected, 0)]?.label;
          else if (e.type === "SegmentedButton") {
            const sel = [].concat(p.selected ?? p.value).map(str);
            v = itemsOf(p.segments || p.items).filter((s) => sel.includes(str(s.value))).map((s) => s.label).join(", ");
          } else v = p.selected;
          check(typeof x.selected === "boolean" ? !!v === x.selected : norm(str(v)) === norm(str(x.selected)) || str(p.selected) === str(x.selected),
            `${this.nameOf(e)} has ${J(x.selected)} selected (it has ${J(v)})`);
        }
        if (x.disabled !== undefined) check(e.disabled === !!x.disabled, `${this.nameOf(e)} is ${x.disabled ? "disabled" : "enabled"}`);
        if (x.enabled !== undefined) check(e.disabled === !x.enabled, `${this.nameOf(e)} is ${x.enabled ? "enabled" : "disabled"}`);
        if (x.label !== undefined) check(norm(e.label || e.deep) === norm(x.label) || norm(e.deep).includes(norm(x.label)), `${e.type} shows ${J(x.label)} (it shows ${J(e.label || e.deep)})`);
        if (x.props) for (const [k, v] of Object.entries(x.props)) check(subset(v, p[k]), `${this.nameOf(e)} has ${k} = ${J(v)} (it has ${J(p[k])})`);
        if (x.rows !== undefined) {
          const rows = p.data || p.items || p.rows || [];
          check(Array.isArray(rows) && rows.length === num(x.rows, -1), `${e.type} has ${x.rows} rows (it has ${Array.isArray(rows) ? rows.length : 0})`);
        }
      }
    }
    if (x.state) {
      const st = this.state();
      for (const [k, v] of Object.entries(x.state)) {
        const got = getPath(st, k);
        check(subset(v, got), `state.${k} is ${J(v)} (it is ${J(got)})`);
      }
    }
    for (const q of [].concat(x.request ?? [])) {
      const pool = q.since === "all" ? this.network : this.lastRequests();
      const match = pool.filter((n) => (!q.method || String(q.method).toUpperCase() === String(n.method).toUpperCase()) &&
        (q.path === undefined || (n.target === "app" && pathMatches(q.path, n.path))) && (!q.op || n.op === q.op) &&
        (q.status === undefined || num(n.code) === num(q.status)) && (q.body === undefined || subset(q.body, n.body)));
      const what = `${q.method || ""} ${q.path !== undefined ? "/" + String(q.path).replace(/^\//, "") : q.op || ""}`.trim();
      if (q.count !== undefined) check(match.length === num(q.count), `${q.since === "all" ? "the session" : "the last action"} made ${q.count} request(s) ${what} (made ${match.length})`);
      else if (q.none) check(match.length === 0, `${q.since === "all" ? "the session" : "the last action"} made no request ${what}`);
      else check(match.length > 0, `${q.since === "all" ? "the session" : "the last action"} made a request ${what}${q.status !== undefined ? ` answered ${q.status}` : ""}${q.body !== undefined ? ` with body ${J(q.body)}` : ""}`);
    }
    if (x.errorBanner !== undefined) {
      const banner = (this.entries || []).find((e) => e.type === "Callout" && /something went wrong/i.test(e.label));
      const shown = !!banner;
      if (x.errorBanner === false) check(!shown, "no error banner is shown");
      else {
        check(shown && (x.errorBanner === true || norm(`${banner.deep} ${str(banner.props.text)}`).includes(norm(x.errorBanner))), `an error banner${x.errorBanner === true ? "" : ` with ${J(x.errorBanner)}`} is shown${banner ? ` (it says ${J(clip(str(banner.props.text), 80))})` : " (none is)"}`);
        if (shown) for (const p of this.problems) if (p.kind === "app-error") p.expected = true;
      }
    }
    if (x.noProblems) {
      const open = this.openProblems();
      check(open.length === 0, `no problems so far${open.length ? ` (${open.length}: ${open.map((p) => p.message).slice(0, 3).join("; ")})` : ""}`);
    }
    if (x.widget !== undefined) {
      check(!!this.hint && this.hint.view === "self", "the app shows its own phone widget");
    }
    if (!results.length) throw new DriveError("expect checked nothing: give text, noText, target (+ value, on, selected, count…), state, request, errorBanner or noProblems");
    const failed = results.filter((r) => !r.ok);
    const text = failed.length
      ? `✗ expectation failed:\n${failed.map((r) => `  ✗ ${r.msg}`).join("\n")}${results.length > failed.length ? `\n${results.filter((r) => r.ok).map((r) => `  ✓ ${r.msg}`).join("\n")}` : ""}`
      : `✓ ${results.map((r) => r.msg).join("; ")}`;
    return { ok: !failed.length, text: quiet || failed.length === 0 ? text : `${text}\n\nThe screen now:\n${this.snapshotText()}`, results };
  }

  lastRequests() {
    return this.lastStep ? this.lastStep.requests : [];
  }

  state() {
    const r = this.evaluate("JSON.stringify((globalThis.__asemanApps||[])[0] ? globalThis.__asemanApps[0].state : null)");
    return r.error ? null : tryJSON(r.value);
  }

  openProblems() {
    return this.problems.filter((p) => FAILING.has(p.kind) || (p.kind === "app-error" && !p.expected));
  }

  // ── coverage ──

  coverKey(e) {
    return `${e.type}|${e.key !== null ? e.key.replace(/[0-9a-f]{8,}|\d+/gi, "#") : norm(e.label || e.deep || "").slice(0, 40)}`;
  }

  noteCoverage() {
    for (const e of this.entries) {
      if (!e.hasEvents || e.blocked) continue;
      const k = this.coverKey(e);
      let c = this.coverage.seen.get(k);
      if (!c) {
        c = { type: e.type, label: clip(e.label || e.deep || e.key || this.optionsOf(e).map((o) => o.label).join(" | "), 50), events: new Set(), where: this.history.slice(-3).join(" → ") || "the first screen", disabledOnly: true };
        this.coverage.seen.set(k, c);
      }
      for (const ev of Object.keys(e.events)) if (!WRAPPER_ONLY.has(ev)) c.events.add(ev);
      if (!e.disabled) c.disabledOnly = false;
    }
  }

  cover(e, event) {
    this.coverage.fired.add(`${this.coverKey(e)}::${event}`);
  }

  coverageReport() {
    const untested = [];
    let total = 0;
    let done = 0;
    for (const [k, c] of this.coverage.seen) {
      const missing = [...c.events].filter((ev) => !this.coverage.fired.has(`${k}::${ev}`));
      total += c.events.size;
      done += c.events.size - missing.length;
      if (missing.length) untested.push({ control: c.label ? `${c.type} ${J(c.label)}` : c.type, events: missing, where: c.where, disabledOnly: c.disabledOnly });
    }
    const dead = this.problems.filter((p) => p.kind === "dead-control").map((p) => p.message);
    return { total, done, untested, dead };
  }

  coverageText() {
    const c = this.coverageReport();
    const lines = [`coverage: ${c.done} of ${c.total} control events used (${c.total ? Math.round((c.done / c.total) * 100) : 100}%)`];
    if (c.untested.length) {
      lines.push("not used yet:");
      for (const u of c.untested) lines.push(`  ${u.control}: ${u.events.join(", ")} — seen after: ${u.where}${u.disabledOnly ? " (only seen disabled)" : ""}`);
    } else lines.push("every control seen so far has been used.");
    if (c.dead.length) lines.push(`dead controls:\n${c.dead.map((d) => `  ${d}`).join("\n")}`);
    return lines.join("\n");
  }

  // The steps so far as a scenario that replays them.
  scenario(name, description) {
    const v = this.env.viewport;
    const sc = { name: name || "scenario", description: description || undefined };
    const first = this.opts.viewport || "phone";
    sc.viewport = typeof first === "string" ? first : { width: v.width, height: v.height };
    if ((this.opts.theme || "light") !== "light") sc.theme = this.opts.theme;
    if (this.opts.display && this.opts.display !== "full") sc.display = this.opts.display;
    const mocks = (this.opts.mocks || []).map(({ used, ...m }) => m);
    if (mocks.length) sc.mocks = mocks;
    sc.steps = this.steps;
    return sc;
  }
}

const FAILING = new Set(["exception", "server", "network", "render", "host"]);
const WRAPPER_ONLY = new Set(["pointerenter", "pointerexit", "pointerhover", "focus", "blur", "tapcancel", "pointercancel", "dragcancel", "resize", "dismissupdate", "dragleave", "dragover"]);

// ── helpers ──────────────────────────────────────────────────────────────

function isAncestor(a, b) {
  for (let x = b.parent; x; x = x.parent) if (x === a) return true;
  return false;
}

function tryJSON(t) {
  if (typeof t !== "string") return t ?? null;
  try {
    return JSON.parse(t);
  } catch {
    return null;
  }
}

// Text matching for mocks: a substring (any case), or "re:<regex>".
function textMatches(pattern, hay) {
  const s = String(pattern);
  if (s.startsWith("re:")) {
    try {
      return new RegExp(s.slice(3), "i").test(hay);
    } catch {
      return false;
    }
  }
  return hay.toLowerCase().includes(s.toLowerCase());
}

// A mock or expectation path: "api/tasks", "/api/tasks/*" (* is any run of
// characters), "api/tasks?x=1" (the query is ignored), or "re:<regex>".
export function pathMatches(pattern, actual) {
  const a = String(actual || "").replace(/^\/+/, "").split("?")[0];
  const s = String(pattern);
  if (s.startsWith("re:")) return textMatches(s, a);
  const p = s.replace(/^\/+/, "").split("?")[0];
  if (!p.includes("*")) return a === p;
  const re = new RegExp("^" + p.split("*").map((x) => x.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$");
  return re.test(a);
}

function getPath(obj, p) {
  let v = obj;
  for (const k of String(p).split(".").filter(Boolean)) {
    if (v === null || v === undefined) return undefined;
    v = v[k];
  }
  return v;
}

// want ⊆ got: objects by their keys, arrays item by item, scalars equal
// (numbers and their strings alike).
export function subset(want, got) {
  if (want === null || typeof want !== "object") return want === got || (want !== null && got !== null && got !== undefined && typeof got !== "object" && String(want) === String(got));
  if (Array.isArray(want)) return Array.isArray(got) && want.length === got.length && want.every((w, i) => subset(w, got[i]));
  if (!got || typeof got !== "object") return false;
  return Object.entries(want).every(([k, v]) => subset(v, got[k]));
}

// The lines that went (-) and came (+), in order.
export function diffLines(a, b) {
  const n = a.length;
  const m = b.length;
  if (n * m > 400000) return [...a.map((l) => `- ${l}`), ...b.map((l) => `+ ${l}`)];
  const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const out = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) out.push(`- ${a[i++]}`);
    else out.push(`+ ${b[j++]}`);
  }
  while (i < n) out.push(`- ${a[i++]}`);
  while (j < m) out.push(`+ ${b[j++]}`);
  return out;
}

function jobPort(dir) {
  try {
    const job = JSON.parse(fs.readFileSync(path.join(dir, "JOB.json"), "utf8"));
    return job.port ? Number(job.port) : null;
  } catch {
    return null;
  }
}

async function reachable(url) {
  try {
    await fetch(url, { signal: AbortSignal.timeout(3000) });
    return true;
  } catch {
    return false;
  }
}

export async function startServer(command, cwd, port, { timeoutMs = 30000 } = {}) {
  const child = spawn(command, { cwd, shell: true, detached: true, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, PORT: String(port), HOST: "0.0.0.0" } });
  let output = "";
  child.stdout.on("data", (d) => (output = (output + d).slice(-4000)));
  child.stderr.on("data", (d) => (output = (output + d).slice(-4000)));
  let exited = null;
  child.on("exit", (code) => (exited = code));
  const url = `http://127.0.0.1:${port}`;
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (exited !== null) throw new DriveError(`the server command exited (${exited}) before serving: ${output.slice(-1500)}`);
    if (await reachable(url)) return child;
    await new Promise((r) => setTimeout(r, 250));
  }
  stopServer(child);
  throw new DriveError(`the server did not answer on ${url} within ${timeoutMs / 1000} s: ${output.slice(-1500)}`);
}

export function stopServer(child) {
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    try {
      child.kill("SIGTERM");
    } catch { /* gone */ }
  }
}

// ── scenarios ────────────────────────────────────────────────────────────

// Reads scenarios from files and directories (*.json: a scenario, a list of
// them, or {scenarios: [...]}).
export function loadScenarios(paths) {
  const out = [];
  const files = [];
  for (const p of paths) {
    if (!fs.existsSync(p)) continue;
    if (fs.statSync(p).isDirectory()) {
      for (const f of fs.readdirSync(p).filter((f) => f.endsWith(".json")).sort()) files.push(path.join(p, f));
    } else files.push(p);
  }
  for (const f of files) {
    let v;
    try {
      v = JSON.parse(fs.readFileSync(f, "utf8"));
    } catch (e) {
      out.push({ file: f, error: `not JSON: ${e.message}` });
      continue;
    }
    const list = Array.isArray(v) ? v : Array.isArray(v.scenarios) ? v.scenarios : [v];
    list.forEach((s, i) => out.push({ file: f, scenario: { name: s && s.name ? s.name : `${path.basename(f, ".json")}${list.length > 1 ? ` #${i + 1}` : ""}`, ...s } }));
  }
  return out;
}

// Runs one scenario in a fresh session: every step must do what it says,
// every expectation must hold, and no problem may be left (an error banner
// counts unless a step expected it).
export async function runScenario(scenario, base = {}) {
  if (!scenario || !Array.isArray(scenario.steps) || !scenario.steps.length) return { name: scenario && scenario.name, ok: false, error: "a scenario needs steps: [{do: …} | {expect: …}]" };
  let s;
  const log = [];
  try {
    s = await Session.open({ ...base, viewport: scenario.viewport || base.viewport, theme: scenario.theme || base.theme, display: scenario.display || base.display, mocks: [...(base.mocks || []), ...(scenario.mocks || [])], start: undefined, server: base.server });
    const boot = s.openProblems();
    if (boot.length) return { name: scenario.name, ok: false, failedAt: 0, error: `the app has problems on opening:\n${boot.map((p) => `  [${p.kind}] ${p.message}`).join("\n")}`, log, coverage: s.coverageReport(), session: s };
    for (let i = 0; i < scenario.steps.length; i++) {
      const step = scenario.steps[i];
      let r;
      try {
        r = await s.run(step);
      } catch (e) {
        if (!(e instanceof DriveError)) throw e;
        return { name: scenario.name, ok: false, failedAt: i + 1, step, error: e.message, log, screen: s.snapshotText(), coverage: s.coverageReport(), session: s };
      }
      const failing = (r.problems || []).filter((p) => FAILING.has(p.kind));
      if (!r.ok || failing.length) {
        return { name: scenario.name, ok: false, failedAt: i + 1, step, error: r.text, log, screen: s.snapshotText(), coverage: s.coverageReport(), session: s };
      }
      log.push(`${i + 1}. ${r.text.split("\n")[0]}`);
    }
    const open = s.openProblems();
    if (open.length) {
      return { name: scenario.name, ok: false, failedAt: scenario.steps.length, error: `problems left at the end (expect {errorBanner: …} where an error banner is meant to show):\n${open.map((p) => `  [${p.kind}] ${p.message}${p.after ? ` (after: ${p.after})` : ""}`).join("\n")}`, log, coverage: s.coverageReport(), session: s };
    }
    return { name: scenario.name, ok: true, steps: scenario.steps.length, log, coverage: s.coverageReport(), session: s };
  } finally {
    if (s) await s.close();
  }
}

// Runs scenarios one after another against the same server, and merges
// their coverage.
export async function runScenarios(paths, base = {}) {
  const loaded = loadScenarios(paths);
  const results = [];
  let child = null;
  try {
    if (base.start) {
      const port = base.port || jobPort(path.resolve(base.dir || ".")) || 8787;
      child = await startServer(base.start, path.resolve(base.dir || "."), port);
      base = { ...base, server: `http://127.0.0.1:${port}`, start: undefined };
    }
    const seen = new Map();
    const fired = new Set();
    for (const l of loaded) {
      if (l.error) {
        results.push({ name: path.basename(l.file), file: l.file, ok: false, error: l.error });
        continue;
      }
      const r = await runScenario(l.scenario, base);
      if (r.session) {
        for (const [k, c] of r.session.coverage.seen) {
          const prev = seen.get(k);
          if (!prev) seen.set(k, { ...c, events: new Set(c.events) });
          else for (const ev of c.events) prev.events.add(ev);
        }
        for (const f of r.session.coverage.fired) fired.add(f);
        delete r.session;
      }
      results.push({ file: l.file, ...r });
    }
    const untested = [];
    let total = 0;
    let done = 0;
    for (const [k, c] of seen) {
      const missing = [...c.events].filter((ev) => !fired.has(`${k}::${ev}`));
      total += c.events.size;
      done += c.events.size - missing.length;
      if (missing.length) untested.push({ control: c.label ? `${c.type} ${J(c.label)}` : c.type, events: missing, where: c.where, disabledOnly: c.disabledOnly });
    }
    return { ok: loaded.length > 0 && results.every((r) => r.ok), count: loaded.length, results, coverage: { total, done, untested } };
  } finally {
    if (child) stopServer(child);
  }
}

export function formatRun(run) {
  const out = [];
  if (!run.count) out.push("no scenarios found: write them to elpian/e2e/*.json (elpian_save_scenario saves a session's steps)");
  for (const r of run.results) {
    if (r.ok) out.push(`✓ ${r.name} (${r.steps} steps)`);
    else {
      out.push(`✗ ${r.name}${r.file ? ` (${path.basename(r.file)})` : ""}${r.failedAt ? `, step ${r.failedAt}${r.step ? ` ${J(r.step)}` : ""}` : ""}:`);
      out.push(String(r.error).split("\n").map((l) => `    ${l}`).join("\n"));
      if (r.log && r.log.length) out.push(`  steps before it:\n${r.log.slice(-6).map((l) => `    ${l}`).join("\n")}`);
      if (r.screen && !String(r.error).includes("The screen now:")) out.push(`  the screen at the failure:\n${r.screen.split("\n").map((l) => `    ${l}`).join("\n")}`);
    }
  }
  const c = run.coverage;
  if (c && c.total) {
    out.push(`coverage: ${c.done} of ${c.total} control events used (${Math.round((c.done / c.total) * 100)}%)`);
    if (c.untested.length) out.push(`not used by any scenario:\n${c.untested.map((u) => `  ${u.control}: ${u.events.join(", ")} — seen after: ${u.where}`).join("\n")}`);
  }
  out.push(run.ok ? `elpian e2e: ${run.count} scenario(s) passed` : `elpian e2e: ${run.results.filter((r) => !r.ok).length} of ${run.count} scenario(s) failed`);
  return out.join("\n");
}

// ── CLI ──────────────────────────────────────────────────────────────────

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const valued = new Set(["--bundle", "--server", "--start", "--port", "--apps", "--viewport", "--theme", "--dir"]);
  const opt = (n) => {
    const i = args.indexOf(n);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const free = args.filter((a, i) => !a.startsWith("--") && !valued.has(args[i - 1]));
  const cmd = free.shift() || "run";
  const dir = path.resolve(opt("--dir") || ".");
  const appsFile = opt("--apps");
  const base = {
    dir,
    bundle: opt("--bundle") || "elpian/app.js",
    server: opt("--server"),
    start: opt("--start"),
    port: opt("--port") ? Number(opt("--port")) : undefined,
    apps: appsFile && fs.existsSync(appsFile) ? JSON.parse(fs.readFileSync(appsFile, "utf8")) : undefined,
    viewport: opt("--viewport"),
    theme: opt("--theme"),
  };
  try {
    if (cmd === "run") {
      const run = await runScenarios(free.length ? free : [path.join(dir, "elpian", "e2e")], base);
      if (args.includes("--json")) console.log(J(run, null, 2));
      else console.log(formatRun(run));
      process.exit(run.ok ? 0 : 1);
    } else if (cmd === "snapshot") {
      const s = await Session.open(base);
      console.log([...s.notes, s.snapshotText(), ...s.openProblems().map((p) => `problem [${p.kind}]: ${p.message}`)].join("\n"));
      await s.close();
    } else {
      console.error(`unknown command ${cmd}: run or snapshot`);
      process.exit(2);
    }
  } catch (e) {
    console.error(`elpian drive: ${e.message}`);
    process.exit(1);
  }
}
