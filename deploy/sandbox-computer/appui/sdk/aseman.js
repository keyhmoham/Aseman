/*
 * Aseman page SDK: how an App UI talks to its space (see ASEMAN_API.md).
 * Classic script; sets globalThis.Aseman (also usable after a module import).
 * Calls go to the preview gateway's `_aseman/api/*`, as the viewing person.
 */
(function (root) {
  "use strict";

  class AsemanError extends Error {
    constructor(message, status, op) {
      super(message);
      this.name = "AsemanError";
      this.status = status || 0;
      this.op = op || "";
    }
  }

  // The preview's root (".../v1/proxy/<id>/"), so calls work from any route
  // of the app, not only from its first page.
  function apiBase() {
    const loc = root.location || { href: "http://localhost/", pathname: "/" };
    const m = /^(.*?\/v1\/proxy\/[^/]+\/)/.exec(loc.pathname || "");
    const origin = loc.origin || "";
    if (m) return origin + m[1] + "_aseman/api/";
    const base = (root.document && root.document.baseURI) || loc.href;
    return new URL("_aseman/api/", base).toString();
  }

  async function request(op, { method = "GET", body, query, timeoutMs = 120000, signal } = {}) {
    const url = new URL(op, apiBase());
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
        credentials: "same-origin",
        headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: ctrl.signal,
      });
    } catch (err) {
      if (err instanceof AsemanError) throw err;
      if (ctrl.signal.reason instanceof AsemanError) throw ctrl.signal.reason;
      throw new AsemanError((err && err.message) || "network error", 0, op);
    } finally {
      clearTimeout(timer);
    }
    let data = null;
    try { data = await res.json(); } catch (_) { /* not JSON */ }
    if (!res.ok) {
      throw new AsemanError((data && (data.error || data.message)) || res.statusText || "request failed", res.status, op);
    }
    return data;
  }

  // Pulls the first JSON value out of a reply (fenced ```json or bare).
  function parseJSON(text) {
    if (text && typeof text === "object") return text;
    const s = String(text || "");
    const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(s);
    const candidates = [fenced && fenced[1], s];
    for (const c of candidates) {
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

  const Aseman = {
    Error: AsemanError,
    apiBase,
    context: (opts) => request("context", opts),
    tools: async (opts) => (await request("tools", opts)).tools || [],
    microtools: async (tool, opts) => (await request("microtools", { ...opts, query: { tool } })).microtools || [],
    agents: async (opts) => (await request("agents", opts)).agents || [],

    // Calls a space app's microtool; resolves to the unwrapped result
    // (often a text/markdown string, sometimes an object).
    async call(tool, microtool, args = {}, opts = {}) {
      const out = await request("call", { ...opts, method: "POST", body: { tool, microtool, args } });
      return out.result;
    },

    // Asks a space agent. Each ask is a fresh, isolated conversation (a
    // temporary thread deleted when the agent is done); pass opts.history
    // ([{role, content}]) to carry earlier turns.
    async ask(agent, prompt, opts = {}) {
      const body = { agent, prompt };
      if (opts.history && opts.history.length) body.history = opts.history;
      return request("ask", { timeoutMs: 360000, ...opts, method: "POST", body });
    },

    // Asks for structured output and parses it. [data] is appended as JSON.
    async askJSON(agent, prompt, data, opts = {}) {
      const text = prompt + (data !== undefined ? "\n\nData (JSON):\n" + JSON.stringify(data) : "") +
        "\n\nAnswer only with JSON, no prose.";
      const { reply } = await Aseman.ask(agent, text, opts);
      return parseJSON(reply);
    },

    // A multi-turn conversation with one agent, kept in the page.
    conversation(agent, { history = [] } = {}) {
      const turns = history.slice();
      return {
        get history() { return turns.slice(); },
        reset() { turns.length = 0; },
        async send(prompt, opts = {}) {
          const { reply } = await Aseman.ask(agent, prompt, { ...opts, history: turns });
          turns.push({ role: "user", content: prompt }, { role: "assistant", content: reply });
          return reply;
        },
      };
    },

    // Opens a space tool's frontend as a window on the room's desk.
    show: (tool, { microtool, args, title, rect } = {}, opts) =>
      request("show", { ...opts, method: "POST", body: { tool, microtool, args, title, rect } }),

    parseJSON,
  };

  root.Aseman = Aseman;
  if (typeof module !== "undefined" && module.exports) module.exports = Aseman;
})(typeof globalThis !== "undefined" ? globalThis : this);
