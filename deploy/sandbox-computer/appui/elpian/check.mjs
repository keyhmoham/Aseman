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
// It also runs the program as its phone-board widget (display "compact"): the
// app must declare one, keep it glanceable and fed with live data.
//
//   node check.mjs elpian/app.js [--server http://127.0.0.1:8787] [--apps APPS.json] [--no-widget | --widget-only] [--json]

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const NODES = JSON.parse(fs.readFileSync(path.join(here, "nodes.json"), "utf8"));
const KNOWN = new Set([...NODES.elpian, ...NODES.html, ...NODES.kit]);
const HOST_APIS = new Set(["render", "aseman.env", "aseman.request", "aseman.compact", "aseman.expand", "println", "env.get",
  "setTimeout", "setInterval", "clearTimeout", "clearInterval"]);

async function loadQuickJS() {
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

function typed(value) {
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
  theme: { mode: "light", accent: "#6750A4", colors: { primary: "#6750A4", onPrimary: "#FFFFFF", primaryContainer: "#EADDFF", surface: "#FEF7FF", onSurface: "#1D1B20", onSurfaceVariant: "#49454F", surfaceContainerHighest: "#E6E0E9", outline: "#79747E" } },
  user: { id: "u-check", handle: "check" },
  space: "s-check",
  room: "r-check",
  title: "Check",
};

// Nodes that do not belong on a glanceable phone widget.
const NOT_IN_WIDGET = new Set(["DataGrid", "ListView", "GridView", "TextField", "Scaffold", "AppBar", "Drawer", "textarea", "input", "form", "table"]);
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

async function run(source, { server = "", apps = null, maxHandlers = 40, millis = 10000, display = "full" } = {}) {
  const compact = display === "compact";
  const env = { ...SAMPLE_ENV, display, widget: compact ? { size: "medium", shape: "card" } : undefined };
  const intervals = [];
  let hint = null;
  let requests = 0;
  const errors = [];
  const warnings = [];
  const renders = [];
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
        if (typeof parsed === "string" && parsed.startsWith("app error:")) errors.push(`${running}: ${parsed.slice(11).trim()}`);
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
        if (res.status >= 500) errors.push(`the app's server answered ${req.method || "GET"} /${req.path} with HTTP ${res.status}: ${text.slice(0, 300)}`);
        return { ok: true, status: 200, data: { status: res.status, ok: res.ok, json, text, contentType: res.headers.get("content-type") || "" } };
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
        if (r.error) errors.push(`after the host answered ${req.op || "/" + req.path}: ${r.error}`);
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
    for (const [ev, name] of Object.entries(node.events || {})) found.push({ at: `${at}.${type}`, event: ev, name });
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
    report.ok = errors.length === 0;
    report.errors = [...new Set(errors)];
    return report;
  }

  // Every handler the screens name exists and works with a sample event.
  const tried = new Set();
  for (let pass = 0; pass < 3 && tried.size < maxHandlers; pass++) {
    const found = [];
    walk(latest(), "root", found);
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
      const sample = { type: h.event, eventType: h.event, data: h.event === "select" ? { index: 0, row: {} } : null,
        value: h.event === "input" ? "sample" : h.event === "change" ? true : undefined };
      running = `${h.at}: handler ${h.name} (${h.event})`;
      const r = evaluate(`globalThis[${JSON.stringify(h.name)}](${JSON.stringify(typed(sample))})`, "event.js");
      if (r.error) errors.push(`${h.at}: handler ${h.name} (${h.event}) threw: ${r.error}`);
      await drain();
    }
  }
  const final = [];
  for (const tree of renders.slice(-3)) walk(tree, "root", final);
  for (const api of unknownApis) warnings.push(`askHost("${api}") is not an Aseman host API: use the SDK (Aseman.*)`);
  vm.dispose();
  runtime.dispose();
  return { ok: errors.length === 0, errors: [...new Set(errors)], warnings, renders: renders.length, handlers: tried.size };
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
