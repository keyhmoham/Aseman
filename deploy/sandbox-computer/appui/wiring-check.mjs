#!/usr/bin/env node
// aseman-wiring-check: the platform's check that an app is wired to its space
// for real. An app built in a space uses the space's own agents and apps —
// exactly those its APPS.json lists, by those names — through the Aseman API,
// from its page or its server. This reads the app's own source (not vendor/,
// node_modules/, builds or tests) and refuses:
//
//   - an agent or app (or a microtool of it) that is not in APPS.json: made
//     up, misspelled, or from another space;
//   - an imitation of the gateway's Aseman API (a route of the app's own
//     server at _aseman/…): the gateway answers that path itself, so such a
//     route stands in for the space's agents and apps instead of using them;
//   - a platform frontend (JOB.json audience "platform") whose server uses the
//     app key while serving people (it must use the request's token).
//
// It warns (without refusing) about model calls made straight to a provider
// or the LLM gateway in an app that has agents to ask, and about wiring that
// was asked for but is never used.
//
//   node wiring-check.mjs <dir> [--apps APPS.json] [--json]
//
// Exit 0: wired for real (warnings may follow). Exit 1: problems, one per line.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE = /\.(m?js|cjs|jsx|ts|tsx|py|html?|vue|svelte)$/i;
const SKIP_DIRS = new Set([
  "node_modules", "vendor", ".git", ".aseman", "dist", "build", ".next", "out", "coverage", "__pycache__",
  ".venv", "venv", "test", "tests", "__tests__", "e2e", "fixtures", "mocks", "__mocks__", "spec",
]);
const SKIP_FILES = /(\.|_|-)(test|spec)\.[a-z]+$|^test_.*\.py$|^conftest\.py$/i;
// Built Elpian bundles repeat elpian/src.
const BUILT = new Set(["elpian/app.js", "elpian/widget.js"]);
const MAX_BYTES = 2 << 20;

export function sourceFiles(dir) {
  const out = [];
  const walk = (d) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(e.name) && !e.name.startsWith(".")) walk(p);
        continue;
      }
      const rel = path.relative(dir, p).split(path.sep).join("/");
      if (!SOURCE.test(e.name) || SKIP_FILES.test(e.name) || BUILT.has(rel)) continue;
      try { if (fs.statSync(p).size > MAX_BYTES) continue; } catch { continue; }
      out.push(rel);
    }
  };
  walk(dir);
  return out.sort();
}

const lineOf = (text, index) => text.slice(0, index).split("\n").length;
const templated = (s) => /\$\{|\{\{|%s|\{\}/.test(s);
const STR = String.raw`(["'\x60])([^"'\x60\n]{1,120})\1`;

// Agent names: SDK asks, OpenUI islands, JSON bodies of raw asks.
const AGENT_PATTERNS = [
  new RegExp(String.raw`\.(?:ask|askJSON|ask_json|conversation)\(\s*` + STR, "g"),
  new RegExp(String.raw`\bagent\s*["']?\s*[:=]\s*` + STR, "g"),
];
// Apps: SDK calls (tool, microtool), JSON bodies and OpenUI query islands.
const CALL_PATTERN = new RegExp(String.raw`\.call\(\s*` + STR + String.raw`\s*,\s*(["'\x60])([^"'\x60\n]{1,120})\3`, "g");
const TOOL_KEY = new RegExp(String.raw`\btool\s*["']?\s*[:=]\s*` + STR, "g");
const MICRO_KEY = new RegExp(String.raw`\bmicrotool\s*["']?\s*[:=]\s*` + STR);
// An app's own route at the gateway's path.
// (A route definition hands the path a handler; a page calling the API with
// axios.post("_aseman/api/ask", body) is the right thing and passes.)
const FAKE_GATEWAY = [
  /\.(?:get|post|put|all|use|route|handle)\(\s*["'`]\/?_aseman\/[^"'`]*["'`]\s*,\s*(?:async\s+)?(?:function\b|\(?[\w\s,{}]*\)?\s*=>|[A-Za-z_$][\w$]*\s*\))/g,
  /@\w+\.(?:get|post|put|route|api_route)\(\s*["']\/?_aseman\//g,
  /\bpathname\s*(?:===?|\.startsWith\()\s*["'`]\/_aseman\//g,
];
const DIRECT_MODEL = /ASEMAN_LLM_BASE_URL|api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|\/chat\/completions|\/v1\/messages\b/;
const APP_KEY_IN_HANDLER = /Aseman\.app\(\)|Aseman\.app\(\s*\)|ASEMAN_APP_KEY/;
// Code that runs in the person's browser or the Aseman client, not the server.
const PAGE_CODE = /^(public|static|www|web|client|frontend|src\/client|elpian\/src)\/|\.(html?|vue|svelte|jsx|tsx)$/i;
const SECRET_NAMES = /ASEMAN_DEVELOPER_KEY|ASEMAN_APP_KEY|dk_live_[A-Za-z0-9_-]{8,}|aak_[0-9a-f]{8,}|Aseman\.developer\(/;

function wiringOf(apps) {
  const agents = (apps.agents || []).map((a) => ({ id: String(a.id || ""), name: String(a.name || "") }));
  const tools = (apps.apps || []).map((a) => ({
    id: String(a.bot_id || a.id || ""), name: String(a.name || ""),
    microtools: (a.microtools || []).map((m) => String(m.name || m)).filter(Boolean),
  }));
  return { agents, tools };
}

const same = (ref, x) => ref === x.id || (x.name && ref.toLowerCase() === x.name.toLowerCase());

export function checkWiring(dir, { apps, job } = {}) {
  if (!apps) {
    const f = path.join(dir, "APPS.json");
    apps = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : { apps: [], agents: [] };
  }
  if (!job) {
    const f = path.join(dir, "JOB.json");
    try { job = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {}; } catch { job = {}; }
  }
  const { agents, tools } = wiringOf(apps);
  const problems = [];
  const warnings = [];
  const used = { agents: new Set(), tools: new Set() };
  const agentList = agents.map((a) => a.name).join(", ") || "none";
  const toolList = tools.map((t) => t.name).join(", ") || "none";

  for (const rel of sourceFiles(dir)) {
    const text = fs.readFileSync(path.join(dir, rel), "utf8");
    const at = (i) => `${rel}:${lineOf(text, i)}`;

    for (const re of AGENT_PATTERNS) {
      re.lastIndex = 0;
      for (let m; (m = re.exec(text));) {
        const ref = m[2].trim();
        if (!ref || templated(ref)) continue;
        const hit = agents.find((a) => same(ref, a));
        if (hit) { used.agents.add(hit.name || hit.id); continue; }
        problems.push(`${at(m.index)}: asks agent "${ref}", which is no agent of this space. APPS.json lists: ${agentList}. Use one of those, by that name — never a made-up agent.`);
      }
    }
    CALL_PATTERN.lastIndex = 0;
    for (let m; (m = CALL_PATTERN.exec(text));) {
      const ref = m[2].trim(), micro = m[4].trim();
      if (!ref || templated(ref) || templated(micro)) continue;
      checkTool(ref, micro, at(m.index));
    }
    TOOL_KEY.lastIndex = 0;
    for (let m; (m = TOOL_KEY.exec(text));) {
      const ref = m[2].trim();
      if (!ref || templated(ref)) continue;
      const near = text.slice(Math.max(0, m.index - 200), m.index + 300);
      const micro = MICRO_KEY.exec(near);
      // A "tool" key without a microtool nearby is not an Aseman call.
      if (!micro) continue;
      if (templated(micro[2])) continue;
      checkTool(ref, micro[2].trim(), at(m.index));
    }
    for (const re of FAKE_GATEWAY) {
      re.lastIndex = 0;
      for (let m; (m = re.exec(text));) {
        problems.push(`${at(m.index)}: the app serves its own route at _aseman/…. That path is the Aseman gateway's: it answers it with the space's real agents and apps, so a route of yours there only stands in for them. Remove it; mock the Aseman API in tests only.`);
      }
    }
    if (PAGE_CODE.test(rel)) {
      const m = SECRET_NAMES.exec(text);
      if (m) {
        problems.push(`${at(m.index)}: page code uses the server's credentials (${m[0].slice(0, 24)}). The developer key and the app key stay on the server: give the page a route of your own server that does the call.`);
      }
    } else {
      const leak = /dk_live_[A-Za-z0-9_-]{8,}|aak_[0-9a-f]{8,}/.exec(text);
      if (leak) problems.push(`${at(leak.index)}: a credential is written into the source. Read it from the environment (.aseman/server.env) instead.`);
    }
    if (agents.length && DIRECT_MODEL.test(text)) {
      warnings.push(`${rel}: calls a model directly. Work that needs the judgment of this space's agents (${agentList}) goes to them (ask), not to a model you prompt yourself.`);
    }
    if (job.audience === "platform" && /server|api|routes?|app\.(m?js|cjs|ts|py)$|main\.py$/i.test(rel) && APP_KEY_IN_HANDLER.test(text) &&
      /(req|request)\b/.test(text)) {
      warnings.push(`${rel}: uses the app key. In a platform's frontend, serve people with the request's token (Aseman.fromRequest(req)); the app key is only for work nobody is in front of.`);
    }

    function checkTool(ref, micro, where) {
      const t = tools.find((x) => same(ref, x));
      if (!t) {
        problems.push(`${where}: calls app "${ref}", which is no app of this space. APPS.json lists: ${toolList}. Use one of those, by that name — never a made-up app.`);
        return;
      }
      used.tools.add(t.name || t.id);
      if (micro && t.microtools.length && !t.microtools.includes(micro)) {
        problems.push(`${where}: calls microtool "${micro}" of ${t.name}, which it does not have. Its microtools: ${t.microtools.join(", ")} (args_schema in APPS.json).`);
      }
    }
  }

  // Asked for, never used: the brief named them (appui_create apps/agents).
  if (apps.narrowed) {
    for (const a of agents) if (!used.agents.has(a.name || a.id)) warnings.push(`agent ${a.name} was wired for this app but the code never asks it.`);
    for (const t of tools) if (!used.tools.has(t.name || t.id)) warnings.push(`app ${t.name} was wired for this app but the code never calls it.`);
  }
  return { ok: problems.length === 0, problems: [...new Set(problems)], warnings: [...new Set(warnings)], used: { agents: [...used.agents], apps: [...used.tools] } };
}

function main(argv) {
  const args = argv.slice(2);
  const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  const dir = path.resolve(args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--apps") || ".");
  const appsFile = opt("--apps");
  const apps = appsFile ? JSON.parse(fs.readFileSync(appsFile, "utf8")) : undefined;
  const res = checkWiring(dir, { apps });
  if (args.includes("--json")) {
    process.stdout.write(JSON.stringify(res, null, 2) + "\n");
  } else {
    for (const p of res.problems) console.log("PROBLEM " + p);
    for (const w of res.warnings) console.log("WARNING " + w);
    if (res.ok) console.log(`wired for real: agents ${res.used.agents.join(", ") || "none"}; apps ${res.used.apps.join(", ") || "none"}`);
  }
  process.exit(res.ok ? 0 : 1);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main(process.argv);
