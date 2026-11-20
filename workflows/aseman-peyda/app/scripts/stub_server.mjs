#!/usr/bin/env node
// A stand-in for Peyda's server with canned answers, for developing and
// testing the Elpian frontend without GLiNER2, iran-mcp or the analyst:
//   node scripts/stub_server.mjs [port]      (default 8787)
// It serves elpian/app.js and the same /api shapes as peyda/api.py.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const port = Number(process.argv[2] || process.env.PORT || 8787);

const frame = { text: "x", domains: [{ name: "shopping", score: 0.9 }], intent: "cheapest", slots: { product: "گوشی", brand: "سامسونگ", price_max_toman: 20000000 }, assumptions: [] };
const search = {
  frame, total: 3, score: 9.5, ms: 812, gaps: [],
  services: [
    { id: "digikala", title: "Digikala", status: "ok", count: 2, ms: 400, reason: "", missing: [], hits: [
      { service: "digikala", tool: "dk_find_cheapest", title: "Samsung Galaxy A55", url: "https://example.com/a55", price_toman: 18500000, detail: "Digikala seller · 4.5" },
      { service: "digikala", tool: "dk_find_cheapest", title: "Samsung Galaxy A35", url: "https://example.com/a35", price_toman: 14900000, detail: "" }] },
    { id: "torob", title: "Torob", status: "ok", count: 1, ms: 600, reason: "", missing: [], hits: [
      { service: "torob", tool: "tb_cheapest", title: "Samsung Galaxy A25", url: "", price_toman: 11800000, detail: "from 12 shops" }] },
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
  if (p === "/api/search") { await readBody(req); return send(res, 200, search); }
  if (p === "/api/chats" && req.method === "GET") return send(res, 200, { chats });
  if (p === "/api/chats" && req.method === "POST") { const c = { id: "c" + (chats.length + 1), title: "New chat", messages: [] }; chats.push(c); return send(res, 200, c); }
  let m = p.match(/^\/api\/chats\/(\w+)\/messages$/);
  if (m) {
    const body = await readBody(req);
    const id = "r" + runs.size;
    const answer = { id: "a" + id, role: "assistant", text: "I found **3** phones under 20 million Toman.", payload: { cards: [{ ...search.services[0].hits[0], ref: "digikala:0", source: "Digikala" }], suggestions: ["Only Samsung", "Cheaper?"], rounds: [{ n: 1, query: body.text, total: 3, reason: "" }], degraded: false } };
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
