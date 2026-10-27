/*
 * Aseman Elpian SDK: what an Elpian App UI program uses to render, react to
 * people, and reach its space (agents, apps) and its own server. Runs on the
 * Elpian QuickJS runtime the Aseman client hosts (no DOM, no fetch, no
 * modules). See ELPIAN.md.
 *
 *   App.create({ state, view(state, app), init(app), widget })  render loop
 *     widget: the phone-board widget, {view(state, app), refresh(app), size,
 *     shape, refreshMs} (or just a view function): drawn instead of `view`
 *     when the app is shown as a widget, its live data refreshed on a timer
 *   app.set(patch) / app.render() / app.handler(key, fn) / app.input(key, field)
 *   Aseman.ask / askJSON / conversation / call / agents / tools / microtools /
 *     context / fetch (the app's own server) / env / compact / expand
 *
 * Every request is asynchronous: it returns a Task (then / catch / finally),
 * settled when the host answers, so the screen never freezes on a long agent
 * ask. Host protocol (the client and `check.mjs` implement it):
 *   askHost('render', treeJSON)
 *   askHost('aseman.env', '')                    -> {display, theme, user, ...}
 *   askHost('aseman.request', requestJSON)       -> {accepted}; later the host
 *     calls __asemanSettle({id, ok, status, data, error})
 *   askHost('aseman.compact', summaryJSON) / askHost('aseman.expand', '')
 *   host -> __asemanEnv(env) when the theme or display changes
 */
(function (root) {
  "use strict";

  // ── host values ──────────────────────────────────────────────────────────

  // askHost answers with the VM's typed value ({type, data: {value}}),
  // sometimes as a JSON string: unwrap to plain JSON.
  function hostValue(raw) {
    var v = raw;
    if (typeof v === "string") {
      try {
        v = JSON.parse(v);
      } catch (e) {
        return raw;
      }
    }
    return plain(v);
  }

  // Event payloads and host replies arrive as typed values: plain JSON out.
  function plain(v) {
    if (v === null || v === undefined || typeof v !== "object") return v;
    if (typeof v.type === "string" && v.data && typeof v.data === "object" && "value" in v.data) {
      return plain(v.data.value);
    }
    if (Array.isArray(v)) return v.map(plain);
    var out = {};
    for (var k in v) {
      if (Object.prototype.hasOwnProperty.call(v, k)) out[k] = plain(v[k]);
    }
    return out;
  }

  function ask(api, payload) {
    if (typeof root.askHost !== "function") throw new Error("not running on the Elpian host (askHost missing)");
    return hostValue(root.askHost(api, payload));
  }

  function log() {
    var text = Array.prototype.map.call(arguments, function (a) {
      return typeof a === "string" ? a : safeStringify(a);
    }).join(" ");
    try {
      root.askHost("println", text);
    } catch (e) {
      /* no host log */
    }
  }

  function safeStringify(v) {
    try {
      return JSON.stringify(v);
    } catch (e) {
      return String(v);
    }
  }

  // ── Task: a promise that does not depend on the engine's job queue ───────

  function Task() {
    this.state = "pending";
    this.value = undefined;
    this.handlers = [];
  }
  Task.prototype._settle = function (state, value) {
    if (this.state !== "pending") return;
    this.state = state;
    this.value = value;
    var hs = this.handlers;
    this.handlers = [];
    for (var i = 0; i < hs.length; i++) this._run(hs[i]);
  };
  Task.prototype._run = function (h) {
    var cb = this.state === "fulfilled" ? h.ok : h.fail;
    if (!cb) {
      h.next._settle(this.state, this.value);
      return;
    }
    try {
      var out = cb(this.value);
      if (out && typeof out.then === "function") {
        out.then(function (v) { h.next._settle("fulfilled", v); }, function (e) { h.next._settle("rejected", e); });
      } else {
        h.next._settle("fulfilled", out);
      }
    } catch (e) {
      h.next._settle("rejected", e);
    }
  };
  Task.prototype.then = function (ok, fail) {
    var next = new Task();
    var h = { ok: ok, fail: fail, next: next };
    if (this.state === "pending") this.handlers.push(h);
    else this._run(h);
    return next;
  };
  Task.prototype.catch = function (fail) {
    return this.then(null, fail);
  };
  Task.prototype.finally = function (fn) {
    return this.then(function (v) { fn(); return v; }, function (e) { fn(); throw e; });
  };
  Task.resolve = function (v) {
    var t = new Task();
    t._settle("fulfilled", v);
    return t;
  };
  Task.reject = function (e) {
    var t = new Task();
    t._settle("rejected", e);
    return t;
  };
  Task.all = function (tasks) {
    var out = new Task();
    var left = tasks.length;
    var values = new Array(tasks.length);
    if (!left) out._settle("fulfilled", values);
    tasks.forEach(function (t, i) {
      Task.resolve(null).then(function () { return t; }).then(function (v) {
        values[i] = v;
        if (--left === 0) out._settle("fulfilled", values);
      }, function (e) {
        out._settle("rejected", e);
      });
    });
    return out;
  };

  function AsemanError(message, status, op) {
    this.name = "AsemanError";
    this.message = message || "request failed";
    this.status = status || 0;
    this.op = op || "";
  }
  AsemanError.prototype = Object.create(Error.prototype);
  AsemanError.prototype.constructor = AsemanError;

  // ── requests ─────────────────────────────────────────────────────────────

  var pending = {};
  var nextId = 1;

  // request sends one request to the host: target "aseman" (the space's
  // page API op) or "app" (a path of the app's own server).
  function request(target, what, opts) {
    opts = opts || {};
    var task = new Task();
    var id = "r" + nextId++;
    pending[id] = { task: task, op: what };
    var req = {
      id: id,
      target: target,
      method: opts.method || (opts.body !== undefined ? "POST" : "GET"),
      timeoutMs: opts.timeoutMs || (target === "aseman" && what === "ask" ? 360000 : 120000),
    };
    if (target === "aseman") req.op = what;
    else req.path = what;
    if (opts.body !== undefined) req.body = opts.body;
    if (opts.query) req.query = opts.query;
    if (opts.headers) req.headers = opts.headers;
    var accepted;
    try {
      accepted = ask("aseman.request", JSON.stringify(req));
    } catch (e) {
      delete pending[id];
      task._settle("rejected", new AsemanError(String((e && e.message) || e), 0, what));
      return task;
    }
    if (accepted && accepted.error) {
      delete pending[id];
      task._settle("rejected", new AsemanError(accepted.error, accepted.status, what));
    }
    return task;
  }

  // The host settles a request: {id, ok, status, data, error}.
  root.__asemanSettle = function (raw) {
    var r = hostValue(raw);
    if (!r || !r.id || !pending[r.id]) return;
    var p = pending[r.id];
    delete pending[r.id];
    if (r.ok) p.task._settle("fulfilled", r.data);
    else p.task._settle("rejected", new AsemanError(r.error || "request failed", r.status, p.op));
  };

  // ── the space and the app's server ───────────────────────────────────────

  var env = null;
  var envListeners = [];

  function currentEnv() {
    if (!env) {
      try {
        env = ask("aseman.env", "") || {};
      } catch (e) {
        env = {};
      }
    }
    return env;
  }

  root.__asemanEnv = function (raw) {
    env = hostValue(raw) || {};
    for (var i = 0; i < envListeners.length; i++) {
      try {
        envListeners[i](env);
      } catch (e) {
        log("env listener failed:", String(e));
      }
    }
  };

  function parseJSON(text) {
    if (text && typeof text === "object") return text;
    var s = String(text || "");
    var fenced = /```(?:json|openui)?\s*([\s\S]*?)```/i.exec(s);
    var candidates = [fenced && fenced[1], s];
    for (var c = 0; c < candidates.length; c++) {
      var str = candidates[c];
      if (!str) continue;
      var start = str.search(/[[{]/);
      if (start < 0) continue;
      for (var end = str.length; end > start; end--) {
        var ch = str.charAt(end - 1);
        if (ch !== "}" && ch !== "]") continue;
        try {
          return JSON.parse(str.slice(start, end));
        } catch (e) {
          /* shorter */
        }
      }
    }
    throw new AsemanError("the agent's reply has no JSON", 0, "ask");
  }

  var Aseman = {
    Error: AsemanError,
    Task: Task,
    plain: plain,
    parseJSON: parseJSON,
    log: log,

    // How the app is shown and themed: {display: full|compact|sheet,
    // theme: {mode, accent, colors: {primary, onPrimary, surface, …}},
    // user: {id, handle}, space, room, title}.
    env: currentEnv,
    onEnv: function (fn) {
      envListeners.push(fn);
    },

    context: function (opts) { return request("aseman", "context", opts); },
    tools: function (opts) { return request("aseman", "tools", opts).then(function (o) { return (o && o.tools) || []; }); },
    microtools: function (tool, opts) {
      return request("aseman", "microtools", merge(opts, { query: { tool: tool } })).then(function (o) { return (o && o.microtools) || []; });
    },
    agents: function (opts) { return request("aseman", "agents", opts).then(function (o) { return (o && o.agents) || []; }); },

    // A space app's microtool: resolves to its unwrapped result (often a
    // text/markdown string, sometimes an object).
    call: function (tool, microtool, args, opts) {
      return request("aseman", "call", merge(opts, { body: { tool: tool, microtool: microtool, args: args || {} } }))
        .then(function (o) { return o ? o.result : o; });
    },

    // Asks a space agent: a fresh, isolated conversation (a temporary room
    // thread deleted once it answers), billed to the person using the app.
    // Resolves to {agent, reply}.
    ask: function (agent, prompt, opts) {
      opts = opts || {};
      var body = { agent: agent, prompt: prompt };
      if (opts.history && opts.history.length) body.history = opts.history;
      return request("aseman", "ask", merge(opts, { body: body }));
    },

    askJSON: function (agent, prompt, data, opts) {
      var text = prompt + (data !== undefined ? "\n\nData (JSON):\n" + safeStringify(data) : "") +
        "\n\nAnswer only with JSON, no prose.";
      return Aseman.ask(agent, text, opts).then(function (r) { return parseJSON(r && r.reply); });
    },

    // A multi-turn conversation with one agent, kept in the program.
    conversation: function (agent, opts) {
      var turns = ((opts && opts.history) || []).slice();
      return {
        history: function () { return turns.slice(); },
        reset: function () { turns.length = 0; },
        send: function (prompt, sendOpts) {
          return Aseman.ask(agent, prompt, merge(sendOpts, { history: turns })).then(function (r) {
            var reply = (r && r.reply) || "";
            turns.push({ role: "user", content: prompt }, { role: "assistant", content: reply });
            return reply;
          });
        },
      };
    },

    // The app's own server (its backend in the sandbox): path relative to
    // the app, e.g. "api/orders". Resolves to {status, ok, json, text}.
    // The server sees the person using the app (X-Aseman-User-Token).
    fetch: function (path, opts) {
      opts = opts || {};
      return request("app", String(path || "").replace(/^\/+/, ""), opts).then(function (r) {
        if (opts.raw) return r;
        if (r && !r.ok) {
          var msg = (r.json && (r.json.error || r.json.message)) || r.text || ("HTTP " + r.status);
          throw new AsemanError(String(msg).slice(0, 300), r.status, path);
        }
        return r;
      });
    },

    // The compact widget on phones (see ELPIAN.md): {title, value, …}.
    compact: function (summary) {
      try {
        ask("aseman.compact", JSON.stringify(summary || {}));
      } catch (e) {
        /* not shown as a widget */
      }
    },
    expand: function () {
      try {
        ask("aseman.expand", "");
      } catch (e) {
        /* nothing to expand */
      }
    },
  };

  function merge(a, b) {
    var out = {};
    var k;
    for (k in a || {}) out[k] = a[k];
    for (k in b || {}) out[k] = b[k];
    return out;
  }

  // ── App: state, view and events ──────────────────────────────────────────

  var handlerCount = 0;

  // A handler key as part of a global function name: letters, digits and _
  // as they are; every other character as $<hex>$, so different keys never
  // share a name ("key_÷" and "key_×" used to both become "key__") and the
  // name stays a JS identifier (the client calls it as code).
  function safeKey(key) {
    return String(key).replace(/[^A-Za-z0-9_]/g, function (c) {
      return "$" + c.charCodeAt(0).toString(16) + "$";
    });
  }

  function App(spec) {
    var app = this;
    this.spec = spec || {};
    this.state = merge(this.spec.state, {});
    this.error = null;
    this.rendering = false;
    this.dirty = false;
    this.prefix = "__app" + handlerCount++ + "_";
    Aseman.onEnv(function () { app.render(); });
  }

  // A function the view can name in `events`: stable for the same key, so
  // re-renders do not pile up handlers. Errors in it are shown, not lost.
  App.prototype.handler = function (key, fn) {
    var app = this;
    var name = this.prefix + safeKey(key);
    root[name] = function (event) {
      try {
        return fn(plain(event), app);
      } catch (e) {
        app.fail(e);
      }
    };
    return name;
  };

  // A TextField-style input bound to state[field]: {value, events.input}.
  // props are TextField props (label, hint, icon, helper, …); search: true
  // draws the M3 SearchBar instead.
  App.prototype.input = function (key, field, props) {
    var app = this;
    var p = merge(props, { value: app.state[field] == null ? "" : String(app.state[field]) });
    var search = !!p.search;
    delete p.search;
    return {
      type: search ? "SearchBar" : "TextField",
      key: key,
      props: p,
      events: {
        input: this.handler(key + "_input", function (e) {
          var patch = {};
          patch[field] = e && e.value !== undefined ? e.value : (e && e.data && e.data.value);
          app.set(patch, { silent: true });
        }),
      },
    };
  };

  App.prototype.set = function (patch, opts) {
    for (var k in patch || {}) this.state[k] = patch[k];
    if (!(opts && opts.silent)) this.render();
  };

  App.prototype.fail = function (e) {
    this.error = (e && e.message) || String(e);
    log("app error:", this.error);
    this.render();
  };

  // The widget spec, normalized: {view, refresh, size, shape, refreshMs}.
  App.prototype.widgetSpec = function () {
    var w = this.spec.widget;
    if (!w) return null;
    if (typeof w === "function") w = { view: w };
    return typeof w.view === "function" ? w : null;
  };

  // Whether the app is shown as a phone-board widget now.
  App.prototype.isWidget = function () {
    return currentEnv().display === "compact";
  };

  // Calls fn(app) every ms (at least 5 s) while the program runs.
  App.prototype.every = function (key, ms, fn) {
    var app = this;
    var name = this.handler("__every_" + key, function () { fn(app); });
    try {
      return ask("setInterval", JSON.stringify({ handler: name, ms: Math.max(5000, ms | 0) }));
    } catch (e) {
      log("timer unavailable:", String(e));
      return null;
    }
  };

  // In the widget display: tell the board to draw the program itself (in
  // its preferred size and shape), and keep the widget's data live.
  App.prototype.startWidget = function () {
    var w = this.widgetSpec();
    if (!w || this.widgetStarted || !this.isWidget()) return;
    this.widgetStarted = true;
    Aseman.compact({ view: "self", size: w.size || "medium", shape: w.shape || "card", static: !!w.static });
    var refresh = typeof w.refresh === "function" ? w.refresh : this.spec.init;
    if (typeof refresh === "function") {
      this.every("widget_refresh", w.refreshMs || 60000, function (app) {
        try {
          refresh(app);
        } catch (e) {
          app.fail(e);
        }
      });
    }
  };

  App.prototype.render = function () {
    if (this.rendering) {
      this.dirty = true;
      return;
    }
    this.rendering = true;
    try {
      do {
        this.dirty = false;
        var tree;
        try {
          var w = this.isWidget() ? this.widgetSpec() : null;
          tree = w ? w.view(this.state, this) : this.spec.view(this.state, this);
        } catch (e) {
          this.error = (e && e.message) || String(e);
          log("view error:", this.error + (e && e.stack ? "\n" + String(e.stack).split("\n").slice(0, 3).join("\n") : ""));
          tree = null;
        }
        if (this.error) tree = errorView(this, tree);
        root.askHost("render", JSON.stringify(cleanNode(tree) || { type: "SizedBox" }));
      } while (this.dirty);
    } finally {
      this.rendering = false;
    }
  };

  // A view tree as the engine wants it: JS idioms that leave holes in a
  // children list (`cond && node`, `cond ? node : null`, `undefined`) are
  // dropped, nested arrays flatten, and bare strings or numbers become Text.
  function cleanList(list, out) {
    out = out || [];
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (Array.isArray(c)) cleanList(c, out);
      else {
        var n = cleanNode(c);
        if (n) out.push(n);
      }
    }
    return out;
  }

  function cleanNode(node) {
    if (node === null || node === undefined || typeof node === "boolean") return null;
    if (typeof node === "string" || typeof node === "number") return { type: "Text", props: { text: String(node) } };
    if (Array.isArray(node)) return { type: "Column", children: cleanList(node) };
    if (typeof node !== "object") return null;
    if (node.children === undefined || node.children === null) return node;
    var out = {};
    for (var k in node) out[k] = node[k];
    out.children = cleanList(Array.isArray(node.children) ? node.children : [node.children]);
    return out;
  }

  function errorView(app, tree) {
    var dismiss = app.handler("__dismiss_error", function () {
      app.error = null;
      app.render();
    });
    var banner = {
      type: "Callout",
      props: { severity: "critical", title: "Something went wrong", text: app.error },
      children: [{ type: "Button", props: { text: "Dismiss", variant: "tonal", size: "xs", icon: "close" }, events: { tap: dismiss } }],
    };
    return { type: "Column", props: { style: { gap: "12", padding: "16" } }, children: tree ? [banner, tree] : [banner] };
  }

  // Snapshot and restore of the first app's state (JSON): check.mjs uses them
  // to explore the app's states (fire every handler from every state).
  root.__asemanSnapshot = function () {
    var a = (root.__asemanApps || [])[0];
    if (!a) return null;
    try {
      return JSON.stringify({ s: a.state, e: a.error || null });
    } catch (e) {
      return null;
    }
  };
  root.__asemanRestore = function (json) {
    var a = (root.__asemanApps || [])[0];
    if (!a) return;
    var v = JSON.parse(json);
    a.state = v.s;
    a.error = v.e;
    a.render();
  };

  App.create = function (spec) {
    if (!spec || typeof spec.view !== "function") throw new Error("App.create needs view(state, app)");
    var app = new App(spec);
    (root.__asemanApps || (root.__asemanApps = [])).push(app);
    app.render();
    app.startWidget();
    Aseman.onEnv(function () { app.startWidget(); });
    if (typeof spec.init === "function") {
      try {
        spec.init(app);
      } catch (e) {
        app.fail(e);
      }
    }
    return app;
  };

  root.Aseman = Aseman;
  root.App = App;
  root.Task = Task;
})(typeof globalThis !== "undefined" ? globalThis : this);
