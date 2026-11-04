/*
 * Aseman plugin shim: what a Creator plugin's Elpian screen uses on top of
 * the Aseman Elpian SDK (aseman-elpian.js, loaded first). The Aseman client
 * runs SDK + this shim + the plugin's program on QuickJS; the plugin checker
 * (plugin-check.mjs) runs the same three. See PLUGINS.md.
 *
 *   Aseman.plugin.call(fn, args)              -> Task: the plugin's own backend
 *   Aseman.plugin.api(namespace, action, body) -> Task: a platform action the
 *                                                plugin declared in permissions
 *   Aseman.plugin.get(key) / set(key, value)   -> Task: the plugin's own store
 *                                                (the default backend's get/set)
 *   Aseman.plugin.context()                    -> Task: {plugin, name, scope,
 *                                                space, room, user, display}
 *
 * Host protocol: askHost('aseman.request', {id, target: "plugin", op, body})
 * -> {accepted}; the host later calls __asemanSettle({id, ok, data, error}).
 * Settles for the SDK's own requests pass through to it.
 */
(function (root) {
  "use strict";
  var Aseman = root.Aseman;
  var Task = root.Task;
  if (!Aseman || !Task) throw new Error("aseman-plugin.js needs the Aseman Elpian SDK loaded first");

  function hostValue(raw) {
    var v = raw;
    if (typeof v === "string") {
      try { v = JSON.parse(v); } catch (e) { return raw; }
    }
    return plain(v);
  }

  // Host values arrive typed ({type, data: {value}}), at any depth.
  function plain(v) {
    if (v === null || v === undefined || typeof v !== "object") return v;
    if (typeof v.type === "string" && v.data && typeof v.data === "object" && "value" in v.data) return plain(v.data.value);
    if (Array.isArray(v)) return v.map(plain);
    var out = {};
    for (var k in v) if (Object.prototype.hasOwnProperty.call(v, k)) out[k] = plain(v[k]);
    return out;
  }

  function PluginError(message, op) {
    this.name = "PluginError";
    this.message = message || "the plugin request failed";
    this.op = op || "";
  }
  PluginError.prototype = Object.create(Error.prototype);
  PluginError.prototype.constructor = PluginError;

  var pending = {};
  var nextId = 1;

  function request(op, body, timeoutMs) {
    var task = new Task();
    var id = "p" + nextId++;
    pending[id] = { task: task, op: op };
    var req = { id: id, target: "plugin", op: op, body: body || {}, timeoutMs: timeoutMs || 120000 };
    var accepted;
    try {
      accepted = hostValue(root.askHost("aseman.request", JSON.stringify(req)));
    } catch (e) {
      delete pending[id];
      task._settle("rejected", new PluginError(String((e && e.message) || e), op));
      return task;
    }
    if (accepted && accepted.error) {
      delete pending[id];
      task._settle("rejected", new PluginError(accepted.error, op));
    }
    return task;
  }

  var sdkSettle = root.__asemanSettle;
  root.__asemanSettle = function (raw) {
    var r = hostValue(raw);
    if (r && r.id && pending[r.id]) {
      var p = pending[r.id];
      delete pending[r.id];
      if (r.ok) p.task._settle("fulfilled", r.data);
      else p.task._settle("rejected", new PluginError(r.error, p.op));
      return;
    }
    if (typeof sdkSettle === "function") sdkSettle(raw);
  };

  Aseman.plugin = {
    call: function (fn, args, opts) {
      return request("invoke", { "function": String(fn || ""), args: args || {} }, opts && opts.timeoutMs);
    },
    api: function (namespace, action, body, opts) {
      return request("call", { namespace: String(namespace || ""), action: String(action || ""), body: body || {} }, opts && opts.timeoutMs);
    },
    get: function (key) {
      return request("invoke", { "function": "get", args: { key: String(key) } }).then(function (o) {
        return o && typeof o === "object" && "value" in o ? o.value : o;
      });
    },
    set: function (key, value) {
      return request("invoke", { "function": "set", args: { key: String(key), value: value } });
    },
    context: function () {
      return request("context", {});
    },
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
