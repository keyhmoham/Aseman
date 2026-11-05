// node --test deploy/sandbox-computer/appui/test/wiring-check.test.mjs
import test from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { checkWiring } from "../wiring-check.mjs";

const APPS = {
  apps: [{ bot_id: "t1", name: "Weather", microtools: [{ name: "forecast" }, { name: "now" }] }],
  agents: [{ id: "a1", name: "Research" }],
};

function project(files, apps = APPS, job = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wiring-"));
  fs.writeFileSync(path.join(dir, "APPS.json"), JSON.stringify(apps));
  fs.writeFileSync(path.join(dir, "JOB.json"), JSON.stringify(job));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  return dir;
}

test("an app wired to its space's agents and apps passes", () => {
  const dir = project({
    "server.js": `app.post("/api/brief", async (req, res) => {
      const { reply } = await req.aseman.ask("research", "Summarise " + req.body.text);
      const f = await Aseman.fromRequest(req).call("Weather", "forecast", { city: "Oslo" });
      res.json({ reply, f });
    });`,
    "elpian/src/app.js": `OpenUI.panel({ agent: "Research", prompt: "Brief" }); Aseman.call("t1", "now", {});`,
    "app.py": `aseman.ask("a1", "hi")\naseman.call("weather", "forecast", {"city": "Oslo"})`,
    "public/index.html": `<aseman-open-panel agent="Research" prompt="x"></aseman-open-panel>`,
    // Tests, vendor and builds are not the app's wiring.
    "test/server.test.js": `ask("Imaginary", "x")`,
    "vendor/aseman-sdk/aseman.js": `ask("assistant", "x")`,
    "elpian/app.js": `ask("Bundled", "x")`,
  });
  const res = checkWiring(dir);
  assert.deepStrictEqual(res.problems, []);
  assert.ok(res.ok);
  assert.deepStrictEqual(res.used.agents, ["Research"]);
  assert.deepStrictEqual(res.used.apps, ["Weather"]);
});

test("made-up agents, apps and microtools are refused", () => {
  const dir = project({
    "server.js": `await req.aseman.ask("Analyst", "x");
      await req.aseman.call("Stocks", "quote", {});
      await req.aseman.call("Weather", "radar", {});
      fetch("_aseman/api/ask", { body: JSON.stringify({ agent: "Helper", prompt: "x" }) });`,
  });
  const res = checkWiring(dir);
  assert.equal(res.ok, false);
  const all = res.problems.join("\n");
  assert.match(all, /agent "Analyst".*APPS\.json lists: Research/);
  assert.match(all, /app "Stocks"/);
  assert.match(all, /microtool "radar" of Weather.*forecast, now/);
  assert.match(all, /agent "Helper"/);
});

test("a server imitating the gateway's Aseman API is refused", () => {
  const dir = project({
    "server.js": `app.post("/_aseman/api/ask", (req, res) => res.json({ reply: "Sure! Here is a summary." }));`,
    "main.py": `@app.post("/_aseman/api/call")\ndef fake(): return {"result": "sunny"}`,
  });
  const res = checkWiring(dir);
  assert.equal(res.ok, false);
  assert.equal(res.problems.length, 2);
  assert.match(res.problems[0], /stands in for them/);
});

test("templated names are left to the runtime; direct model calls and unused wiring warn", () => {
  const dir = project({
    "server.js": "const who = req.body.agent; await req.aseman.ask(`${who}`, 'x');\n" +
      "await fetch(process.env.ASEMAN_LLM_BASE_URL + '/chat/completions');",
  }, { ...APPS, narrowed: true });
  const res = checkWiring(dir);
  assert.ok(res.ok, res.problems.join("\n"));
  assert.ok(res.warnings.some((w) => /calls a model directly/.test(w)));
  assert.ok(res.warnings.some((w) => /agent Research was wired .* never asks/.test(w)));
  assert.ok(res.warnings.some((w) => /app Weather was wired .* never calls/.test(w)));
});

test("a platform frontend serving people with the app key is warned", () => {
  const dir = project({
    "server.js": `app.get("/api/x", async (req, res) => res.json(await Aseman.app().ask("Research", "x")));`,
  }, APPS, { audience: "platform" });
  const res = checkWiring(dir);
  assert.ok(res.ok);
  assert.ok(res.warnings.some((w) => /request's token/.test(w)));
});

test("a page calling the Aseman API is not a fake gateway", () => {
  const dir = project({
    "public/app.js": `axios.post("_aseman/api/ask", { agent: "Research", prompt: "x" });
      fetch(new URL("_aseman/api/call", location.href), { method: "POST" });`,
  });
  const res = checkWiring(dir);
  assert.deepStrictEqual(res.problems, []);
});

test("the developer key stays on the server", () => {
  const dir = project({
    "server.js": `const dev = Aseman.developer(); app.post("/api/space", async (req, res) => res.json(await dev.platform("spaces", "space_create", req.body)));`,
    "public/app.js": `fetch("/dev/v1/platform/spaces/space_create", { headers: { Authorization: "Bearer " + window.ASEMAN_DEVELOPER_KEY } });`,
    "lib/config.js": `export const KEY = "dk_live_abcdefghijklmnop";`,
  });
  const res = checkWiring(dir);
  assert.equal(res.ok, false);
  assert.equal(res.problems.length, 2, res.problems.join("\n"));
  assert.match(res.problems.join("\n"), /page code uses the server's credentials/);
  assert.match(res.problems.join("\n"), /credential is written into the source/);
});
