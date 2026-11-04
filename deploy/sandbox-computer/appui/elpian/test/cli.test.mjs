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

const here = path.dirname(fileURLToPath(import.meta.url));
const kit = path.resolve(here, "..");
const SHOWCASE = [...["aseman-elpian.js", "openui-elpian.js"].map((f) => fs.readFileSync(path.join(kit, f), "utf8")),
  fs.readFileSync(path.join(kit, "examples", "showcase.js"), "utf8")].join("\n;\n");

function tasksServer() {
  const tasks = [{ id: 1, title: "Write spec", owner: "ana", due: "today", done: false, priority: "high" }];
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      if (req.url === "/api/tasks" && req.method === "POST") tasks.push({ id: tasks.length + 1, done: false, due: "today", ...JSON.parse(body) });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ tasks }));
    });
  });
  return new Promise((r) => srv.listen(0, "127.0.0.1", () => r({ srv, url: `http://127.0.0.1:${srv.address().port}` })));
}

// One aseman-elpian command, as an agent runs it on the sandbox shell.
function cli(dir, ...args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(kit, "elpian-cli.mjs"), ...args, "--dir", dir]);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

test("aseman-elpian lists the same tools its MCP servers serve", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "elpian-cli-"));
  try {
    const r = await cli(dir, "tools");
    assert.equal(r.status, 0, r.stderr);
    for (const n of ["elpian_validate", "elpian_validate_program", "elpian_describe", "elpian_icons", "elpian_open", "elpian_tap",
      "elpian_expect", "elpian_mock", "elpian_coverage", "elpian_save_scenario", "elpian_run_scenarios", "elpian_close"]) {
      assert.match(r.stdout, new RegExp(`\\b${n}\\b`), n);
    }
    const one = await cli(dir, "tools", "elpian_type");
    assert.match(one.stdout, /arguments \(JSON schema\)/);
    const d = await cli(dir, "elpian_describe", '{"types":["Button"]}');
    assert.equal(d.status, 0, d.stderr);
    assert.match(d.stdout, /Button/);
    const bad = await cli(dir, "elpian_validate", '{"tree":{"type":"NoSuchNode"}}');
    assert.equal(bad.status, 0);
    assert.match(bad.stdout, /NoSuchNode/);
    const unknown = await cli(dir, "elpian_nope", "{}");
    assert.equal(unknown.status, 2);
  } finally {
    fs.rmSync(dir, { recursive: true });
  }
});

test("driver sessions persist between aseman-elpian commands", async () => {
  const { srv, url } = await tasksServer();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "elpian-cli-"));
  fs.mkdirSync(path.join(dir, "elpian"), { recursive: true });
  fs.writeFileSync(path.join(dir, "elpian", "app.js"), SHOWCASE);
  try {
    let r = await cli(dir, "elpian_tap", '{"target":"New"}');
    assert.equal(r.status, 1, "no session yet");
    assert.match(r.stdout, /call elpian_open first/);
    r = await cli(dir, "elpian_open", JSON.stringify({ server: url }));
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /session "main" open: elpian\/app.js against http/);
    r = await cli(dir, "elpian_tap", '{"target":"New"}');
    assert.match(r.stdout, /went to "New"/);
    r = await cli(dir, "elpian_type", '{"target":{"key":"draft"},"text":"Call mom"}');
    assert.equal(r.status, 0, r.stdout);
    fs.writeFileSync(path.join(dir, "tap.json"), '{"target":"Add task"}');
    r = await cli(dir, "elpian_tap", "@" + path.join(dir, "tap.json"));
    assert.match(r.stdout, /POST \/api\/tasks → 200/);
    r = await cli(dir, "elpian_expect", '{"text":"Call mom"}');
    assert.match(r.stdout, /✓ the screen shows "Call mom"/);
    r = await cli(dir, "elpian_save_scenario", '{"name":"Add a reminder"}');
    assert.match(r.stdout, /saved elpian\/e2e\/add-a-reminder.json/);
    assert.ok(fs.existsSync(path.join(dir, "elpian", "e2e", "add-a-reminder.json")));
    r = await cli(dir, "elpian_run_scenarios", "{}");
    assert.match(r.stdout, /1 scenario\(s\) passed/);
  } finally {
    const s = await cli(dir, "stop");
    assert.match(s.stdout, /driver stopped/);
    srv.close();
    fs.rmSync(dir, { recursive: true });
  }
});
