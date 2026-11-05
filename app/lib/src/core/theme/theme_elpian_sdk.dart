import 'package:flutter/services.dart';

/// Loads the stock Aseman Elpian SDK plus a thin theme shim that exposes
/// `Aseman.api(namespace, action, body)` → `target: "core"` for theme panels.
abstract final class ThemeElpianSdk {
  static const assetPath = 'assets/elpian/aseman-elpian.js';

  static String? _cached;

  /// SDK + shim source. Cached after first load.
  static Future<String> bootstrap() async {
    final cached = _cached;
    if (cached != null) return cached;
    final sdk = await rootBundle.loadString(assetPath);
    final source = '$sdk\n$_themeShim\n';
    _cached = source;
    return source;
  }

  /// Prepends the SDK when [source.sdk] is true.
  static Future<String> wrapProgram(String program, {bool sdk = true}) async {
    if (!sdk || program.trim().isEmpty) return program;
    final boot = await bootstrap();
    return '$boot\n$program\n';
  }

  /// Shim: core platform API for theme UI islands.
  static const _themeShim = r'''
(function (root) {
  "use strict";
  var Aseman = root.Aseman;
  if (!Aseman) return;

  function ask(api, payload) {
    if (typeof root.askHost !== "function") throw new Error("askHost missing");
    var raw = root.askHost(api, payload);
    if (typeof raw === "string") {
      try { raw = JSON.parse(raw); } catch (e) { return raw; }
    }
    if (raw && typeof raw === "object" && raw.data && "value" in raw.data) return raw.data.value;
    return raw;
  }

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
    for (var i = 0; i < hs.length; i++) {
      var h = hs[i];
      var cb = state === "fulfilled" ? h.ok : h.fail;
      if (!cb) { h.next._settle(state, value); continue; }
      try {
        var r = cb(value);
        if (r && typeof r.then === "function") {
          r.then(function (v) { h.next._settle("fulfilled", v); },
                 function (e) { h.next._settle("rejected", e); });
        } else h.next._settle("fulfilled", r);
      } catch (e) { h.next._settle("rejected", e); }
    }
  };
  Task.prototype.then = function (ok, fail) {
    var next = new Task();
    var h = { ok: ok, fail: fail, next: next };
    if (this.state === "pending") this.handlers.push(h);
    else this._settle(this.state, this.value), this.handlers.push(h), this._settle(this.state, this.value);
    if (this.state !== "pending") {
      var self = this;
      setTimeout(function () { self._settle(self.state, self.value); }, 0);
    }
    return next;
  };
  Task.prototype.catch = function (fail) { return this.then(null, fail); };

  // Full platform API as the signed-in person.
  Aseman.api = function (namespace, action, body, opts) {
    opts = opts || {};
    var task = new Task();
    var id = "core" + Date.now().toString(36) + Math.floor(Math.random() * 1e6);
    var pending = root.__themePending || (root.__themePending = {});
    pending[id] = task;
    var req = {
      id: id,
      target: "core",
      namespace: String(namespace || ""),
      action: String(action || ""),
      body: body || {},
      timeoutMs: opts.timeoutMs || 120000
    };
    try {
      var accepted = ask("aseman.request", JSON.stringify(req));
      if (accepted && accepted.error) {
        delete pending[id];
        task._settle("rejected", new Error(accepted.error));
      }
    } catch (e) {
      delete pending[id];
      task._settle("rejected", e);
    }
    return task;
  };

  var prevSettle = root.__asemanSettle;
  root.__asemanSettle = function (raw) {
    var r = raw;
    if (typeof r === "string") {
      try { r = JSON.parse(r); } catch (e) {}
    }
    if (r && r.data && "value" in r.data) r = r.data.value;
    var pending = root.__themePending;
    if (r && r.id && pending && pending[r.id]) {
      var t = pending[r.id];
      delete pending[r.id];
      if (r.ok) t._settle("fulfilled", r.data);
      else t._settle("rejected", new Error(r.error || "request failed"));
      return;
    }
    if (typeof prevSettle === "function") prevSettle(raw);
  };

  Aseman.navigate = function (intent) {
    try {
      ask("aseman.navigate", JSON.stringify(intent || {}));
      return true;
    } catch (e) {
      return false;
    }
  };
})(globalThis);
''';
}
