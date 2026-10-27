// node --test deploy/sandbox-computer/appui/elpian/test/
// Needs quickjs-emscripten (deploy/tool-runtime: npm install).
import test from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Session, runScenarios, formatRun, pathMatches, subset } from "../drive.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const kit = path.resolve(here, "..");
const SDK = ["aseman-elpian.js", "openui-elpian.js"].map((f) => fs.readFileSync(path.join(kit, f), "utf8")).join("\n;\n");
const SHOWCASE = SDK + "\n;\n" + fs.readFileSync(path.join(kit, "examples", "showcase.js"), "utf8");

// The showcase's server: GET/POST api/tasks, POST api/tasks/<id>/toggle.
function tasksServer() {
  const tasks = [
    { id: 1, title: "Write spec", owner: "ana", due: "today", done: false, priority: "high" },
    { id: 2, title: "Ship it", owner: "bo", due: "friday", done: true, priority: "normal" },
  ];
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      if (req.url === "/api/tasks" && req.method === "POST") tasks.push({ id: tasks.length + 1, done: false, due: "today", ...JSON.parse(body) });
      const m = /^\/api\/tasks\/(\d+)\/toggle$/.exec(req.url);
      if (m) {
        const t = tasks.find((x) => x.id === Number(m[1]));
        if (t) t.done = !t.done;
      }
      if (req.url === "/api/boom") {
        res.writeHead(500);
        return res.end("kaput");
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ tasks }));
    });
  });
  return new Promise((r) => srv.listen(0, "127.0.0.1", () => r({ srv, tasks, url: `http://127.0.0.1:${srv.address().port}` })));
}

function runCli(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(kit, "drive.mjs"), ...args]);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

async function withServer(fn) {
  const s = await tasksServer();
  try {
    return await fn(s);
  } finally {
    s.srv.close();
  }
}

test("a session reads the screen as an outline with stable refs", async () => {
  await withServer(async ({ url }) => {
    const s = await Session.open({ source: SHOWCASE, server: url });
    try {
      const snap = s.snapshotText();
      assert.match(snap, /^Screen 360×640 \(compact, light\)/);
      assert.match(snap, /Text "Team tasks"/);
      assert.match(snap, /IconButton \[e\d+\] "Refresh" icon=refresh \(on: tap\)/);
      assert.match(snap, /SegmentedButton \[e\d+\] options: Open\* \| Done \| All \(on: change\)/);
      assert.match(snap, /ListTile \[e\d+\] "Write spec" — "ana · due today" trailing="Urgent" \(on: tap\)/);
      assert.match(snap, /NavigationBar \[e\d+\] items: Tasks\* \(1\) \| New \| Insights/);
      assert.doesNotMatch(snap, /- (Column|Row|Padding|ListView)\b/, "pure layout is left out");
      const ref = /SegmentedButton \[(e\d+)\]/.exec(snap)[1];
      await s.run({ do: "select", target: ref, value: "Done" });
      assert.match(s.snapshotText(), new RegExp(`SegmentedButton \\[${ref}\\] options: Open \\| Done\\* \\| All`), "the same control keeps its ref");
      assert.deepEqual(s.openProblems(), []);
    } finally {
      await s.close();
    }
  });
});

test("a journey: navigate, type, toggle, tap, with the screen changes and requests of each step", async () => {
  await withServer(async ({ url, tasks }) => {
    const s = await Session.open({ source: SHOWCASE, server: url });
    try {
      let r = await s.run({ do: "tap", target: "New" });
      assert.match(r.text, /✓ went to "New" on the NavigationBar/);
      assert.match(r.text, /\+ - TextField \[e\d+\] "What needs doing\?" value=""/);
      assert.match(r.text, /\+ - Button \[e\d+\] "Add task" icon=add disabled/);
      r = await s.run({ do: "type", target: "What needs doing?", text: "Buy milk" });
      assert.match(r.text, /value="Buy milk"/);
      assert.match(r.text, /\+ - Button \[e\d+\] "Add task" icon=add \(on: tap\)/, "live input enables the button");
      await s.run({ do: "type", target: { key: "owner" }, text: "kim" });
      r = await s.run({ do: "toggle", target: "Urgent" });
      assert.match(r.text, /Switch \[e\d+\] "Urgent" on/);
      r = await s.run({ do: "tap", target: "Add task" });
      assert.match(r.text, /requests: POST \/api\/tasks → 200 · GET \/api\/tasks → 200/);
      assert.equal(tasks.length, 3);
      assert.deepEqual({ ...tasks[2], id: undefined }, { id: undefined, title: "Buy milk", owner: "kim", priority: "high", done: false, due: "today" });
      r = await s.run({ expect: { text: "Buy milk", state: { tab: 0, draft: "", "tasks.length": 3 }, request: { method: "POST", path: "api/tasks", body: { title: "Buy milk" } } } });
      assert.equal(r.ok, true, r.text);
      r = await s.run({ expect: { request: { method: "POST", path: "api/tasks", count: 2 } } });
      assert.equal(r.ok, false, "counts the last action's requests");
      assert.match(r.text, /made 2 request\(s\) POST \/api\/tasks \(made 1\)/);
      r = await s.run({ do: "tap", target: "Buy milk" });
      assert.match(r.text, /POST \/api\/tasks\/3\/toggle → 200/);
      r = await s.run({ expect: { target: { key: "filter" }, selected: "Open" } });
      assert.equal(r.ok, true, r.text);
      r = await s.run({ expect: { noText: "Buy milk" } });
      assert.equal(r.ok, true, "a done task leaves the open filter");
      assert.deepEqual(s.openProblems(), []);
    } finally {
      await s.close();
    }
  });
});

test("people cannot use what is disabled, unreachable or has no handler — and the driver says so", async () => {
  const s = await Session.open({ source: SDK + `
    var app = App.create({ state: { n: 0, draft: "" }, view: function (s, app) { return { type: "Column", children: [
      { type: "Text", props: { text: "n=" + s.n } },
      { type: "Button", props: { text: "Save", disabled: true }, events: { tap: app.handler("save", function () { app.set({ n: s.n + 1 }); }) } },
      { type: "Button", props: { text: "Inner" }, children: [{ type: "Text", props: { text: "x" }, events: { tap: app.handler("inner", function () { app.set({ n: 99 }); }) } }] },
      { type: "Button", props: { text: "Nothing" } },
      { type: "Container", props: { style: { pointerEvents: "none", height: 40 } }, children: [
        { type: "IconButton", props: { icon: "add", tooltip: "Plus" }, events: { tap: app.handler("plus", function () { app.set({ n: s.n + 1 }); }) } } ] },
      { type: "Card", events: { tap: app.handler("card", function () { app.set({ n: s.n + 10 }); }) }, children: [{ type: "Text", props: { text: "Open card" } }] },
      app.input("draft", "draft", { label: "Draft" }),
    ] }; } });` });
  try {
    let r = await s.run({ do: "tap", target: "Save" });
    assert.equal(r.done, false);
    assert.match(r.text, /it is disabled: nothing happens/);
    r = await s.run({ do: "tap", target: "Plus" });
    assert.match(r.text, /a touch never reaches it: touches pass through it \(style.pointerEvents: none\)/);
    r = await s.run({ do: "tap", target: { type: "Text", text: "x" } });
    assert.match(r.text, /inside a Button, which takes the touches/);
    r = await s.run({ do: "tap", target: "Nothing" });
    assert.match(r.text, /no tap handler \(a dead control\)/);
    assert.match(s.coverageText(), /Button "Nothing" does nothing when tapped/);
    r = await s.run({ do: "tap", target: "Open card" });
    assert.match(r.text, /tap Card "Open card"/);
    assert.match(r.text, /\+ - Text "n=10"/, "a tap on a label reaches the card around it");
    r = await s.run({ do: "type", target: "Draft", text: "hello" });
    assert.match(r.text, /value="hello"/, "a text field keeps what was typed, even without a redraw");
    assert.deepEqual(s.state(), { n: 10, draft: "hello" });
    assert.match(s.coverageText(), /not used yet:[\s\S]*Button "Save": tap — seen after: the first screen \(only seen disabled\)/);
  } finally {
    await s.close();
  }
});

test("targets: by ref, key, text, type and nth; ambiguity and misses name the candidates", async () => {
  const s = await Session.open({ source: SDK + `
    App.create({ state: {}, view: function (s, app) { return { type: "Column", children: [
      { type: "Button", props: { text: "Delete" }, events: { tap: app.handler("d1", function () {}) } },
      { type: "Button", props: { text: "Delete" }, events: { tap: app.handler("d2", function () {}) } },
      { type: "Slider", key: "vol", props: { value: 0.2, min: 0, max: 1 }, events: { change: app.handler("vol", function (e, app) { app.set({ vol: e.value }); }) } },
    ] }; } });` });
  try {
    await assert.rejects(s.run({ do: "tap", target: "Delete" }), /matches 2 controls[\s\S]*nth 0: Button \[e\d+\] "Delete"[\s\S]*nth 1:/);
    await assert.rejects(s.run({ do: "tap", target: "Remove" }), /nothing on the screen matches \{"text":"Remove"\}[\s\S]*Button \[e\d+\] "Delete"/);
    const r = await s.run({ do: "tap", target: { text: "Delete", nth: 1 } });
    assert.equal(r.done, true);
    assert.deepEqual(s.steps[0].target, { type: "Button", text: "Delete", nth: 1 });
    await s.run({ do: "select", target: "Slider", value: 3 });
    assert.equal(s.state().vol, 1, "a slider value is kept within its range");
    await assert.rejects(s.run({ do: "tap", target: { key: "vol" } }), /choose one of its options with elpian_select/);
  } finally {
    await s.close();
  }
});

test("mocks: failing agents show the error banner; a scenario must expect it", async () => {
  const src = SDK + `
    var app = App.create({ state: { answer: "" }, view: function (s, app) { return { type: "Column", children: [
      { type: "Text", props: { text: s.answer || "No answer yet" } },
      { type: "Button", props: { text: "Ask" }, events: { tap: app.handler("ask", function (e, app) {
        Aseman.ask("planner", "Plan my day").then(function (r) { app.set({ answer: r.reply }); }).catch(function (err) { app.fail(err); });
      }) } },
    ] }; } });`;
  const s = await Session.open({ source: src, mocks: [{ op: "ask", agent: "planner", reply: "Gym at 7, then work" }] });
  try {
    let r = await s.run({ do: "tap", target: "Ask" });
    assert.match(r.text, /requests: ask planner → ok \(mock\)/);
    assert.match(r.text, /\+ - Text "Gym at 7, then work"/);
    await s.run({ do: "mock", mocks: [{ op: "ask", error: "the agent is busy", status: 503 }] });
    r = await s.run({ do: "tap", target: "Ask" });
    assert.match(r.text, /\[app-error\] the app shows an error banner: the agent is busy/);
    assert.match(r.text, /Callout \[e\d+\] "Something went wrong" critical "the agent is busy"/);
    assert.equal(s.openProblems().length, 1);
    r = await s.run({ expect: { errorBanner: "busy" } });
    assert.equal(r.ok, true, r.text);
    assert.deepEqual(s.openProblems(), [], "an expected error banner is not a problem");
    r = await s.run({ do: "tap", target: "Dismiss" });
    assert.match(r.text, /- - Callout/);
  } finally {
    await s.close();
  }
});

test("held requests show the loading state until they are let through", async () => {
  await withServer(async ({ url }) => {
    const s = await Session.open({ source: SHOWCASE, server: url, mocks: [{ path: "api/tasks", method: "GET", hold: true }] });
    try {
      assert.match(s.snapshotText(), /1 request\(s\) held/);
      assert.match(s.snapshotText(), /Text "Loading…"/);
      assert.match(s.snapshotText(), /Shimmer/);
      const r = await s.run({ do: "wait", release: true });
      assert.match(r.text, /let 1 held request\(s\) through/);
      assert.match(r.text, /requests: GET \/api\/tasks → 200/);
      assert.match(r.text, /\+ - ListTile \[e\d+\] "Write spec"/);
    } finally {
      await s.close();
    }
  });
});

test("time passes on the program's clock: timers and refreshes fire", async () => {
  const s = await Session.open({ source: SDK + `
    var app = App.create({ state: { ticks: 0 }, view: function (s) { return { type: "Text", props: { text: "ticks " + s.ticks } }; },
      init: function (app) { app.every("tick", 10000, function (app) { app.set({ ticks: app.state.ticks + 1 }); }); } });` });
  try {
    let r = await s.run({ do: "wait", ms: 25000 });
    assert.match(r.text, /\+ - Text "ticks 2"/);
    r = await s.run({ do: "wait", until: { text: "ticks 5" } });
    assert.equal(r.done, true, r.text);
    r = await s.run({ do: "wait", until: { text: "never" }, timeoutMs: 20000 });
    assert.equal(r.done, false);
  } finally {
    await s.close();
  }
});

test("kit controls: tabs and expandables switch by themselves; rows, days and cards are chosen with the client's data", async () => {
  const s = await Session.open({ source: SDK + `
    var app = App.create({ state: { picked: null, day: null, card: null, moved: null }, view: function (s, app) { return { type: "Column", children: [
      { type: "Tabs", key: "tabs", props: { tabs: ["One", "Two"] }, children: [
        { type: "Text", props: { text: "first panel" } }, { type: "Text", props: { text: "second panel" } } ] },
      { type: "Expandable", props: { title: "More" }, children: [{ type: "Text", props: { text: "hidden detail" } }] },
      { type: "DataGrid", props: { data: [{ name: "Ana", score: 3 }, { name: "Bo", score: 5 }], columns: [{ field: "name" }, { field: "score" }] },
        events: { select: app.handler("row", function (e, app) { app.set({ picked: e.row.name + "@" + e.index }); }) } },
      { type: "Calendar", props: { month: "2026-05", events: [{ date: "2026-05-04", title: "Gym" }] },
        events: { select: app.handler("day", function (e, app) { app.set({ day: e.date + ":" + e.events.length }); }) } },
      { type: "Kanban", props: { columns: [{ id: "todo", title: "To do", cards: [{ title: "Paint" }] }, { id: "done", title: "Done", cards: [] }] },
        events: { move: app.handler("move", function (e, app) { app.set({ moved: e.card.title + "→" + e.toId }); }) } },
      { type: "Dismissible", key: "row1", events: { dismissed: app.handler("gone", function (e, app) { app.set({ card: "dismissed " + e.direction }); }) },
        children: [{ type: "Text", props: { text: "swipe me" } }] },
    ] }; } });` });
  try {
    assert.match(s.snapshotText(), /Tabs \[e\d+\] tabs: One\* \| Two/);
    assert.doesNotMatch(s.snapshotText(), /second panel|hidden detail/);
    await s.run({ do: "tap", target: "Two" });
    assert.match(s.snapshotText(), /second panel/);
    await s.run({ do: "tap", target: "More" });
    assert.match(s.snapshotText(), /Expandable \[e\d+\] "More" open/);
    assert.match(s.snapshotText(), /hidden detail/);
    assert.match(s.snapshotText(), /· row 1: name=Bo, score=5/);
    await s.run({ do: "select", target: "DataGrid", value: "Bo" });
    await s.run({ do: "select", target: "Calendar", value: "2026-05-04" });
    await s.run({ do: "move", target: "Kanban", card: "Paint", to: "Done" });
    await s.run({ do: "swipe", target: "swipe me", direction: "left" });
    assert.deepEqual(s.state(), { picked: "Bo@1", day: "2026-05-04:1", card: "dismissed endToStart", moved: "Paint→done" });
    const r = await s.run({ expect: { target: "Tabs", selected: "Two" } });
    assert.equal(r.ok, true, r.text);
  } finally {
    await s.close();
  }
});

test("drawing: a drag is the sequence the finger makes, with positions", async () => {
  const s = await Session.open({ source: SDK + `
    var app = App.create({ state: { strokes: [], current: null }, view: function (s, app) { return { type: "Column", children: [
      { type: "Text", props: { text: s.strokes.length + " strokes" } },
      { type: "Expanded", children: [{ type: "Canvas", key: "pad", events: {
        dragstart: app.handler("down", function (e, app) { app.state.current = [[e.localPosition.x, e.localPosition.y]]; }),
        drag: app.handler("move", function (e, app) { app.state.current.push([e.localPosition.x, e.localPosition.y]); }),
        dragend: app.handler("up", function (e, app) { app.set({ strokes: app.state.strokes.concat([app.state.current]), current: null }); }),
      } }] },
    ] }; } });` });
  try {
    const r = await s.run({ do: "drag", target: { key: "pad" }, from: { x: 10, y: 10 }, to: { x: 110, y: 60 }, steps: 5 });
    assert.match(r.text, /dragged on Canvas/);
    assert.match(r.text, /\+ - Text "1 strokes"/);
    const stroke = s.state().strokes[0];
    assert.equal(stroke.length, 6);
    assert.deepEqual(stroke[0], [10, 10]);
    assert.deepEqual(stroke[5], [110, 60]);
  } finally {
    await s.close();
  }
});

test("exceptions and broken servers are problems of the step that caused them", async () => {
  await withServer(async ({ url }) => {
    const s = await Session.open({ source: SDK + `
      App.create({ state: { x: null }, view: function (s, app) { return { type: "Column", children: [
        { type: "Button", props: { text: "Crash" }, events: { tap: app.handler("crash", function () { null.boom; }) } },
        { type: "Button", props: { text: "Server" }, events: { tap: "callServer" } },
        { type: "Button", props: { text: "Missing" }, events: { tap: "noSuchFunction" } },
      ] }; } });
      function callServer() { Aseman.fetch("api/boom").catch(function () {}); }`, server: url });
    try {
      let r = await s.run({ do: "tap", target: "Crash" });
      assert.equal(r.ok, false);
      assert.match(r.text, /\[exception\] the program threw TypeError: .*null.* — a bug, not a failed request/);
      assert.match(r.text, /\[app-error\] the app shows an error banner: .*null/);
      r = await s.run({ do: "tap", target: "Server" });
      assert.equal(r.ok, false);
      assert.match(r.text, /\[server\] the app's server answered GET \/api\/boom with HTTP 500: kaput/);
      r = await s.run({ do: "tap", target: "Missing" });
      assert.match(r.text, /"noSuchFunction", which is not a global function/);
    } finally {
      await s.close();
    }
  });
});

test("the screen size and theme change as on the client, and the app redraws", async () => {
  const s = await Session.open({ source: SDK + `
    App.create({ state: {}, view: function (s, app) { var v = Aseman.viewport(); var t = Aseman.env().theme.mode;
      return { type: "Text", props: { text: v.sizeClass + " " + v.width + " " + t } }; } });` });
  try {
    assert.match(s.snapshotText(), /Text "compact 360 light"/);
    const r = await s.run({ do: "env", viewport: "desk", theme: "dark" });
    assert.match(r.text, /\+ - Text "expanded 1280 dark"/);
  } finally {
    await s.close();
  }
});

test("a session saves as a scenario that replays, and coverage spans the scenarios", async () => {
  await withServer(async ({ url }) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "elpian-e2e-"));
    fs.mkdirSync(path.join(dir, "elpian", "e2e"), { recursive: true });
    fs.writeFileSync(path.join(dir, "elpian", "app.js"), SHOWCASE);
    const s = await Session.open({ dir, server: url });
    await s.run({ do: "tap", target: "New" });
    await s.run({ do: "type", target: "What needs doing?", text: "Water plants" });
    await s.run({ do: "tap", target: "Add task" });
    await s.run({ expect: { text: "Water plants", target: "Add task", exists: false } });
    const sc = s.scenario("add a task");
    await s.close();
    assert.deepEqual(sc.steps.map((x) => x.do || "expect"), ["select", "type", "tap", "expect"]);
    assert.deepEqual(sc.steps[1].target, { key: "draft" });
    fs.writeFileSync(path.join(dir, "elpian", "e2e", "add.json"), JSON.stringify(sc));
    // A scenario that fails: it expects what the app does not do.
    fs.writeFileSync(path.join(dir, "elpian", "e2e", "wrong.json"), JSON.stringify({ name: "wrong", steps: [{ do: "tap", target: "Insights" }, { expect: { text: "Revenue" } }] }));
    let run = await runScenarios([path.join(dir, "elpian", "e2e")], { dir, server: url });
    assert.equal(run.ok, false);
    assert.equal(run.results.find((r) => r.name === "add a task").ok, true, formatRun(run));
    const wrong = run.results.find((r) => r.name === "wrong");
    assert.equal(wrong.failedAt, 2);
    assert.match(formatRun(run), /✗ wrong \(wrong.json\), step 2[\s\S]*the screen shows "Revenue"[\s\S]*The screen now:/);
    assert.match(formatRun(run), /coverage: \d+ of \d+ control events used/);
    fs.rmSync(path.join(dir, "elpian", "e2e", "wrong.json"));
    run = await runScenarios([path.join(dir, "elpian", "e2e")], { dir, server: url });
    assert.equal(run.ok, true, formatRun(run));
    // The CLI exits 0 when every scenario passes, 1 otherwise.
    // (Not spawnSync: this process serves the app's server.)
    const cli = await runCli(["run", "--dir", dir, "--server", url]);
    assert.equal(cli.status, 0, cli.stdout + cli.stderr);
    assert.match(cli.stdout, /✓ add a task \(4 steps\)/);
    const none = await runCli(["run", path.join(dir, "nothing"), "--dir", dir, "--server", url]);
    assert.equal(none.status, 1);
    assert.match(none.stdout, /no scenarios found/);
    fs.rmSync(dir, { recursive: true });
  });
});

test("the driver's MCP server keeps sessions across tool calls", async () => {
  await withServer(async ({ url }) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "elpian-mcp-"));
    fs.mkdirSync(path.join(dir, "elpian"), { recursive: true });
    fs.writeFileSync(path.join(dir, "elpian", "app.js"), SHOWCASE);
    const child = spawn(process.execPath, [path.join(kit, "drive-mcp.mjs")], { cwd: dir, stdio: ["pipe", "pipe", "inherit"] });
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
    let id = 0;
    const call = async (name, args) => {
      const n = ++id;
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: n, method: "tools/call", params: { name, arguments: args } }) + "\n");
      for (let i = 0; i < 400 && !replies.has(n); i++) await new Promise((r) => setTimeout(r, 25));
      const m = replies.get(n);
      assert.ok(m, `no reply to ${name}`);
      return m.result;
    };
    try {
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params: {} }) + "\n");
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: "list", method: "tools/list" }) + "\n");
      for (let i = 0; i < 200 && !replies.has("list"); i++) await new Promise((r) => setTimeout(r, 25));
      assert.equal(replies.get(0).result.serverInfo.name, "aseman-elpian-driver");
      const names = replies.get("list").result.tools.map((t) => t.name);
      for (const n of ["elpian_open", "elpian_snapshot", "elpian_tap", "elpian_type", "elpian_select", "elpian_toggle", "elpian_gesture", "elpian_wait", "elpian_expect", "elpian_coverage", "elpian_save_scenario", "elpian_run_scenarios"]) assert.ok(names.includes(n), n);
      let r = await call("elpian_tap", { target: "New" });
      assert.equal(r.isError, true);
      assert.match(r.content[0].text, /call elpian_open first/);
      r = await call("elpian_open", { server: url });
      assert.match(r.content[0].text, /session "main" open: elpian\/app.js against http/);
      assert.match(r.content[0].text, /NavigationBar \[e\d+\]/);
      r = await call("elpian_tap", { target: "New" });
      assert.match(r.content[0].text, /went to "New"/);
      r = await call("elpian_type", { target: { key: "draft" }, text: "Call mom" });
      r = await call("elpian_tap", { target: "Add task" });
      assert.match(r.content[0].text, /POST \/api\/tasks → 200/);
      r = await call("elpian_expect", { text: "Call mom" });
      assert.match(r.content[0].text, /^✓ the screen shows "Call mom"/);
      r = await call("elpian_tap", { target: "Nope" });
      assert.equal(r.isError, true);
      r = await call("elpian_coverage", {});
      assert.match(r.content[0].text, /coverage: \d+ of \d+/);
      r = await call("elpian_save_scenario", { name: "Add a reminder" });
      assert.match(r.content[0].text, /saved elpian\/e2e\/add-a-reminder.json: 3 action\(s\), 1 expectation\(s\)/);
      r = await call("elpian_run_scenarios", {});
      assert.match(r.content[0].text, /✓ Add a reminder \(4 steps\)[\s\S]*1 scenario\(s\) passed/);
      r = await call("elpian_close", {});
      assert.match(r.content[0].text, /closed/);
    } finally {
      child.stdin.end();
      child.kill();
      fs.rmSync(dir, { recursive: true });
    }
  });
});

test("paths and subsets match the way scenarios write them", () => {
  assert.equal(pathMatches("api/tasks", "/api/tasks?x=1"), true);
  assert.equal(pathMatches("/api/tasks/*/toggle", "api/tasks/12/toggle"), true);
  assert.equal(pathMatches("api/tasks", "api/tasks/1"), false);
  assert.equal(pathMatches("re:^api/t", "api/tasks"), true);
  assert.equal(subset({ a: 1, b: [1, "2"] }, { a: "1", b: [1, 2], c: 3 }), true);
  assert.equal(subset({ a: { b: 1 } }, { a: { b: 2 } }), false);
});
