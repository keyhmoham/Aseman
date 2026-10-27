#!/usr/bin/env node
// Runs an Elpian App UI program on QuickJS (the engine the Aseman client runs
// it on) against a simulated Aseman host, and reports what would break:
//   - the program throws, or never renders;
//   - a rendered node type the engine does not draw;
//   - an event names a handler that is not a global function, or a handler
//     throws when used (each one is invoked with a sample event);
//   - host APIs that do not exist.
// With --server, the program's requests to its own server (Aseman.fetch) go
// to the running server, so the frontend and backend are checked together.
//
// Every render is validated against the UI DSL schema (validate.mjs): prop
// and style types, parent–child relations, layout constraints, keys. To reach
// the screens people reach, it explores the app's states: from every distinct
// state (snapshotted through the SDK) it fires every handler with realistic
// event data, breadth first, within a budget; each finding names the steps
// that lead to it. While exploring, writes to the app's server are answered
// from what it answered before, so the server is never flooded.
//
// It also runs the program as its phone-board widget (display "compact"): the
// app must declare one, keep it glanceable and fed with live data.
//
//   node check.mjs elpian/app.js [--server http://127.0.0.1:8787] [--apps APPS.json] [--no-widget | --widget-only] [--json]

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { validate as validateTree } from "./validate.mjs";
import { GESTURE_SEQUENCES, PHONE } from "./schema.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const NODES = JSON.parse(fs.readFileSync(path.join(here, "nodes.json"), "utf8"));
const KNOWN = new Set([...NODES.elpian, ...NODES.html, ...NODES.kit]);
const HOST_APIS = new Set(["render", "aseman.env", "aseman.request", "aseman.compact", "aseman.expand", "println", "env.get",
  "setTimeout", "setInterval", "clearTimeout", "clearInterval"]);

export async function loadQuickJS() {
  const candidates = [
    process.env.ASEMAN_QUICKJS_MODULE,
    "/opt/aseman-tool-runtime/node_modules/quickjs-emscripten",
    path.resolve(here, "../../../tool-runtime/node_modules/quickjs-emscripten"),
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      const require = createRequire(path.join(c, "package.json"));
      const entry = require.resolve(c);
      return await import(entry);
    } catch {
      /* next */
    }
  }
  try {
    return await import("quickjs-emscripten");
  } catch {
    throw new Error("QuickJS (quickjs-emscripten) not found: set ASEMAN_QUICKJS_MODULE");
  }
}

export function typed(value) {
  if (value === null || value === undefined) return { type: "null", data: { value: null } };
  if (typeof value === "boolean") return { type: "bool", data: { value } };
  if (typeof value === "number") return { type: Number.isInteger(value) ? "i64" : "f64", data: { value } };
  if (typeof value === "string") return { type: "string", data: { value } };
  if (Array.isArray(value)) return { type: "array", data: { value: value.map(typed) } };
  const out = {};
  for (const [k, v] of Object.entries(value)) out[k] = typed(v);
  return { type: "object", data: { value: out } };
}

export const SAMPLE_ENV = {
  display: "full",
  theme: { mode: "light", accent: "#6750A4", colors: {
    primary: "#6750A4", onPrimary: "#FFFFFF", primaryContainer: "#EADDFF", onPrimaryContainer: "#21005D",
    secondary: "#625B71", onSecondary: "#FFFFFF", secondaryContainer: "#E8DEF8", onSecondaryContainer: "#1D192B",
    tertiary: "#7D5260", onTertiary: "#FFFFFF", tertiaryContainer: "#FFD8E4", onTertiaryContainer: "#31111D",
    surface: "#FEF7FF", onSurface: "#1D1B20", onSurfaceVariant: "#49454F",
    surfaceContainerLowest: "#FFFFFF", surfaceContainerLow: "#F7F2FA", surfaceContainer: "#F3EDF7", surfaceContainerHigh: "#ECE6F0", surfaceContainerHighest: "#E6E0E9",
    inverseSurface: "#322F35", onInverseSurface: "#F5EFF7", outline: "#79747E", outlineVariant: "#CAC4D0",
    error: "#B3261E", onError: "#FFFFFF", errorContainer: "#F9DEDC", onErrorContainer: "#410E0B",
  } },
  // A small phone: the size fixed screens must fit (validate.mjs checks the
  // renders against the same size).
  viewport: { width: PHONE.width, height: PHONE.height, sizeClass: "compact", orientation: "portrait" },
  user: { id: "u-check", handle: "check" },
  space: "s-check",
  room: "r-check",
  title: "Check",
};

// Nodes that do not belong on a glanceable phone widget.
const NOT_IN_WIDGET = new Set(["DataGrid", "ListView", "GridView", "TextField", "SearchBar", "NavigationBar", "SegmentedButton", "ListGroup", "Scaffold", "AppBar", "Drawer", "textarea", "input", "form", "table"]);
const WIDGET_MAX_NODES = 80;

// check runs the app as people use it (display "full") and, with
// widget: true, as its phone-board widget (display "compact").
export async function check(source, opts = {}) {
  // A web app's widget program is only ever drawn as the widget.
  if (opts.widgetOnly) {
    const widget = await run(source, { ...opts, display: "compact" });
    return { ...widget, errors: widget.errors.map((e) => `widget: ${e}`), warnings: widget.warnings.map((w) => `widget: ${w}`),
      widget: { renders: widget.renders, nodes: widget.nodes, hint: widget.hint, requests: widget.requests } };
  }
  const full = await run(source, { ...opts, display: "full" });
  if (!opts.widget) return full;
  const widget = await run(source, { ...opts, display: "compact" });
  return {
    ok: full.ok && widget.ok,
    errors: [...full.errors, ...widget.errors.map((e) => `widget: ${e}`)],
    warnings: [...full.warnings, ...widget.warnings.map((w) => `widget: ${w}`)],
    renders: full.renders,
    handlers: full.handlers,
    widget: { renders: widget.renders, nodes: widget.nodes, hint: widget.hint, requests: widget.requests },
  };
}

// The value a node's `change` event carries, as the client sends it.
function sampleChange(node) {
  const p = (node && node.props) || {};
  switch (node && node.type) {
    case "NavigationBar": return Math.min(1, ((p.items || p.destinations || []).length || 1) - 1);
    case "SegmentedButton": {
      const segs = (p.segments || p.items || []).map((x) => (x && typeof x === "object" ? (x.value !== undefined ? x.value : x.label) : x));
      const v = segs.length > 1 ? String(segs[1]) : segs.length ? String(segs[0]) : "";
      return p.multi ? [v] : v;
    }
    case "Slider": return typeof p.max === "number" ? p.max : 1;
    case "Rating": return 3;
    case "Radio": return p.value;
    case "Chip": return !p.selected;
    default: return true;
  }
}

// Messages, each kept once: the same finding reached by different steps
// keeps the first (shortest) steps.
function dedupeSteps(list) {
  const out = new Map();
  for (const m of list) {
    const base = m.replace(/ \(reached after: .*\)$/s, "").split("\n")[0];
    if (!out.has(base)) out.set(base, m);
  }
  return [...out.values()];
}

// The steps that led somewhere, for a message.
const stepsText = (path) => (path && path.length ? ` (reached after: ${path.join(" → ")})` : "");

// Folds the validator's findings on every distinct render into the check's
// errors and warnings, each with the steps that first reached it (the checks
// this file makes itself are left to it).
const OWN = new Set(["type-unknown", "type-missing", "widget-node", "widget-size", "event-handler"]);
// Validator warnings that mean the app does not work for the person using it
// — touches that never arrive, a screen cut off on phones — fail the check
// (the validator keeps them warnings: its errors are what makes Flutter
// throw). Not row overflow: it estimates text widths.
export const BLOCKING = new Set(["gesture-in-scroll", "gesture-in-control", "gesture-no-area", "stack-overlay-blocks",
  "layout-wider-than-screen", "layout-taller-than-screen", "layout-screen-overflow"]);
function addValidation(renders, paths, compact, errors, warnings, opts, viewports = []) {
  if (opts.validate === false || !renders.length) return;
  const seenTrees = new Set();
  const seenIssues = new Map();
  for (let r = 0; r < renders.length && seenTrees.size < 800; r++) {
    const key = JSON.stringify(renders[r]) + JSON.stringify(viewports[r] || null);
    if (seenTrees.has(key)) continue;
    seenTrees.add(key);
    for (const i of validateTree(renders[r], { mode: compact ? "widget" : "app", theme: SAMPLE_ENV.theme, viewport: viewports[r] }).issues) {
      const id = `${i.code}|${i.path}|${i.message}`;
      if (!seenIssues.has(id)) seenIssues.set(id, { ...i, steps: (paths && paths[r]) || [] });
    }
  }
  let notes = 0;
  for (const i of seenIssues.values()) {
    if (OWN.has(i.code)) continue;
    const line = `${i.at || i.path}: ${i.message}${i.fix ? ` Fix: ${i.fix}` : ""} [${i.code}]${stepsText(i.steps)}`;
    if ((i.severity === "error" && i.code !== "widget-events") || BLOCKING.has(i.code)) errors.push(line);
    else if (i.severity === "info") notes++;
    else warnings.push(line);
  }
  if (notes) warnings.push(`${notes} design note(s) on the view trees: run node vendor/aseman-elpian/validate.mjs --program <bundle> to see them`);
}

async function run(source, { server = "", apps = null, maxHandlers = 60, millis = 10000, display = "full", validate: doValidate, collect = false,
  explore = true, exploreMs = 8000, maxTransitions = 2500 } = {}) {
  const vopts = { validate: doValidate };
  const compact = display === "compact";
  const env = { ...SAMPLE_ENV, display, widget: compact ? { size: "medium", shape: "card" } : undefined };
  const intervals = [];
  let hint = null;
  let requests = 0;
  const errors = [];
  const warnings = [];
  const renders = [];
  // The steps (handler labels) that led to each render, and the viewport it
  // was drawn for.
  const renderPaths = [];
  const renderViewports = [];
  let currentPath = [];
  // While exploring, writes to the app's server are answered from cache.
  let exploring = false;
  let synthetic = false;
  const responses = new Map();
  const queue = [];
  const unknownApis = new Set();
  // What is running, to name it when the SDK reports an error it caught.
  let running = "the program";
  const QuickJS = await loadQuickJS();
  const module = await QuickJS.getQuickJS();
  const runtime = module.newRuntime();
  runtime.setMemoryLimit(128 << 20);
  runtime.setMaxStackSize(1 << 20);
  let deadline = Infinity;
  runtime.setInterruptHandler(() => Date.now() > deadline);
  const vm = runtime.newContext();

  const askHost = vm.newFunction("askHost", (apiH, payloadH) => {
    const api = vm.getString(apiH);
    let payload = payloadH === undefined ? "" : vm.dump(payloadH);
    let parsed = payload;
    if (typeof payload === "string") {
      try {
        parsed = JSON.parse(payload);
      } catch {
        parsed = payload;
      }
    }
    let reply = true;
    switch (api) {
      case "render":
        renders.push(parsed);
        renderPaths.push(currentPath.slice());
        renderViewports.push(env.viewport);
        break;
      case "aseman.env":
      case "env.get":
        reply = env;
        break;
      case "aseman.compact":
        hint = parsed;
        break;
      case "setInterval":
        if (parsed && (parsed.handler || parsed.fn)) intervals.push(parsed.handler || parsed.fn);
        reply = intervals.length;
        break;
      case "println":
        if (typeof parsed === "string" && parsed.startsWith("app error:") && !synthetic) errors.push(`${running}: ${parsed.slice(11).trim()}${stepsText(currentPath)}`);
        if (typeof parsed === "string" && parsed.startsWith("view error:")) {
          // The error and where in the program's view it happened.
          const [first, ...frames] = parsed.slice(12).trim().split("\n");
          const at = frames.map((f) => f.trim()).find((f) => f.startsWith("at ")) || "";
          errors.push(`the view threw: ${first}${at ? ` (${at})` : ""}${stepsText(currentPath)}`);
        }
        break;
      case "aseman.request":
        if (!parsed || !parsed.id || !(parsed.op || parsed.path !== undefined)) errors.push(`aseman.request without id and op/path: ${JSON.stringify(parsed)}`);
        else {
          queue.push(parsed);
          requests++;
        }
        reply = { accepted: true };
        break;
      default:
        if (!HOST_APIS.has(api)) unknownApis.add(api);
    }
    return vm.newString(JSON.stringify(typed(reply)));
  });
  vm.setProp(vm.global, "askHost", askHost);
  askHost.dispose();

  const evaluate = (code, name) => {
    deadline = Date.now() + millis;
    try {
      const result = vm.evalCode(code, name);
      if (result.error) {
        const err = vm.dump(result.error);
        result.error.dispose();
        return { error: typeof err === "object" ? `${err.name || "Error"}: ${err.message}${err.stack ? "\n" + String(err.stack).split("\n").slice(0, 4).join("\n") : ""}` : String(err) };
      }
      result.value.dispose();
      return {};
    } finally {
      deadline = Infinity;
    }
  };

  const answer = async (req) => {
    if (req.target === "app") {
      if (!server) return { ok: true, status: 200, data: { status: 200, ok: true, json: {}, text: "{}", contentType: "application/json" } };
      const cacheKey = `${req.method || "GET"} ${req.path}`;
      if (exploring && (responses.has(cacheKey) || (req.method && req.method !== "GET"))) {
        if (responses.has(cacheKey)) return responses.get(cacheKey);
        synthetic = true;
        return { ok: true, status: 200, data: { status: 200, ok: true, json: {}, text: "{}", contentType: "application/json" } };
      }
      try {
        const url = new URL(String(req.path || ""), server.replace(/\/?$/, "/"));
        for (const [k, v] of Object.entries(req.query || {})) url.searchParams.set(k, typeof v === "string" ? v : JSON.stringify(v));
        const res = await fetch(url, {
          method: req.method || "GET",
          headers: { "Content-Type": "application/json", ...(req.headers || {}) },
          body: req.body !== undefined && req.method !== "GET" ? (typeof req.body === "string" ? req.body : JSON.stringify(req.body)) : undefined,
        });
        const text = await res.text();
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          json = null;
        }
        if (res.status >= 500) errors.push(`the app's server answered ${req.method || "GET"} /${req.path} with HTTP ${res.status}: ${text.slice(0, 300)}${stepsText(currentPath)}`);
        const out = { ok: true, status: 200, data: { status: res.status, ok: res.ok, json, text, contentType: res.headers.get("content-type") || "" } };
        responses.set(cacheKey, out);
        return out;
      } catch (e) {
        errors.push(`the app's server did not answer ${req.method || "GET"} /${req.path}: ${e.message}`);
        return { ok: false, status: 0, error: e.message };
      }
    }
    const agents = (apps && apps.agents) || [{ id: "a1", name: "assistant", description: "sample agent" }];
    const tools = (apps && apps.apps) || [];
    switch (req.op) {
      case "context":
        return { ok: true, status: 200, data: { space: SAMPLE_ENV.space, user: SAMPLE_ENV.user, room: SAMPLE_ENV.room } };
      case "agents":
        return { ok: true, status: 200, data: { agents } };
      case "tools":
        return { ok: true, status: 200, data: { tools: tools.map((t) => ({ name: t.name, id: t.bot_id, microtools: t.microtools || [] })) } };
      case "microtools":
        return { ok: true, status: 200, data: { microtools: [] } };
      case "call":
        return { ok: true, status: 200, data: { result: "Sample result of " + (req.body && req.body.microtool) } };
      case "ask": {
        const prompt = String((req.body && req.body.prompt) || "");
        const reply = /json/i.test(prompt)
          ? "```json\n{\"ok\": true, \"items\": []}\n```"
          : "```openui\n{\"c\":\"Card\",\"p\":{\"title\":\"Sample\"},\"children\":[{\"c\":\"Markdown\",\"p\":{\"content\":\"**Sample** answer\"}}]}\n```";
        return { ok: true, status: 200, data: { agent: req.body && req.body.agent, reply } };
      }
      case "show":
        return { ok: true, status: 200, data: { ok: true } };
      default:
        errors.push(`unknown Aseman op "${req.op}" (use context, tools, microtools, call, agents, ask, show)`);
        return { ok: false, status: 404, error: "no such op" };
    }
  };

  const drain = async () => {
    for (let round = 0; round < 50 && queue.length; round++) {
      const batch = queue.splice(0);
      for (const req of batch) {
        const result = { id: req.id, ...(await answer(req)) };
        running = `after the host answered ${req.op || "/" + req.path}`;
        const r = evaluate(`__asemanSettle(${JSON.stringify(JSON.stringify(result))})`, "settle.js");
        if (r.error && !synthetic) errors.push(`after the host answered ${req.op || "/" + req.path}: ${r.error}${stepsText(currentPath)}`);
        synthetic = false;
      }
    }
  };

  const walk = (node, at, found) => {
    if (node === null || node === undefined) return;
    if (typeof node !== "object" || Array.isArray(node)) {
      errors.push(`${at}: a node must be an object {type, props, children}, got ${JSON.stringify(node).slice(0, 80)}`);
      return;
    }
    const type = node.type;
    if (!type) errors.push(`${at}: a node without type`);
    else if (!KNOWN.has(type)) errors.push(`${at}: node type "${type}" is not drawn by the Elpian engine (see ELPIAN.md / nodes.json)`);
    for (const [ev, name] of Object.entries(node.events || {})) found.push({ at: `${at}.${type}`, event: ev, name, node });
    (node.children || []).forEach((c, i) => walk(c, `${at}.${type || "?"}[${i}]`, found));
  };

  const latest = () => renders[renders.length - 1];

  const boot = evaluate(source, "app.js");
  if (boot.error) errors.push(`the program failed while starting: ${boot.error}`);
  await drain();
  if (!renders.length) errors.push("the program never rendered (call App.create({view}) or askHost('render', …))");

  if (compact) {
    // The widget refreshes its live data: run each refresh once.
    for (const name of intervals.slice(0, 5)) {
      running = `the widget's refresh (${name})`;
      const r = evaluate(`globalThis[${JSON.stringify(name)}]()`, "refresh.js");
      if (r.error) errors.push(`its refresh threw: ${r.error}`);
      await drain();
    }
    const tree = latest();
    const nodes = [];
    const count = (n) => {
      if (!n || typeof n !== "object") return;
      nodes.push(n);
      (n.children || []).forEach(count);
    };
    count(tree);
    const report = { ok: false, errors, warnings, renders: renders.length, handlers: 0, nodes: nodes.length, hint, requests };
    if (!hint || hint.view !== "self") {
      errors.push("the app has no phone widget: give App.create a widget {view(state, app), refresh(app), size, shape} (ELPIAN.md, The phone widget)");
    } else {
      if (hint.size && !["small", "medium", "large"].includes(hint.size)) errors.push(`widget size "${hint.size}" is not small, medium or large`);
      if (hint.shape && !["card", "squircle", "pill", "circle", "leaf"].includes(hint.shape)) errors.push(`widget shape "${hint.shape}" is not card, squircle, pill, circle or leaf`);
      if (nodes.length > WIDGET_MAX_NODES) errors.push(`the widget draws ${nodes.length} nodes: keep it a glanceable summary (at most ${WIDGET_MAX_NODES})`);
      const heavy = [...new Set(nodes.map((n) => n.type).filter((t) => NOT_IN_WIDGET.has(t)))];
      if (heavy.length) errors.push(`the widget uses ${heavy.join(", ")}: a widget is a glance (stats, a chart, a few lines), not a screen; taps open the full app`);
      if (requests === 0 && !(hint.static === true)) errors.push("the widget shows no live data: load it in init or widget.refresh (Aseman.fetch / call / ask), or declare widget.static: true when the app truly has none");
      if (!intervals.length && !(hint.static === true)) warnings.push("the widget never refreshes: give it widget.refresh (or init) to run on a timer");
      if (nodes.some((n) => n.events && Object.keys(n.events).length)) warnings.push("widget nodes have events: taps on a widget open the full app instead");
    }
    const walked = [];
    walk(tree, "widget", walked);
    vm.dispose();
    runtime.dispose();
    addValidation(renders.slice(-6), renderPaths.slice(-6), true, errors, warnings, vopts, renderViewports.slice(-6));
    report.ok = errors.length === 0;
    report.errors = [...new Set(errors)];
    report.warnings = [...new Set(warnings)];
    if (collect) Object.assign(report, { trees: renders, paths: renderPaths, viewports: renderViewports, theme: SAMPLE_ENV.theme });
    return report;
  }

  // A handler's label for the steps: what the person sees on the control.
  const labelOf = (h, value) => {
    const p = (h.node && h.node.props) || {};
    const what = p.text ?? p.label ?? p.title ?? p.tooltip ?? p.icon ?? h.node.key ?? h.name;
    return `${h.event} "${String(what).slice(0, 24)}"${value !== undefined && value !== null && h.event !== "tap" ? ` = ${JSON.stringify(value)}` : ""}`;
  };
  // An event as the client sends it (ElpianVmWidget, elpianEventJson): type,
  // target and phase, `data`, the fields of its kind, and `data`'s fields at
  // the top level too.
  const clientEvent = (h, fields = {}, data = {}) => {
    const id = (h.node && typeof h.node.key === "string" && h.node.key) || "element_1";
    return { ...data, type: h.event, eventType: h.event, target: id, currentTarget: id, timestamp: "2026-01-01T09:00:00.000", phase: "atTarget", data, ...fields };
  };
  const pt = (x, y) => ({ x, y });
  // A finger on the node: where (on it and on the screen) and how far it
  // moved since the last event.
  const pointerAt = (h, x, y, dx = 0, dy = 0, data = {}) => clientEvent(h, {
    position: pt(16 + x, 120 + y), localPosition: pt(x, y), delta: pt(dx, dy), buttons: 1, pressure: 1, distance: 0, pointerId: 1,
  }, data);
  const gestureAt = (h, scale, rotation, data = {}) => clientEvent(h, { velocity: pt(0, 0), scale, rotation, focalPoint: pt(180, 260) }, { localFocalPoint: pt(164, 140), ...data });
  // The event data the client sends, several realistic values per event.
  const samplesFor = (h) => {
    switch (h.event) {
      case "input":
        return ["sample", "", "0", "-1", "12.5", "abc"].map((value) => clientEvent(h, { value, inputType: "text" }));
      case "change": {
        const v = sampleChange(h.node);
        const alt = typeof v === "boolean" ? !v : h.node && h.node.type === "Slider" ? (h.node.props || {}).min ?? 0 : undefined;
        return [v, ...(alt !== undefined ? [alt] : [])].map((value) => clientEvent(h, {}, { value }));
      }
      case "select":
        return [clientEvent(h, {}, { index: 0, row: {} })];
      case "resize":
        return [clientEvent(h, {}, { width: PHONE.width - 32, height: 420 }), clientEvent(h, {}, { width: 1200, height: 700 })];
      case "swipeleft": case "swiperight": case "swipeup": case "swipedown": {
        const v = { swipeleft: pt(-900, 0), swiperight: pt(900, 0), swipeup: pt(0, -900), swipedown: pt(0, 900) }[h.event];
        return [clientEvent(h, { velocity: v, scale: 1, rotation: 0, focalPoint: pt(0, 0) })];
      }
      case "tapdown": case "tapup": case "secondarytap": case "contextmenu": case "pointerenter": case "pointerexit": case "pointerhover":
        return [pointerAt(h, 24, 32)];
      default:
        return [clientEvent(h)];
    }
  };
  // One step of a gesture sequence: the i-th event of n.
  const sequenceStep = (h, i, n) => {
    const x = 20 + i * 18, y = 30 + i * 12;
    if (/^(scale|pinch|rotate)/.test(h.event)) {
      const end = /end$/.test(h.event);
      return end ? clientEvent(h, { velocity: pt(0, 0), scale: 1, rotation: 0, focalPoint: pt(0, 0) }) : gestureAt(h, 1 + i * 0.15, i * 0.05);
    }
    if (h.event === "dragend") return pointerAt(h, x, y, 0, 0, { velocity: pt(120, 80) });
    return pointerAt(h, x, y, i ? 18 : 0, i ? 12 : 0);
  };
  // What the person does, as handler calls: one call per sample, but the
  // events of a gesture fire as the sequence the finger makes (start, two
  // moves, end) — a move handler is never called without its start.
  const actionsOf = (hs) => {
    const actions = [];
    const inSequence = new Set();
    for (const seq of GESTURE_SEQUENCES) {
      const byNode = new Map();
      for (const h of hs) if (seq.includes(h.event)) (byNode.get(h.node) || byNode.set(h.node, []).get(h.node)).push(h);
      for (const list of byNode.values()) {
        const steps = [];
        for (const ev of seq) {
          const h = list.find((x) => x.event === ev);
          if (!h) continue;
          inSequence.add(h);
          const times = ev === seq[1] ? 2 : 1;
          for (let k = 0; k < times; k++) steps.push({ h, sample: sequenceStep(h, steps.length, 4) });
        }
        if (steps.length) actions.push({ steps, label: `${seq[0].replace(/start|down$/, "")} on ${labelOf(steps[0].h).split(" ").slice(1).join(" ")}` });
      }
    }
    for (const h of hs) {
      if (inSequence.has(h)) continue;
      for (const sample of samplesFor(h)) actions.push({ steps: [{ h, sample }], label: labelOf(h, sample.value) });
    }
    return actions;
  };
  const handlersOf = (tree) => {
    const found = [];
    walk(tree, "root", found);
    const seen = new Set();
    return found.filter((h) => typeof h.name === "string" && h.name && !seen.has(h.name + ":" + h.event) && seen.add(h.name + ":" + h.event));
  };
  const snapshot = () => {
    const r = vm.evalCode("typeof __asemanSnapshot === 'function' ? __asemanSnapshot() : null");
    if (r.error) {
      r.error.dispose();
      return null;
    }
    const v = vm.dump(r.value);
    r.value.dispose();
    return typeof v === "string" ? v : null;
  };
  const explored = { states: 0, transitions: 0 };
  const errorBases = new Set();
  // Breadth-first over distinct app states, within a time and step budget.
  async function exploreStates() {
    const start = snapshot();
    if (!start) return;
    exploring = true;
    const end = Date.now() + exploreMs;
    const seen = new Set([start]);
    const frontier = [{ state: start, path: [] }];
    try {
      while (frontier.length && explored.transitions < maxTransitions && Date.now() < end) {
        const { state, path } = frontier.shift();
        explored.states++;
        currentPath = path;
        evaluate(`__asemanRestore(${JSON.stringify(state)})`, "restore.js");
        await drain();
        const hs = handlersOf(latest()).slice(0, 60);
        for (const action of actionsOf(hs)) {
          if (explored.transitions >= maxTransitions || Date.now() >= end) break;
          explored.transitions++;
          evaluate(`__asemanRestore(${JSON.stringify(state)})`, "restore.js");
          currentPath = path.concat(action.label);
          for (const { h, sample } of action.steps) {
            running = `${h.at}: handler ${h.name} (${h.event})`;
            const r = evaluate(`globalThis[${JSON.stringify(h.name)}](${JSON.stringify(typed(sample))})`, "event.js");
            if (r.error) {
              const base = `${h.at}: handler ${h.name} (${h.event}) threw: ${r.error.split("\n")[0]}`;
              if (!errorBases.has(base)) {
                errorBases.add(base);
                errors.push(`${base}${stepsText(currentPath)}`);
              }
              break;
            }
            await drain();
          }
          const next = snapshot();
          if (next && !seen.has(next) && seen.size < 4000) {
            seen.add(next);
            frontier.push({ state: next, path: currentPath });
          }
        }
      }
    } finally {
      exploring = false;
      currentPath = [];
    }
  }

  // Every handler the screens name exists and works with a sample event (a
  // gesture's handlers as the sequence the finger makes).
  const tried = new Set();
  for (let pass = 0; pass < 3 && tried.size < maxHandlers; pass++) {
    const found = [];
    walk(latest(), "root", found);
    const fresh = [];
    for (const h of found) {
      if (tried.size >= maxHandlers) break;
      const key = `${h.name}:${h.event}`;
      if (tried.has(key)) continue;
      tried.add(key);
      if (typeof h.name !== "string" || !h.name) {
        errors.push(`${h.at}: events.${h.event} must name a global function`);
        continue;
      }
      const isFn = vm.evalCode(`typeof globalThis[${JSON.stringify(h.name)}] === "function"`);
      const ok = isFn.error ? false : vm.dump(isFn.value);
      (isFn.error || isFn.value).dispose();
      if (!ok) {
        errors.push(`${h.at}: events.${h.event} names "${h.name}", which is not a global function`);
        continue;
      }
      fresh.push(h);
    }
    const once = new Set();
    for (const action of actionsOf(fresh)) {
      if (action.steps.length === 1 && once.has(action.steps[0].h)) continue;
      once.add(action.steps[0].h);
      for (const { h, sample } of action.steps) {
        running = `${h.at}: handler ${h.name} (${h.event})`;
        const r = evaluate(`globalThis[${JSON.stringify(h.name)}](${JSON.stringify(typed(sample))})`, "event.js");
        if (r.error) {
          errors.push(`${h.at}: handler ${h.name} (${h.event}) threw: ${r.error}`);
          break;
        }
        await drain();
      }
    }
  }
  if (explore) await exploreStates();
  // The same program in a desk window: the layout it picks for wide screens
  // renders and validates too.
  if (renders.length) {
    const desk = { width: 1280, height: 800, sizeClass: "expanded", orientation: "landscape" };
    env.viewport = desk;
    currentPath = [`a desk window ${desk.width}×${desk.height}`];
    running = "the app in a desk window";
    const r = evaluate(`typeof __asemanEnv === "function" && __asemanEnv(${JSON.stringify(JSON.stringify(typed(env)))})`, "env.js");
    if (r.error) errors.push(`the app in a desk window (${desk.width}×${desk.height}) threw: ${r.error}`);
    await drain();
    currentPath = [];
  }
  const final = [];
  for (const tree of renders.slice(-3)) walk(tree, "root", final);
  for (const api of unknownApis) warnings.push(`askHost("${api}") is not an Aseman host API: use the SDK (Aseman.*)`);
  vm.dispose();
  runtime.dispose();
  addValidation(renders, renderPaths, false, errors, warnings, vopts, renderViewports);
  const out = { ok: errors.length === 0, errors: dedupeSteps(errors), warnings: dedupeSteps(warnings), renders: renders.length, handlers: tried.size, states: explored.states, transitions: explored.transitions };
  if (collect) Object.assign(out, { trees: renders, paths: renderPaths, viewports: renderViewports, theme: SAMPLE_ENV.theme });
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const opt = (name) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : "";
  };
  const file = args.find((a, i) => !a.startsWith("--") && !["--server", "--apps"].includes(args[i - 1])) || "elpian/app.js";
  const appsFile = opt("--apps");
  const report = await check(fs.readFileSync(file, "utf8"), {
    server: opt("--server"),
    apps: appsFile && fs.existsSync(appsFile) ? JSON.parse(fs.readFileSync(appsFile, "utf8")) : null,
    widget: !args.includes("--no-widget"),
    widgetOnly: args.includes("--widget-only"),
  }).catch((e) => ({ ok: false, errors: [e.message], warnings: [] }));
  if (args.includes("--json")) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    for (const w of report.warnings) console.log(`warning: ${w}`);
    for (const e of report.errors) console.log(`error: ${e}`);
    console.log(report.ok ? `elpian check: ok (${report.renders} renders, ${report.handlers} handlers exercised)` : `elpian check: ${report.errors.length} problem(s)`);
  }
  process.exit(report.ok ? 0 : 1);
}
