/*
 * Aseman server SDK: how an app's backend uses its space's agents and apps
 * (see ASEMAN_API.md, "From your server"). Node 18+ (global fetch).
 *
 *   const { Aseman } = require("./vendor/aseman-sdk/server.cjs");
 *   // Serving a request: act for (and bill) the person using the app.
 *   const aseman = Aseman.fromRequest(req);
 *   const { reply } = await aseman.ask("research", "Summarise …");
 *   // Work nobody is in front of: act for (and bill) the person who asked
 *   // for the app.
 *   const bg = Aseman.app();
 *
 * Settings come from the environment (ASEMAN_API_URL, ASEMAN_APP_KEY), else
 * from .aseman/server.env in the working directory, which Aseman writes.
 */
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const USER_TOKEN = "x-aseman-user-token";

class AsemanError extends Error {
  constructor(message, status, op) {
    super(message);
    this.name = "AsemanError";
    this.status = status || 0;
    this.op = op || "";
  }
}

let fileSettings;
function settings() {
  if (fileSettings === undefined) {
    fileSettings = {};
    try {
      const text = fs.readFileSync(path.join(process.cwd(), ".aseman", "server.env"), "utf8");
      for (const line of text.split(/\r?\n/)) {
        const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
        if (m) fileSettings[m[1]] = m[2].replace(/^["']|["']$/g, "");
      }
    } catch (_) { /* no file: environment only */ }
  }
  const get = (k) => process.env[k] || fileSettings[k] || "";
  return {
    url: get("ASEMAN_API_URL"), key: get("ASEMAN_APP_KEY"),
    devUrl: get("ASEMAN_DEVELOPER_API_URL"), devKey: get("ASEMAN_DEVELOPER_KEY"), platform: get("ASEMAN_PLATFORM"),
  };
}

function header(req, name) {
  if (!req || !req.headers) return "";
  const h = req.headers;
  if (typeof h.get === "function") return h.get(name) || ""; // Fetch Request
  const v = h[name] ?? h[name.toLowerCase()];
  return Array.isArray(v) ? v[0] : v || "";
}

// The sub-platform a request came through, when the app is a platform's
// frontend (X-Aseman-Platform*), else null.
function platformOf(req) {
  const slug = header(req, "x-aseman-platform");
  if (!slug) return null;
  return { slug, id: header(req, "x-aseman-platform-id"), name: header(req, "x-aseman-platform-name") };
}

function parseJSON(text) {
  if (text && typeof text === "object") return text;
  const s = String(text || "");
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(s);
  for (const c of [fenced && fenced[1], s]) {
    if (!c) continue;
    const start = c.search(/[[{]/);
    if (start < 0) continue;
    for (let end = c.length; end > start; end--) {
      const ch = c[end - 1];
      if (ch !== "}" && ch !== "]") continue;
      try { return JSON.parse(c.slice(start, end)); } catch (_) { /* shorter */ }
    }
  }
  throw new AsemanError("the agent's reply has no JSON", 0, "ask");
}

class Client {
  constructor(token, { url, user, platform } = {}) {
    if (!token) {
      throw new AsemanError(
        "no Aseman credential: serve a request from the Aseman preview (it carries X-Aseman-User-Token) or set ASEMAN_APP_KEY",
        401, "");
    }
    this.token = token;
    this.url = (url || settings().url || "").replace(/\/+$/, "");
    if (!this.url) throw new AsemanError("ASEMAN_API_URL is not set", 0, "");
    // Who the app is serving, when known. In a platform's frontend that is
    // the platform's person; the calls run as (and bill) the frontend's
    // publisher, and reach only the agents and apps the app is wired to.
    this.user = user || null;
    this.platform = platform || null;
  }

  async request(op, { method = "GET", body, query, timeoutMs = 120000, signal } = {}) {
    const url = new URL(this.url + "/" + op);
    if (query) for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== null) url.searchParams.set(k, typeof v === "string" ? v : JSON.stringify(v));
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(new AsemanError(op + " timed out", 504, op)), timeoutMs);
    if (signal) {
      if (signal.aborted) ctrl.abort(signal.reason);
      else signal.addEventListener("abort", () => ctrl.abort(signal.reason), { once: true });
    }
    let res;
    try {
      res = await fetch(url, {
        method,
        headers: { Authorization: "Bearer " + this.token, ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: ctrl.signal,
      });
    } catch (err) {
      if (ctrl.signal.reason instanceof AsemanError) throw ctrl.signal.reason;
      throw new AsemanError((err && err.message) || "network error", 0, op);
    } finally {
      clearTimeout(timer);
    }
    let data = null;
    try { data = await res.json(); } catch (_) { /* not JSON */ }
    if (!res.ok) throw new AsemanError((data && (data.error || data.message)) || res.statusText || "request failed", res.status, op);
    return data;
  }

  context(opts) { return this.request("context", opts); }
  async tools(opts) { return (await this.request("tools", opts)).tools || []; }
  async microtools(tool, opts = {}) { return (await this.request("microtools", { ...opts, query: { tool } })).microtools || []; }
  async agents(opts) { return (await this.request("agents", opts)).agents || []; }

  // A space app's microtool; resolves to the unwrapped result (often text).
  async call(tool, microtool, args = {}, opts = {}) {
    return (await this.request("call", { ...opts, method: "POST", body: { tool, microtool, args } })).result;
  }

  // Asks a space agent: a fresh, isolated conversation (a temporary thread
  // deleted when it answers); pass opts.history for earlier turns.
  ask(agent, prompt, opts = {}) {
    const body = { agent, prompt };
    if (opts.history && opts.history.length) body.history = opts.history;
    return this.request("ask", { timeoutMs: 360000, ...opts, method: "POST", body });
  }

  async askJSON(agent, prompt, data, opts = {}) {
    const text = prompt + (data !== undefined ? "\n\nData (JSON):\n" + JSON.stringify(data) : "") +
      "\n\nAnswer only with JSON, no prose.";
    return parseJSON((await this.ask(agent, text, opts)).reply);
  }
}

// The developer API of the person's organization (DEVELOPER.md), for the
// app's server only: models and chat (OpenAI-shaped), and the platform
// collection — the platform's own product surface, as the person.
class Developer {
  constructor({ url, key, platform } = {}) {
    const s = settings();
    this.url = (url || s.devUrl || "").replace(/\/+$/, "");
    this.key = key || s.devKey;
    this.platformSlug = platform || s.platform || "";
    if (!this.key || !this.url) {
      throw new AsemanError("no developer API access: ask for app_developer_access (ASEMAN_DEVELOPER_KEY, ASEMAN_DEVELOPER_API_URL)", 401, "developer");
    }
  }

  async request(path, { method = "GET", body, timeoutMs = 120000, signal } = {}) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(new AsemanError(path + " timed out", 504, path)), timeoutMs);
    if (signal) signal.addEventListener("abort", () => ctrl.abort(signal.reason), { once: true });
    let res;
    try {
      res = await fetch(this.url + "/" + path.replace(/^\/+/, ""), {
        method,
        headers: { Authorization: "Bearer " + this.key, ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: ctrl.signal,
      });
    } catch (err) {
      if (ctrl.signal.reason instanceof AsemanError) throw ctrl.signal.reason;
      throw new AsemanError((err && err.message) || "network error", 0, path);
    } finally {
      clearTimeout(timer);
    }
    let data = null;
    try { data = await res.json(); } catch (_) { /* not JSON */ }
    if (!res.ok) {
      const e = data && data.error;
      throw new AsemanError((e && (e.message || e)) || res.statusText || "request failed", res.status, path);
    }
    return data;
  }

  models(opts) { return this.request("models", opts); }
  // OpenAI-shaped chat completion: {model, messages, …}.
  chat(body, opts = {}) { return this.request("chat/completions", { ...opts, method: "POST", body }); }
  // The platform collection: any non-admin product action, as the person.
  platform(namespace, action, body = {}, opts = {}) {
    return this.request("platform/" + namespace + "/" + action, { ...opts, method: "POST", body });
  }
  catalog(opts) { return this.request("platform", opts); }
}

const Aseman = {
  Error: AsemanError,
  Client,
  Developer,
  // The organization's developer API (server only; see DEVELOPER.md).
  developer: (opts) => new Developer(opts),
  parseJSON,

  // Acts for the person whose request [req] is (Node http, Express, Fastify
  // or a Fetch Request): their token came with it from the Aseman gateway.
  // Calls are billed to that person — in a platform's frontend, to the
  // person who published it, for the platform's person.
  fromRequest(req, opts = {}) {
    const user = header(req, "x-aseman-user");
    return new Client(header(req, USER_TOKEN), {
      url: header(req, "x-aseman-api") || opts.url,
      user: user ? { id: user, handle: header(req, "x-aseman-user-handle") } : null,
      platform: platformOf(req),
    });
  },

  // The sub-platform [req] came through ({slug, id, name}), or null when the
  // app is not serving as a platform's frontend.
  platform: platformOf,

  // Acts with the app's key, for work nobody is in front of. Calls are billed
  // to the person who asked for the app.
  app(opts = {}) {
    return new Client(opts.key || settings().key, { url: opts.url });
  },

  // Whether a request came through the Aseman gateway with a person.
  hasUser: (req) => Boolean(header(req, USER_TOKEN)),

  // Express/Connect middleware: req.aseman acts for the person using the app
  // (absent for a visitor who has not signed in); req.asemanPlatform is the
  // sub-platform the request came through, if any.
  middleware(opts = {}) {
    return (req, _res, next) => {
      req.asemanPlatform = platformOf(req);
      if (Aseman.hasUser(req)) req.aseman = Aseman.fromRequest(req, opts);
      next();
    };
  },
};

module.exports = { Aseman, AsemanError, Client, Developer };
module.exports.default = Aseman;
