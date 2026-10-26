/**
 * Aseman OpenUI — agent-backed UI islands for OpenCode App UIs.
 *
 * Mix with programmed frontend/backend freely. Same theme tokens as the host
 * app (--md-sys-color-* / --aseman-* from DeskWeb). Load via:
 *   <link rel="stylesheet" href="_aseman/kit/openui/openui.css">
 *   <script type="module" src="_aseman/kit/openui/openui.js"></script>
 * or from vendor/aseman-openui/ after aseman-appui copies the kit.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.AsemanOpenUI = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const apiBase = () => new URL("_aseman/api/", location.href);

  async function apiJSON(op, { method = "GET", body } = {}) {
    const url = new URL(op, apiBase());
    const init = { method, headers: { Accept: "application/json" }, credentials: "same-origin" };
    if (body != null) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    const r = await fetch(url, init);
    const text = await r.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { error: text || r.statusText };
    }
    if (!r.ok) {
      const err = new Error((data && (data.error || data.message)) || r.statusText || "request failed");
      err.status = r.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  /** List space agents (kind=agent). */
  function agents() {
    return apiJSON("agents").then((d) => (d && d.agents) || []);
  }

  /** Ask a space agent. body: { agent|bot, prompt|body, history? } */
  function ask(opts) {
    const agent = opts.agent || opts.bot;
    const body = opts.prompt || opts.body || "";
    if (!agent) return Promise.reject(new Error("ask needs agent"));
    if (!String(body).trim()) return Promise.reject(new Error("ask needs prompt"));
    return apiJSON("ask", {
      method: "POST",
      body: { agent, bot: agent, body, history: opts.history || undefined },
    }).then((d) => ({
      reply: d.reply,
      bot_id: d.bot_id,
      agent: d.agent || d.bot_id,
    }));
  }

  /** Call a space app microtool (programmed backend path). */
  function call(opts) {
    const tool = opts.tool;
    const microtool = opts.microtool;
    if (!tool || !microtool) return Promise.reject(new Error("call needs tool + microtool"));
    return apiJSON("call", {
      method: "POST",
      body: { tool, microtool, args: opts.args || {} },
    }).then((d) => d.result);
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /** Minimal markdown → HTML (headings, bold, italic, code, links, lists). */
  function renderMarkdown(src) {
    if (src == null) return "";
    if (typeof src !== "string") {
      try {
        src = JSON.stringify(src, null, 2);
      } catch {
        src = String(src);
      }
    }
    let s = escapeHtml(src);
    s = s.replace(/```([\s\S]*?)```/g, (_, code) => `<pre><code>${code}</code></pre>`);
    s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
    s = s.replace(/^### (.+)$/gm, "<h3>$1</h3>");
    s = s.replace(/^## (.+)$/gm, "<h2>$1</h2>");
    s = s.replace(/^# (.+)$/gm, "<h1>$1</h1>");
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/\*([^*]+)\*/g, "<em>$1</em>");
    s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    s = s.replace(/^(?:- |\* )(.+)(?:\n(?:- |\* ).+)*/gm, (block) => {
      const items = block.split(/\n/).map((l) => `<li>${l.replace(/^(- |\* )/, "")}</li>`).join("");
      return `<ul>${items}</ul>`;
    });
    s = s.replace(/\n\n+/g, "</p><p>");
    if (!/^</.test(s.trim())) s = `<p>${s}</p>`;
    return s;
  }

  function interpolate(tpl, vars) {
    return String(tpl || "").replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, k) => {
      const v = vars && vars[k];
      return v == null ? "" : String(v);
    });
  }

  function readVars(el) {
    const raw = el.getAttribute("vars");
    if (raw) {
      try {
        return JSON.parse(raw);
      } catch {
        /* fall through */
      }
    }
    const out = {};
    for (const a of el.attributes) {
      if (a.name.startsWith("var-")) out[a.name.slice(4)] = a.value;
    }
    return out;
  }

  function kitURL(file) {
    try {
      return new URL(file, new URL("../kit/openui/", apiBase())).href;
    } catch {
      return file;
    }
  }

  function ensureStyles() {
    if (document.querySelector('link[data-aseman-openui], style[data-aseman-openui]')) return;
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = kitURL("openui.css");
    link.dataset.asemanOpenui = "1";
    document.head.appendChild(link);
  }

  function ensureCatalog() {
    if (globalThis.AsemanOpenUICatalog) return Promise.resolve(globalThis.AsemanOpenUICatalog);
    return new Promise((resolve, reject) => {
      const existing = document.querySelector("script[data-aseman-openui-catalog]");
      if (existing) {
        existing.addEventListener("load", () => resolve(globalThis.AsemanOpenUICatalog));
        existing.addEventListener("error", reject);
        return;
      }
      const s = document.createElement("script");
      s.src = kitURL("catalog.js");
      s.dataset.asemanOpenuiCatalog = "1";
      s.onload = () => resolve(globalThis.AsemanOpenUICatalog);
      s.onerror = () => reject(new Error("failed to load OpenUI catalog.js"));
      document.head.appendChild(s);
    });
  }

  async function paintContent(el, value) {
    try {
      const cat = await ensureCatalog();
      const tree = cat && cat.tryParseOpenUI(value);
      if (tree) {
        el.innerHTML = cat.render(tree);
        cat.enhance(el);
        return { kind: "openui", tree };
      }
    } catch {
      /* fall through to markdown */
    }
    el.innerHTML = renderMarkdown(value);
    return { kind: "markdown" };
  }

  class OpenPanel extends HTMLElement {
    static get observedAttributes() {
      return ["agent", "prompt", "autorun", "title"];
    }
    connectedCallback() {
      ensureStyles();
      if (!this._built) {
        this._built = true;
        this.innerHTML = `
          <div class="ou-head">
            <span class="ou-badge" data-kind="agent">Agent</span>
            <span class="ou-title"></span>
          </div>
          <div class="ou-body ou-empty">Ready</div>
          <div class="ou-foot"><button type="button" class="ou-run">Run</button></div>`;
        this.querySelector(".ou-run").addEventListener("click", () => this.run());
      }
      this._syncChrome();
      if (this.getAttribute("autorun") !== "false") this.run();
    }
    attributeChangedCallback() {
      if (this._built) {
        this._syncChrome();
        if (this.isConnected && this.getAttribute("autorun") !== "false") this.run();
      }
    }
    _syncChrome() {
      const title = this.getAttribute("title") || this.getAttribute("agent") || "OpenUI";
      const t = this.querySelector(".ou-title");
      if (t) t.textContent = title;
    }
    async run(extraVars) {
      const body = this.querySelector(".ou-body");
      const btn = this.querySelector(".ou-run");
      const agent = this.getAttribute("agent");
      const prompt = interpolate(this.getAttribute("prompt") || "", { ...readVars(this), ...(extraVars || {}) });
      if (!agent || !prompt.trim()) {
        body.className = "ou-body ou-empty";
        body.textContent = "Set agent and prompt.";
        return;
      }
      body.className = "ou-body ou-loading";
      body.textContent = "Thinking…";
      if (btn) btn.disabled = true;
      try {
        const { reply } = await ask({ agent, prompt });
        body.className = "ou-body";
        await paintContent(body, reply);
        this.dispatchEvent(new CustomEvent("aseman-openui:done", { detail: { reply, agent }, bubbles: true }));
      } catch (e) {
        body.className = "ou-body ou-error";
        body.textContent = e.message || String(e);
        this.dispatchEvent(new CustomEvent("aseman-openui:error", { detail: { error: e }, bubbles: true }));
      } finally {
        if (btn) btn.disabled = false;
      }
    }
  }

  class OpenQuery extends HTMLElement {
    static get observedAttributes() {
      return ["tool", "microtool", "args", "agent", "prompt", "autorun", "title"];
    }
    connectedCallback() {
      ensureStyles();
      if (!this._built) {
        this._built = true;
        this.innerHTML = `
          <div class="ou-head">
            <span class="ou-badge" data-kind="query">Data</span>
            <span class="ou-title"></span>
          </div>
          <div class="ou-body ou-empty">Ready</div>
          <div class="ou-foot"><button type="button" class="ou-run">Refresh</button></div>`;
        this.querySelector(".ou-run").addEventListener("click", () => this.run());
      }
      this._syncChrome();
      if (this.getAttribute("autorun") !== "false") this.run();
    }
    attributeChangedCallback() {
      if (this._built) {
        this._syncChrome();
        if (this.isConnected && this.getAttribute("autorun") !== "false") this.run();
      }
    }
    _syncChrome() {
      const title =
        this.getAttribute("title") ||
        this.getAttribute("microtool") ||
        this.getAttribute("agent") ||
        "Query";
      const t = this.querySelector(".ou-title");
      if (t) t.textContent = title;
      const badge = this.querySelector(".ou-badge");
      if (badge) {
        const agentic = !!(this.getAttribute("agent") && this.getAttribute("prompt"));
        badge.dataset.kind = agentic ? "agent" : "query";
        badge.textContent = agentic ? "Agent" : "Microtool";
      }
    }
    async run(extraVars) {
      const body = this.querySelector(".ou-body");
      const btn = this.querySelector(".ou-run");
      const vars = { ...readVars(this), ...(extraVars || {}) };
      body.className = "ou-body ou-loading";
      body.textContent = "Loading…";
      if (btn) btn.disabled = true;
      try {
        let result;
        const agent = this.getAttribute("agent");
        const promptTpl = this.getAttribute("prompt");
        if (agent && promptTpl) {
          result = (await ask({ agent, prompt: interpolate(promptTpl, vars) })).reply;
        } else {
          let args = {};
          const raw = this.getAttribute("args");
          if (raw) {
            try {
              args = JSON.parse(interpolate(raw, vars));
            } catch {
              args = {};
            }
          }
          result = await call({
            tool: this.getAttribute("tool"),
            microtool: this.getAttribute("microtool"),
            args,
          });
        }
        body.className = "ou-body";
        await paintContent(body, result);
        this.dispatchEvent(new CustomEvent("aseman-openui:done", { detail: { result }, bubbles: true }));
      } catch (e) {
        body.className = "ou-body ou-error";
        body.textContent = e.message || String(e);
      } finally {
        if (btn) btn.disabled = false;
      }
    }
  }

  class OpenAction extends HTMLElement {
    static get observedAttributes() {
      return ["agent", "prompt", "tool", "microtool", "args", "label", "variant"];
    }
    connectedCallback() {
      ensureStyles();
      if (!this._built) {
        this._built = true;
        const btn = document.createElement("button");
        btn.type = "button";
        btn.addEventListener("click", () => this.run());
        this.appendChild(btn);
        this._btn = btn;
      }
      this._sync();
    }
    attributeChangedCallback() {
      if (this._built) this._sync();
    }
    _sync() {
      if (!this._btn) return;
      this._btn.textContent =
        this.getAttribute("label") || this.textContent.trim() || "Run";
      this._btn.dataset.variant = this.getAttribute("variant") || "filled";
    }
    async run(extraVars) {
      const vars = { ...readVars(this), ...(extraVars || {}) };
      this._btn.disabled = true;
      try {
        let detail;
        const agent = this.getAttribute("agent");
        if (agent) {
          detail = await ask({
            agent,
            prompt: interpolate(this.getAttribute("prompt") || this.getAttribute("label") || "Go", vars),
          });
        } else {
          let args = {};
          const raw = this.getAttribute("args");
          if (raw) {
            try {
              args = JSON.parse(interpolate(raw, vars));
            } catch {
              args = {};
            }
          }
          detail = {
            result: await call({
              tool: this.getAttribute("tool"),
              microtool: this.getAttribute("microtool"),
              args,
            }),
          };
        }
        this.dispatchEvent(new CustomEvent("aseman-openui:done", { detail, bubbles: true }));
        const target = this.getAttribute("target");
        if (target) {
          const el = document.querySelector(target);
          if (el && typeof el.run === "function") el.run(vars);
          else if (el) {
            const body = el.querySelector?.(".ou-body") || el;
            const reply = detail.reply != null ? detail.reply : detail.result;
            await paintContent(body, reply);
          }
        }
        return detail;
      } catch (e) {
        this.dispatchEvent(new CustomEvent("aseman-openui:error", { detail: { error: e }, bubbles: true }));
        throw e;
      } finally {
        this._btn.disabled = false;
      }
    }
  }

  if (typeof customElements !== "undefined") {
    if (!customElements.get("aseman-open-panel")) customElements.define("aseman-open-panel", OpenPanel);
    if (!customElements.get("aseman-open-query")) customElements.define("aseman-open-query", OpenQuery);
    if (!customElements.get("aseman-open-action")) customElements.define("aseman-open-action", OpenAction);
  }

  return {
    agents,
    ask,
    call,
    renderMarkdown,
    interpolate,
    paintContent,
    ensureCatalog,
    mount: async (el, tree) => {
      const cat = await ensureCatalog();
      return cat.mount(el, tree);
    },
    render: async (tree) => {
      const cat = await ensureCatalog();
      return cat.render(tree);
    },
    components: async () => {
      const cat = await ensureCatalog();
      return cat.componentNames();
    },
    OpenPanel,
    OpenQuery,
    OpenAction,
    version: "1.1.0",
  };
});
