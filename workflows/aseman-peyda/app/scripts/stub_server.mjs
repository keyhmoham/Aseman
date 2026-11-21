#!/usr/bin/env node
// A stand-in for Peyda's server with canned answers, for developing and
// testing the Elpian frontend without GLiNER2, iran-mcp or the analyst:
//   node scripts/stub_server.mjs [port]      (default 8787)
//   STUB_DELAY_MS=3000 node scripts/stub_server.mjs   holds each search that long (to see the loading state)
// It serves elpian/app.js and the same /api shapes as peyda/api.py.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const port = Number(process.argv[2] || process.env.PORT || 8787);

const frame = { text: "x", domains: [{ name: "shopping", score: 0.9 }], intent: "cheapest", slots: { product: "گوشی", brand: "سامسونگ", price_max_toman: 20000000 }, assumptions: [] };
// Pictures are on img.peyda.test, which does not exist: a preview or a test serves them (or they fail, as a dead site's would).
const img = (n) => `https://img.peyda.test/${n}.jpg`;
const search = {
  frame, total: 9, score: 14.5, ms: 1812, gaps: [],
  services: [
    { id: "digikala", title: "Digikala", status: "ok", count: 3, ms: 900, reason: "", missing: [], hits: [
      { service: "digikala", tool: "dk_find_cheapest", title: "Samsung Galaxy A55 5G 256GB", url: "https://example.com/a55", price_toman: 18500000, detail: "Digikala seller · rating: 4.5", image: img("a55") },
      { service: "digikala", tool: "dk_find_cheapest", title: "Samsung Galaxy A35 128GB", url: "https://example.com/a35", price_toman: 14900000, detail: "Digikala seller · rating: 4.3", image: img("a35") },
      { service: "digikala", tool: "dk_find_cheapest", title: "Samsung Galaxy S24 FE", url: "https://example.com/s24", price_toman: 32400000, detail: "Official warranty", image: img("s24") }] },
    { id: "torob", title: "Torob", status: "ok", count: 3, ms: 600, reason: "", missing: [], hits: [
      { service: "torob", tool: "tb_cheapest", title: "Samsung Galaxy A25 128GB", url: "https://example.com/a25", price_toman: 11800000, detail: "from 12 shops", image: img("a25") },
      { service: "torob", tool: "tb_cheapest", title: "Samsung Galaxy A15", url: "https://example.com/a15", price_toman: 8900000, detail: "from 21 shops", image: img("a15") },
      { service: "torob", tool: "tb_cheapest", title: "Samsung Galaxy A06", url: "", price_toman: 5600000, detail: "from 9 shops" }] },
    { id: "technolife", title: "Technolife", status: "ok", count: 1, ms: 700, reason: "", missing: [], hits: [
      { service: "technolife", tool: "tl_find_cheapest", title: "Samsung Galaxy A55 5G", url: "https://example.com/tl-a55", price_toman: 18900000, detail: "18 months warranty", image: img("a55b") }] },
    { id: "gmaps", title: "Google Maps", status: "ok", count: 2, ms: 1800, reason: "", missing: [], hits: [
      { service: "gmaps", tool: "gm_search", title: "Samsung Store Valiasr", url: "https://www.google.com/maps/place/x", detail: "Electronics store · ★ 4.7 (1,204) · +98 21 2222 3333 · Open · Valiasr St, Tehran", image: img("store") },
      { service: "gmaps", tool: "gm_search", title: "Mobile Center Paytakht", url: "https://www.google.com/maps/place/y", detail: "Cell phone store · ★ 4.2 (380) · Paytakht Computer Complex, Tehran", image: img("mall") }] },
    { id: "emalls", title: "Emalls", status: "error", count: 0, ms: 3000, reason: "timed out", missing: [], hits: [] },
  ],
};
const runs = new Map();
const chats = [];

function send(res, code, body, type = "application/json") {
  res.writeHead(code, { "content-type": type });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}
function readBody(req) { return new Promise((r) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => r(b ? JSON.parse(b) : {})); }); }

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;
  if (p === "/" || p === "/healthz") return send(res, 200, p === "/" ? "<p>Peyda stub</p>" : { ok: true }, p === "/" ? "text/html" : undefined);
  if (p === "/elpian/app.js") {
    const f = path.join(root, "elpian", "app.js");
    return fs.existsSync(f) ? send(res, 200, fs.readFileSync(f, "utf8"), "application/javascript") : send(res, 503, { error: "not built" });
  }
  if (p === "/api/info") return send(res, 200, { platform: "Peyda", signed_in: !!req.headers["x-decillion-user-token"], services: 61, sites: ["Digikala"], extractor: { ready: true, engine: "gliner2" }, max_rounds: 3 });
  if (p === "/api/search") {
    await readBody(req);
    const delay = Number(process.env.STUB_DELAY_MS || 0);
    if (delay) await new Promise((r) => setTimeout(r, delay));
    return send(res, 200, search);
  }
  if (p === "/api/chats" && req.method === "GET") return send(res, 200, { chats });
  if (p === "/api/chats" && req.method === "POST") { const c = { id: "c" + (chats.length + 1), title: "New chat", messages: [] }; chats.push(c); return send(res, 200, c); }
  let m = p.match(/^\/api\/chats\/(\w+)\/messages$/);
  if (m) {
    const body = await readBody(req);
    const chat = chats.find((c) => c.id === m[1]);
    if (chat && chat.title === "New chat") chat.title = String(body.text || "").slice(0, 80); // as peyda/api.py does
    const id = "r" + runs.size;
    const answer = { id: "a" + id, role: "assistant", text: "The best value under 20 million Toman is the **Galaxy A55 5G** at Digikala (18,500,000 Toman); Technolife has it for 400,000 more with a longer warranty. If the budget is tighter, the **A25** starts at 11,800,000 Toman on Torob.", payload: { cards: [{ ...search.services[0].hits[0], ref: "digikala:0", source: "Digikala" }, { ...search.services[2].hits[0], ref: "technolife:0", source: "Technolife" }, { ...search.services[1].hits[0], ref: "torob:0", source: "Torob" }], suggestions: ["Only Samsung", "Cheaper?"], rounds: [{ n: 1, query: body.text, total: 3, reason: "" }], degraded: false } };
    runs.set(id, { answer, t: Date.now() });
    return send(res, 202, { run: id, message: { id: "u" + id, role: "user", text: body.text } });
  }
  m = p.match(/^\/api\/runs\/(\w+)$/);
  if (m) {
    const r = runs.get(m[1]);
    if (!r) return send(res, 404, { error: "No such run" });
    const after = Number(url.searchParams.get("after") || 0);
    const events = [{ i: 0, type: "stage", name: "extract", round: 1, query: "q" }, { i: 1, type: "service", round: 1, id: "digikala", title: "Digikala", status: "ok", count: 2, ms: 400, reason: "" }, { i: 2, type: "done" }];
    return send(res, 200, { id: m[1], status: "done", error: "", events: events.slice(after), next: events.length, message: r.answer });
  }
  m = p.match(/^\/api\/chats\/(\w+)$/);
  if (m) return send(res, 200, { id: m[1], title: "New chat", messages: [] });
  send(res, 404, { error: "not found" });
}).listen(port, "0.0.0.0", () => console.log("peyda stub on " + port));
