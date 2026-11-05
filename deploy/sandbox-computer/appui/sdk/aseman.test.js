// node --test deploy/sandbox-computer/appui/sdk/aseman.test.js
const test = require("node:test");
const assert = require("node:assert");

function load(pathname, respond) {
  const seen = [];
  globalThis.location = { origin: "https://node.example", pathname, href: "https://node.example" + pathname };
  globalThis.fetch = async (url, init) => {
    const body = init && init.body ? JSON.parse(init.body) : undefined;
    seen.push({ url: String(url), method: init.method, body });
    const [status, data] = respond(String(url), body);
    return { ok: status < 300, status, statusText: "x", json: async () => data };
  };
  delete require.cache[require.resolve("./aseman.js")];
  return { Aseman: require("./aseman.js"), seen };
}

test("calls go to the preview root from any route", async () => {
  const { Aseman, seen } = load("/v1/proxy/abc/orders/12", () => [200, { result: "Sunny" }]);
  assert.equal(await Aseman.call("weather", "forecast", { city: "Oslo" }), "Sunny");
  assert.equal(seen[0].url, "https://node.example/v1/proxy/abc/_aseman/api/call");
  assert.deepEqual(seen[0].body, { tool: "weather", microtool: "forecast", args: { city: "Oslo" } });
});

test("errors carry the gateway's message and status", async () => {
  const { Aseman } = load("/v1/proxy/abc/", () => [404, { error: "x is no agent of this space" }]);
  await assert.rejects(Aseman.ask("x", "hi"), (e) => e instanceof Aseman.Error && e.status === 404 && /no agent/.test(e.message));
});

test("a conversation sends its history with every ask", async () => {
  let n = 0;
  const { Aseman, seen } = load("/v1/proxy/abc/", () => [200, { reply: "r" + ++n }]);
  const chat = Aseman.conversation("assistant");
  assert.equal(await chat.send("one"), "r1");
  assert.equal(await chat.send("two"), "r2");
  assert.equal(seen[0].body.history, undefined);
  assert.deepEqual(seen[1].body.history, [{ role: "user", content: "one" }, { role: "assistant", content: "r1" }]);
});

test("askJSON parses fenced and bare JSON", async () => {
  const { Aseman } = load("/v1/proxy/abc/", () => [200, { reply: "Sure:\n```json\n{\"a\": [1, 2]}\n```" }]);
  assert.deepEqual(await Aseman.askJSON("analyst", "go", { rows: [] }), { a: [1, 2] });
  assert.deepEqual(Aseman.parseJSON('result: [1, {"b": 2}] done'), [1, { b: 2 }]);
  assert.throws(() => Aseman.parseJSON("no json here"), Aseman.Error);
});

test("a platform's frontend calls its own root and signs people in through the gateway", async () => {
  const { Aseman, seen } = load("/v1/platforms/acme/app/shop/1", (url) =>
    [200, url.includes("/_aseman/auth/") ? { user: { id: "u7", handle: "shopper" }, platform: { slug: "acme" } } : { reply: "hi" }]);
  await Aseman.ask("Advisor", "hello");
  assert.equal(seen[0].url, "https://node.example/v1/platforms/acme/app/_aseman/api/ask");
  const who = await Aseman.signIn("shopper", "pw");
  assert.equal(who.user.handle, "shopper");
  assert.equal(seen[1].url, "https://node.example/v1/platforms/acme/app/_aseman/auth/login");
  assert.deepEqual(seen[1].body, { account: "shopper", password: "pw" });
  await Aseman.me();
  assert.equal(seen[2].url, "https://node.example/v1/platforms/acme/app/_aseman/auth/me");
  assert.equal(seen[2].method, undefined);
});
