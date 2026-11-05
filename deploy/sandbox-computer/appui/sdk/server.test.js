// node --test deploy/sandbox-computer/appui/sdk/server.test.js
const test = require("node:test");
const assert = require("node:assert");
const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

function fakeNode() {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      seen.push({ url: req.url, method: req.method, auth: req.headers.authorization, body: body ? JSON.parse(body) : undefined });
      if (req.headers.authorization === "Bearer bad") {
        res.writeHead(401, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: "invalid app user token" }));
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      if (req.url.startsWith("/appapi/v1/ask")) return res.end(JSON.stringify({ reply: '```json\n{"ok":true}\n```' }));
      res.end(JSON.stringify({ result: "Sunny" }));
    });
  });
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r({ server, seen, url: `http://127.0.0.1:${server.address().port}/appapi/v1` })));
}

test("a request's person is who the server acts for", async () => {
  const { server, seen, url } = await fakeNode();
  const { Aseman } = require("./server.cjs");
  const req = { headers: { "x-aseman-user-token": "tok-ann", "x-aseman-user": "u1", "x-aseman-user-handle": "ann", "x-aseman-api": url } };
  const a = Aseman.fromRequest(req);
  assert.deepEqual(a.user, { id: "u1", handle: "ann" });
  assert.equal(await a.call("weather", "forecast", { city: "Oslo" }), "Sunny");
  assert.deepEqual(await a.askJSON("analyst", "go", { rows: [] }), { ok: true });
  assert.equal(seen[0].auth, "Bearer tok-ann");
  assert.equal(seen[0].url, "/appapi/v1/call");
  assert.deepEqual(seen[1].body.agent, "analyst");
  const bad = Aseman.fromRequest({ headers: { "x-aseman-user-token": "bad", "x-aseman-api": url } });
  await assert.rejects(bad.agents(), (e) => e instanceof Aseman.Error && e.status === 401);
  assert.throws(() => Aseman.fromRequest({ headers: {} }), Aseman.Error);
  server.close();
});

test("background work uses the app key from .aseman/server.env", async () => {
  const { server, seen, url } = await fakeNode();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "app-"));
  fs.mkdirSync(path.join(dir, ".aseman"));
  fs.writeFileSync(path.join(dir, ".aseman", "server.env"), `# x\nASEMAN_API_URL=${url}\nASEMAN_APP_KEY=aak_1.s3cret\n`);
  const cwd = process.cwd();
  process.chdir(dir);
  try {
    delete require.cache[require.resolve("./server.cjs")];
    const { Aseman } = require(path.join(__dirname, "server.cjs"));
    await Aseman.app().ask("research", "nightly");
    assert.equal(seen[0].auth, "Bearer aak_1.s3cret");
    assert.equal(seen[0].body.prompt, "nightly");
  } finally {
    process.chdir(cwd);
    server.close();
  }
});

test("the ES module entry exposes the same SDK", async () => {
  const mod = await import("./server.mjs");
  assert.equal(typeof mod.Aseman.fromRequest, "function");
  assert.equal(mod.default, mod.Aseman);
});

test("a platform frontend's request carries its platform; visitors have no person", async () => {
  const { Aseman } = require("./server.cjs");
  const headers = {
    "x-aseman-user-token": "pf-token", "x-aseman-user": "u1", "x-aseman-user-handle": "shopper",
    "x-aseman-api": "http://aseman:8080/appapi/v1",
    "x-aseman-platform": "acme", "x-aseman-platform-id": "pf1", "x-aseman-platform-name": "Acme",
  };
  const client = Aseman.fromRequest({ headers });
  assert.deepStrictEqual(client.platform, { slug: "acme", id: "pf1", name: "Acme" });
  assert.strictEqual(client.user.handle, "shopper");
  const visitor = { headers: { "x-aseman-platform": "acme", "x-aseman-platform-id": "pf1", "x-aseman-platform-name": "Acme" } };
  const req = { ...visitor };
  Aseman.middleware()(req, {}, () => {});
  assert.strictEqual(req.aseman, undefined);
  assert.strictEqual(req.asemanPlatform.slug, "acme");
  assert.strictEqual(Aseman.platform({ headers: {} }), null);
  assert.throws(() => Aseman.fromRequest(visitor), /no Aseman credential/);
});
