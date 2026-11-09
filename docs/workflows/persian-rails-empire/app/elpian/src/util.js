/* Thin Godot host — all player UI lives in the Godot shell (HUD design language). */

var THEME = {
  WOOD_DARK: "#3b2418",
  CREAM: "#fff8ee",
  GOLD_SOFT: "#e6c86a",
  FONT: "Vazirmatn, 'Vazirmatn UI FD', Tahoma, sans-serif",
};

function assetBase() {
  var e = (typeof Aseman !== "undefined" && Aseman.env) ? (Aseman.env() || {}) : {};
  if (e.appUrl) return String(e.appUrl).replace(/\/?$/, "/");
  var cfg = (typeof app !== "undefined" && app.state && app.state.cfg) || {};
  return cfg.asset_base || "/";
}

function T(text, variant, more) {
  var p = {
    text: String(text == null ? "" : text),
    variant: variant || "bodyMedium",
    textAlign: "center",
    style: { fontFamily: THEME.FONT, color: THEME.CREAM },
  };
  for (var k in more || {}) {
    if (k === "style" && more.style && typeof more.style === "object") {
      p.style = Object.assign({}, p.style, more.style);
    } else {
      p[k] = more[k];
    }
  }
  return { type: "Text", props: p };
}

function C(children, style) {
  return {
    type: "Column",
    props: { style: Object.assign({ gap: "10", alignItems: "stretch" }, style || {}) },
    children: (children || []).filter(Boolean),
  };
}

function box(style, children) {
  return { type: "Container", props: { style: style || {} }, children: children || [] };
}

function errText(e) {
  if (!e) return "یه مشکلی پیش اومد";
  var j = e.json || (e.response && e.response.json);
  if (j && j.error) return j.error;
  if (e.status === 0 || /network|fetch/i.test(String(e.message || ""))) {
    return "فعلاً به سرور وصل نیستیم. یکم بعد دوباره بیا.";
  }
  return String(e.message || e.error || e);
}
