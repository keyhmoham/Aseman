/*
 * Aseman web plugin bridge: injected first into a web plugin's HTML by the
 * Aseman client (and by plugin-check.mjs). A web plugin is one self-contained
 * HTML document shown in the app's sandboxed web frame; it never loads or
 * sends anything over the network (the frame's Content-Security-Policy
 * forbids it), so everything it needs is inlined and everything it does goes
 * through this bridge. See PLUGINS.md.
 *
 *   Aseman.plugin.call(fn, args)               -> Promise: its own backend
 *   Aseman.plugin.api(namespace, action, body) -> Promise: a declared platform action
 *   Aseman.plugin.get(key) / set(key, value)   -> Promise: its own store
 *   Aseman.plugin.context()                    -> Promise: {plugin, name, scope, space, room, user, display}
 *   Aseman.env                                 the person's theme, display and viewport
 *   Aseman.onEnv(fn)                           called now and when the theme changes
 *
 * The theme is also set as CSS variables on :root — --aseman-primary,
 * --aseman-on-primary, --aseman-surface, --aseman-on-surface,
 * --aseman-surface-container, --aseman-outline, --aseman-error, … (every
 * colour role, kebab-cased), --aseman-radius, --aseman-font — and
 * color-scheme / data-theme="light|dark" on <html>.
 *
 * Wire protocol (window.parent.postMessage, JSON):
 *   page -> host  {aseman: "request", id, op: "invoke"|"call"|"context", body}
 *   host -> page  {aseman: "settle", id, ok, data, error}
 *   host -> page  {aseman: "env", env}
 *   page -> host  {aseman: "ready"} once the bridge is up; {aseman: "error", message} on an uncaught error
 */
(function () {
  "use strict";
  if (window.Aseman && window.Aseman.__web) return;
  var pending = {};
  var nextId = 1;
  var listeners = [];
  var env = window.__asemanInitialEnv || { display: "full", theme: { mode: "light", colors: {} } };

  function post(message) {
    try {
      window.parent.postMessage(message, "*");
    } catch (e) {
      /* no host */
    }
  }

  function request(op, body) {
    return new Promise(function (resolve, reject) {
      var id = "w" + nextId++;
      pending[id] = { resolve: resolve, reject: reject, op: op };
      post({ aseman: "request", id: id, op: op, body: body || {} });
    });
  }

  function kebab(name) {
    return String(name).replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
  }

  function applyEnv(next) {
    env = next || env;
    var root = document.documentElement;
    if (!root) return;
    var theme = env.theme || {};
    var colors = theme.colors || {};
    for (var k in colors) {
      if (Object.prototype.hasOwnProperty.call(colors, k)) root.style.setProperty("--aseman-" + kebab(k), colors[k]);
    }
    if (theme.radius !== undefined) root.style.setProperty("--aseman-radius", theme.radius + "px");
    if (theme.font) root.style.setProperty("--aseman-font", theme.font);
    var mode = theme.mode === "dark" ? "dark" : "light";
    root.setAttribute("data-theme", mode);
    root.style.colorScheme = mode;
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](env); } catch (e) { report(e); }
    }
  }

  function report(error) {
    post({ aseman: "error", message: String((error && (error.stack || error.message)) || error) });
  }

  window.addEventListener("message", function (event) {
    var m = event.data;
    if (typeof m === "string") {
      try { m = JSON.parse(m); } catch (e) { return; }
    }
    if (!m || typeof m !== "object") return;
    if (m.aseman === "settle" && pending[m.id]) {
      var p = pending[m.id];
      delete pending[m.id];
      if (m.ok) p.resolve(m.data);
      else p.reject(new Error(m.error || ("the plugin request " + p.op + " failed")));
    } else if (m.aseman === "env") {
      applyEnv(m.env);
    }
  });
  window.addEventListener("error", function (e) { report(e.error || e.message); });
  window.addEventListener("unhandledrejection", function (e) { report(e.reason); });

  window.Aseman = {
    __web: true,
    get env() { return env; },
    onEnv: function (fn) {
      listeners.push(fn);
      try { fn(env); } catch (e) { report(e); }
    },
    plugin: {
      call: function (fn, args) { return request("invoke", { "function": String(fn || ""), args: args || {} }); },
      api: function (namespace, action, body) {
        return request("call", { namespace: String(namespace || ""), action: String(action || ""), body: body || {} });
      },
      get: function (key) {
        return request("invoke", { "function": "get", args: { key: String(key) } }).then(function (o) {
          return o && typeof o === "object" && "value" in o ? o.value : o;
        });
      },
      set: function (key, value) { return request("invoke", { "function": "set", args: { key: String(key), value: value } }); },
      context: function () { return request("context", {}); },
    },
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { applyEnv(env); });
  else applyEnv(env);
  post({ aseman: "ready" });
})();
