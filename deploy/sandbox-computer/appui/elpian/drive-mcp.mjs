#!/usr/bin/env node
// The Elpian headless driver (drive.mjs) as an MCP server (stdio), so a
// coding agent (OpenCode) can use the Elpian app it built the way a person
// does, step by step, and see that every screen and control works — no
// screenshots: the screen is a text outline with refs.
//
//   elpian_open            start a session: run the bundle against the app's server
//   elpian_snapshot        the screen now (controls with refs e1, e2 …)
//   elpian_tap / _type / _select / _toggle / _gesture / _fire   use controls
//   elpian_wait            let held requests through, pass time, wait for a screen
//   elpian_expect          assert the screen, the state, the requests
//   elpian_state / _env / _mock / _network / _logs / _coverage / _reload / _close
//   elpian_save_scenario   save the session's steps as elpian/e2e/<name>.json
//   elpian_run_scenarios   replay elpian/e2e (what the platform runs before READY)
//
// Register it in opencode.json: "mcp": {"elpian-driver": {"type": "local",
// "command": ["node", "/opt/aseman-appui/elpian/drive-mcp.mjs"]}}.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { serveTools, text } from "./mcp-stdio.mjs";
import { Session, DriveError, runScenarios, formatRun, diffLines } from "./drive.mjs";

const VERSION = "1.0.0";

const INSTRUCTIONS = `Drives an Elpian app headlessly, like a person using it, so you can prove it works end to end — not only its code and APIs. Build the bundle and start your server, then:
1. elpian_open (bundle elpian/app.js, your server or start command) → the first screen as an outline. Every control has a ref (e1, e2 …) that stays the same across renders; target controls by ref, by {key}, or by the text they show.
2. Go through every section and every control: elpian_tap, elpian_type, elpian_select (segments, tabs, nav destinations, sliders, rows, days…), elpian_toggle, elpian_gesture (swipe, drag, pinch, long_press…). Each answers with what changed on the screen, the requests made, and PROBLEMS (exceptions, error banners, server errors, renders that break). Fix every problem in the code, rebuild, elpian_reload, and go on.
3. After each meaningful action, elpian_expect what should be true (text shown, a control's value, the app's state, the request sent). Mock the space's agents and apps with elpian_mock (realistic replies; also failures and held requests to see loading and error states). Check the phone and a desk window (elpian_env), light and dark.
4. elpian_coverage lists the controls no step has used: keep going until it is empty (or every remaining one is explained).
5. elpian_save_scenario saves the session's steps as elpian/e2e/<name>.json — one session per user journey (elpian_open again for the next). elpian_run_scenarios replays them all; the platform runs them before the app is ready, so they must pass.`;

const target = { description: "The control: a ref from the snapshot (\"e12\"), a selector {ref, key, type, text, icon, nth, within}, or the text it shows (\"Add task\"). Tapping an option's label (\"Insights\" on a NavigationBar) picks that option." };
const sessionProp = { session: { type: "string", description: "Session id (default \"main\"); open several to compare." } };
const settleProp = { settle: { type: "boolean", description: "false: leave the requests it makes pending (see the loading state), then elpian_wait." } };
const expectProps = {
  text: { description: "Text (or a list) that must be on the screen." },
  noText: { description: "Text (or a list) that must not be on the screen." },
  target,
  exists: { type: "boolean", description: "With target: whether it is on the screen (default true)." },
  count: { type: "number", description: "With target: how many controls match." },
  value: { description: "With target: its value (a text field's text, a slider's value, a selected segment's value…)." },
  on: { type: "boolean", description: "With target: a switch, checkbox, filter chip or expandable panel is on/open." },
  selected: { description: "With target: the selected option's label (NavigationBar, Tabs, SegmentedButton) or true/false." },
  disabled: { type: "boolean" },
  enabled: { type: "boolean" },
  label: { type: "string", description: "With target: the text it shows." },
  props: { type: "object", description: "With target: props it has (a subset)." },
  rows: { type: "number", description: "With target: a table's or list view's row count." },
  state: { type: "object", description: "The app's state (app.state), by dot paths: {\"draft\": \"\", \"items.length\": 3, \"items.0.title\": \"Milk\"}." },
  request: { description: "A request the last action made: {method, path (\"api/tasks/*\") | op (ask, call…), status, body (a subset), count, none, since: \"all\"}; or a list." },
  errorBanner: { description: "true or text: the app shows its error banner (app.fail). false: none is shown." },
  noProblems: { type: "boolean", description: "true: no problem so far in the session." },
};

const TOOLS = [
  {
    name: "elpian_open",
    description: "Start a session: run the bundled Elpian program on QuickJS (the engine the Aseman client uses) against your running server, as a person opens the app. Answers with the first screen (an outline with refs), the server's state and any problems. Reopening a session id restarts it.",
    inputSchema: { type: "object", properties: {
      ...sessionProp,
      bundle: { type: "string", description: "The bundle (default elpian/app.js)." },
      dir: { type: "string", description: "The project directory (default: the working directory)." },
      build: { type: "boolean", description: "Bundle elpian/src first (node vendor/aseman-elpian/bundle.mjs .)." },
      server: { type: "string", description: "Your running server (default http://127.0.0.1:<JOB.json port>)." },
      start: { type: "string", description: "Start the server with this command (e.g. \"node server.js\", PORT is set) and stop it on close." },
      port: { type: "number", description: "The port for start (default JOB.json port)." },
      apps: { type: "string", description: "APPS.json path (default ./APPS.json): the space's apps and agents." },
      viewport: { description: "phone (360×640, default), phone-large, tablet, desk (1280×800), \"WxH\" or {width, height}." },
      theme: { type: "string", enum: ["light", "dark"] },
      display: { type: "string", enum: ["full", "widget"], description: "widget: the app as its phone widget." },
      mocks: { type: "array", description: "Answers for requests (see elpian_mock)." },
    } },
  },
  {
    name: "elpian_snapshot",
    description: "The screen now as a person sees it: one line per text, control and data view, controls with refs (e1 …), values, selected options, rows of tables, disabled and unreachable controls, handlers (on: …).",
    inputSchema: { type: "object", properties: { ...sessionProp, within: { description: "Only the part inside this control or group (a target)." } } },
  },
  {
    name: "elpian_tap",
    description: "Tap a control (button, icon button, FAB, list tile, card, chip, switch, checkbox, radio, expandable panel, empty-state action, or an option label of a NavigationBar / SegmentedButton / Tabs). A tap on a label reaches the control around it; disabled controls and touches that never arrive do nothing (and say so).",
    inputSchema: { type: "object", required: ["target"], properties: { ...sessionProp, target, kind: { type: "string", enum: ["tap", "double_tap", "long_press"] }, ...settleProp } },
  },
  {
    name: "elpian_type",
    description: "Type into a text field or search bar (replacing its text unless clear: false), as the client sends it (input events with the value); submit: true presses enter.",
    inputSchema: { type: "object", required: ["target", "text"], properties: { ...sessionProp, target, text: { type: "string" }, clear: { type: "boolean", description: "Replace the text (default true)." }, submit: { type: "boolean" }, keystrokes: { type: "boolean", description: "One input event per character (as a person types)." }, ...settleProp } },
  },
  {
    name: "elpian_select",
    description: "Choose an option: a SegmentedButton segment, a NavigationBar destination, a tab, a Pagination page, a Slider/Rating value, a Radio, a select option, a Stepper step, a breadcrumb, a chat suggestion, a Calendar day (yyyy-MM-dd) or month (yyyy-MM), a Kanban card, or a row of a DataGrid / Chart / Timeline / TreeView / Leaderboard (index or a cell's text).",
    inputSchema: { type: "object", required: ["target", "value"], properties: { ...sessionProp, target, value: { description: "The option's label, value or index; a number for sliders and pages; a row index or text." }, ...settleProp } },
  },
  {
    name: "elpian_toggle",
    description: "Switch a Switch, Checkbox or filter Chip on/off, or open/close an Expandable panel.",
    inputSchema: { type: "object", required: ["target"], properties: { ...sessionProp, target, on: { type: "boolean", description: "The state to reach (default: flip it)." }, ...settleProp } },
  },
  {
    name: "elpian_gesture",
    description: "A gesture as the finger makes it: swipe (direction; swipes Dismissibles and Carousels too), drag (from/to points on the node, as dragstart, drag…, dragend; or to: another target to drop a Draggable on a DragTarget), pinch (scale, rotation), long_press, double_tap, hover, move (a Kanban card to a column), link (a Markdown link), remove (an input chip).",
    inputSchema: { type: "object", required: ["target", "gesture"], properties: { ...sessionProp, target,
      gesture: { type: "string", enum: ["swipe", "drag", "pinch", "long_press", "double_tap", "hover", "move", "link", "remove"] },
      direction: { type: "string", enum: ["left", "right", "up", "down"] },
      from: { type: "object", properties: { x: { type: "number" }, y: { type: "number" } }, description: "drag: where the finger starts on the node (local px)." },
      to: { description: "drag: {x, y} where it ends, or a target to drop on. move: the column's title." },
      steps: { type: "number", description: "drag: moves between from and to (default 4)." },
      scale: { type: "number" }, rotation: { type: "number" },
      card: { type: "string", description: "move: the card's title." },
      href: { type: "string", description: "link: the link's URL." },
      ...settleProp } },
  },
  {
    name: "elpian_fire",
    description: "Fire any event a node handles with your own event data (when no other tool fits). Prefer the tools above: they send what the client sends.",
    inputSchema: { type: "object", required: ["target", "event"], properties: { ...sessionProp, target, event: { type: "string" }, data: { type: "object", description: "The event's data (also merged at the top level, like the client)." }, ...settleProp } },
  },
  {
    name: "elpian_wait",
    description: "Wait: let held requests through (release), pass time on the program's clock (ms: timers and app.every refreshes fire), or wait until an expectation holds (until, as in elpian_expect; time passes until it does or timeoutMs).",
    inputSchema: { type: "object", properties: { ...sessionProp, release: { description: "true, or {path} / {op}: let held requests through." }, ms: { type: "number" }, until: { type: "object", properties: expectProps }, timeoutMs: { type: "number" } } },
  },
  {
    name: "elpian_expect",
    description: "Assert what a person should see and what should have happened: text on the screen, a control's value / state / label, the app's state, the request the last action made, an error banner, no problems. Saved into the scenario. On failure it shows the screen.",
    inputSchema: { type: "object", properties: { ...sessionProp, ...expectProps } },
  },
  {
    name: "elpian_state",
    description: "Read the app's state (app.state), or a dot path of it. set: patch it (to reach a state that is slow to reach by hand; recorded in the scenario — prefer real actions).",
    inputSchema: { type: "object", properties: { ...sessionProp, path: { type: "string" }, set: { type: "object" } } },
  },
  {
    name: "elpian_env",
    description: "Change the screen the app is drawn on, as the client does: viewport (phone, phone-large, tablet, desk, \"WxH\"), theme (light/dark), display (full or widget). The app redraws; check the layout it picks.",
    inputSchema: { type: "object", properties: { ...sessionProp, viewport: {}, theme: { type: "string", enum: ["light", "dark"] }, display: { type: "string", enum: ["full", "widget"] } } },
  },
  {
    name: "elpian_mock",
    description: "Answer requests with your own replies (later mocks win). The space's agents and apps are mocked by default with sample replies: give realistic ones. A mock: {op: \"ask\", agent?, match?, reply} | {op: \"call\", tool?, microtool?, match?, result} | {op: \"agents\"|\"tools\"|\"context\", data} | {path: \"api/x/*\", method?, status?, json? | text?} (overrides your server); add error + status to fail, hold: true to keep it pending (see the loading state; elpian_wait release), times: n to use it n times. match: text in the request (or \"re:<regex>\").",
    inputSchema: { type: "object", properties: { ...sessionProp, mocks: { type: "array", items: { type: "object" } }, clear: { type: "boolean", description: "Remove the mocks in place first." } } },
  },
  {
    name: "elpian_network",
    description: "The requests the app made: to its server (method, path, status) and to the space (ask, call…), mocked or real, held or answered, and the action that made them.",
    inputSchema: { type: "object", properties: { ...sessionProp, last: { type: "number", description: "Only the last n (default 30)." }, bodies: { type: "boolean", description: "Include request bodies." } } },
  },
  {
    name: "elpian_logs",
    description: "What the program logged (Aseman.log, errors) and every problem found in the session so far.",
    inputSchema: { type: "object", properties: { ...sessionProp, last: { type: "number" } } },
  },
  {
    name: "elpian_coverage",
    description: "Which controls and events seen in the session no step has used yet (and where they were seen), and the dead controls (buttons without handlers…). Test until nothing is left.",
    inputSchema: { type: "object", properties: { ...sessionProp } },
  },
  {
    name: "elpian_reload",
    description: "Open the app again: a fresh run of the program (rebuilt with build: true), the server keeps its data. Use after fixing the code, or to test that data persists.",
    inputSchema: { type: "object", properties: { ...sessionProp, build: { type: "boolean", description: "Rebundle elpian/src first." } } },
  },
  {
    name: "elpian_save_scenario",
    description: "Save the session's steps (actions and expectations, with portable targets) as a scenario: elpian/e2e/<name>.json. One session per journey: save, then elpian_open again for the next. Replayed by elpian_run_scenarios and by the platform before READY.",
    inputSchema: { type: "object", required: ["name"], properties: { ...sessionProp, name: { type: "string", description: "The journey, e.g. \"add-and-complete-a-task\"." }, description: { type: "string" }, file: { type: "string", description: "Where (default elpian/e2e/<name>.json)." } } },
  },
  {
    name: "elpian_run_scenarios",
    description: "Replay scenarios (default every elpian/e2e/*.json) in fresh sessions against your server: each step must work, each expectation hold, no problem left. Reports failures with the screen at the failure, and the controls no scenario uses.",
    inputSchema: { type: "object", properties: { paths: { type: "array", items: { type: "string" } }, bundle: { type: "string" }, dir: { type: "string" }, server: { type: "string" }, start: { type: "string" }, apps: { type: "string" } } },
  },
  {
    name: "elpian_close",
    description: "End a session (stops a server it started).",
    inputSchema: { type: "object", properties: { ...sessionProp } },
  },
];

const sessions = new Map();

function get(args) {
  const id = args.session || "main";
  const s = sessions.get(id);
  if (!s) throw new DriveError(`no session "${id}": call elpian_open first`);
  return s;
}

const step = (args, extra) => {
  const out = { ...extra, target: args.target };
  if (args.settle === false) out.settle = false;
  return out;
};

function problemsLine(s) {
  const open = s.openProblems();
  return open.length ? `PROBLEMS (${open.length}):\n${open.map((p) => `  [${p.kind}] ${p.message}${p.after ? ` (after: ${p.after})` : ""}`).join("\n")}` : "problems: none";
}

function readApps(args, dir) {
  if (!args.apps) return undefined;
  const f = path.resolve(dir, args.apps);
  return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : undefined;
}

export async function call(name, args = {}) {
  try {
    switch (name) {
      case "elpian_open": {
        const id = args.session || "main";
        if (sessions.has(id)) {
          await sessions.get(id).close();
          sessions.delete(id);
        }
        const dir = path.resolve(args.dir || process.cwd());
        const s = await Session.open({ ...args, dir, apps: readApps(args, dir), mocks: args.mocks });
        sessions.set(id, s);
        return text([`session "${id}" open: ${s.bundlePath ? path.relative(process.cwd(), s.bundlePath) || s.bundlePath : "source"}${s.server ? ` against ${s.server}` : " (no server)"}`,
          ...s.notes, "", s.snapshotText(), "", problemsLine(s)].join("\n"));
      }
      case "elpian_snapshot": {
        const s = get(args);
        if (args.within !== undefined) {
          const scope = s.resolve(args.within, { prefer: "any" });
          const inside = new Set();
          const add = (e) => { inside.add(e); e.children.forEach(add); };
          add(scope);
          return text(s.outline().filter((l) => inside.has(l.e)).map((l) => l.text).join("\n") || "(nothing there)");
        }
        return text(`${s.snapshotText()}\n\n${problemsLine(s)}`);
      }
      case "elpian_tap": {
        const s = get(args);
        return text((await s.run(step(args, { do: args.kind || "tap" }))).text);
      }
      case "elpian_type": {
        const s = get(args);
        return text((await s.run(step(args, { do: "type", text: args.text, clear: args.clear, submit: args.submit, keystrokes: args.keystrokes }))).text);
      }
      case "elpian_select": {
        const s = get(args);
        return text((await s.run(step(args, { do: "select", value: args.value }))).text);
      }
      case "elpian_toggle": {
        const s = get(args);
        return text((await s.run(step(args, { do: "toggle", on: args.on }))).text);
      }
      case "elpian_gesture": {
        const s = get(args);
        const { session, gesture, target, settle, ...rest } = args;
        return text((await s.run(step(args, { do: gesture, ...rest }))).text);
      }
      case "elpian_fire": {
        const s = get(args);
        return text((await s.run(step(args, { do: "fire", event: args.event, data: args.data }))).text);
      }
      case "elpian_wait": {
        const s = get(args);
        const r = await s.run({ do: "wait", release: args.release, ms: args.ms, until: args.until, timeoutMs: args.timeoutMs });
        return text(r.text);
      }
      case "elpian_expect": {
        const s = get(args);
        const { session, ...x } = args;
        const r = await s.run({ expect: x });
        return text(r.text, false);
      }
      case "elpian_state": {
        const s = get(args);
        if (args.set) return text((await s.run({ do: "setState", patch: args.set })).text);
        const st = s.state();
        const v = args.path ? String(args.path).split(".").filter(Boolean).reduce((o, k) => (o == null ? undefined : o[k]), st) : st;
        return text(JSON.stringify(v, null, 1) ?? "undefined");
      }
      case "elpian_env": {
        const s = get(args);
        return text((await s.run({ do: "env", viewport: args.viewport, theme: args.theme, display: args.display })).text);
      }
      case "elpian_mock": {
        const s = get(args);
        return text((await s.run({ do: "mock", mocks: args.mocks || [], clear: args.clear })).text.split("\n")[0]);
      }
      case "elpian_network": {
        const s = get(args);
        const list = s.network.slice(-(args.last || 30));
        if (!list.length) return text("no requests yet");
        return text(list.map((n) => `#${n.n} ${n.what} → ${n.status}${n.mocked ? " (mock)" : ""}${n.ms ? ` ${n.ms} ms` : ""} — after: ${n.after}${args.bodies && n.body !== undefined ? `\n    body: ${JSON.stringify(n.body).slice(0, 600)}` : ""}`).join("\n"));
      }
      case "elpian_logs": {
        const s = get(args);
        const logs = s.logs.slice(-(args.last || 50)).map((l) => `[${l.at} ms] ${l.text}`);
        const all = s.problems.map((p) => `[${p.kind}${p.expected ? ", expected" : ""}] ${p.message}${p.after ? ` (after: ${p.after})` : ""}`);
        return text(`logs:\n${logs.join("\n") || "  (none)"}\n\nproblems in this session:\n${all.join("\n") || "  (none)"}`);
      }
      case "elpian_coverage":
        return text(get(args).coverageText());
      case "elpian_reload": {
        const s = get(args);
        const before = s.outline().map((l) => l.text.trim());
        if (args.build) s.opts.build = true;
        const r = await s.run({ do: "reload" });
        return text(`${r.text.split("\n")[0]}\n${s.snapshotText()}\n\n${problemsLine(s)}${diffLines(before, s.outline().map((l) => l.text.trim())).length ? "" : "\n(the same screen as before)"}`);
      }
      case "elpian_save_scenario": {
        const s = get(args);
        if (!s.steps.length) throw new DriveError("the session has no steps to save yet");
        const slug = String(args.name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "scenario";
        const file = path.resolve(s.dir, args.file || path.join("elpian", "e2e", `${slug}.json`));
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const sc = s.scenario(args.name, args.description);
        fs.writeFileSync(file, JSON.stringify(sc, null, 2) + "\n");
        const acts = sc.steps.filter((x) => x.do).length;
        const checks = sc.steps.filter((x) => x.expect).length;
        return text(`saved ${path.relative(process.cwd(), file) || file}: ${acts} action(s), ${checks} expectation(s)${checks ? "" : " — add elpian_expect steps: a scenario without expectations proves little"}\n${s.coverageText()}`);
      }
      case "elpian_run_scenarios": {
        const dir = path.resolve(args.dir || process.cwd());
        const open = [...sessions.values()][0];
        const run = await runScenarios((args.paths && args.paths.length ? args.paths : ["elpian/e2e"]).map((p) => path.resolve(dir, p)), {
          dir, bundle: args.bundle || "elpian/app.js", server: args.server || (open && !args.start ? open.server : undefined), start: args.start, apps: readApps(args, dir),
        });
        return text(formatRun(run), false);
      }
      case "elpian_close": {
        const id = args.session || "main";
        const s = sessions.get(id);
        if (!s) return text(`no session "${id}"`);
        await s.close();
        sessions.delete(id);
        return text(`session "${id}" closed`);
      }
      default:
        return null;
    }
  } catch (e) {
    if (e instanceof DriveError) return text(e.message, true);
    throw e;
  }
}

export async function closeAll() {
  for (const s of sessions.values()) await s.close();
  sessions.clear();
}

export function serve(input = process.stdin, output = process.stdout) {
  return serveTools({ name: "aseman-elpian-driver", version: VERSION, instructions: INSTRUCTIONS, tools: TOOLS, call, failure: "The driver failed" }, input, output);
}

export { TOOLS, INSTRUCTIONS };

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const stop = () => closeAll().finally(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  serve()
    .then(() => closeAll())
    .catch((e) => {
      process.stderr.write(String(e && e.stack ? e.stack : e) + "\n");
      process.exit(1);
    });
}
