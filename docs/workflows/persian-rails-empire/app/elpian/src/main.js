/* Godot-first host: Flutter/Elpian only embeds the Godot shell Scene3D.
 * Home / play / atlas / ranks / rules all run inside Godot (shell.tscn).
 */

var app = App.create({
  state: {
    booted: false,
    bootError: null,
    cfg: null,
    progress: null,
    sceneError: null,
  },

  view: function (s) {
    if (!s.booted) {
      return {
        type: "Scaffold",
        props: { style: { backgroundColor: THEME.WOOD_DARK } },
        children: [
          box({
            padding: "24",
            alignItems: "center",
            justifyContent: "center",
            backgroundColor: THEME.WOOD_DARK,
            width: "100%",
            height: "100%",
          }, [
            C([
              T(s.bootError ? "ای وای!" : "سلام!", "titleMedium", {
                style: { color: THEME.GOLD_SOFT, fontWeight: "700" },
              }),
              T(s.bootError || "داریم ایستگاه گودو رو باز می‌کنیم…", "bodyMedium"),
            ], { gap: "8", alignItems: "center" }),
          ]),
        ],
      };
    }

    var g = (s.cfg && s.cfg.game) || {};
    var base = assetBase();
    /* Root-relative /api/ — Aseman's injected fetch proxy rewrites it to
     * /v1/platforms/<slug>/app/api/. Absolute origin+/api hits the SPA. */
    var apiBase = "/api/";
    var packPath = g.pack_path || g.pack || "games/persian-rails/persian-rails.pck";
    var scenePath = g.scene || "res://arena/persian_rails/shell.tscn";
    var userId = (s.cfg.me && (s.cfg.me.id || s.cfg.me.handle)) || "visitor";
    var playerName = (s.cfg.me && s.cfg.me.name) || "";
    var pack = {
      type: "pack",
      id: "shell",
      src: base + packPath,
      scene: scenePath,
      version: g.version || "1.6.4",
      params: {
        api_base: apiBase,
        player_name: playerName,
        user_id: userId,
      },
    };
    if (g.web) {
      var q = [
        "api_base=" + encodeURIComponent(apiBase),
        "user_id=" + encodeURIComponent(userId),
      ];
      if (playerName) q.push("player_name=" + encodeURIComponent(playerName));
      var web = base + g.web;
      pack.web = web + (web.indexOf("?") >= 0 ? "&" : "?") + q.join("&");
    }

    var scene = {
      type: "Scene3D",
      key: "shell",
      props: { scene: { nodes: [pack] } },
      events: {
        assetprogress: app.handler("shell_progress", function (e) {
          var d = e.data || e;
          app.set({ progress: { loaded: Number(d.loaded || 0), total: Number(d.total || 0) } });
        }),
        asseterror: app.handler("shell_error", function (e) {
          var d = e.data || e;
          app.set({ sceneError: d.message || "موتور گودو لود نشد" });
        }),
      },
      children: [
        box({
          padding: "20",
          alignItems: "center",
          justifyContent: "center",
          backgroundColor: THEME.WOOD_DARK,
          width: "100%",
          height: "100%",
        }, [
          C([
            T(s.sceneError || "موتور گودو داره بالا میاد…", "titleSmall", {
              style: { color: THEME.CREAM, fontWeight: "700" },
            }),
            s.progress && s.progress.total
              ? T(Math.round(100 * s.progress.loaded / s.progress.total) + "٪", "bodyMedium", {
                style: { color: THEME.GOLD_SOFT },
              })
              : null,
            pack.web
              ? {
                type: "InkWell",
                key: "open_web",
                events: {
                  tap: app.handler("open_web", function () {
                    if (Aseman.openUrl) Aseman.openUrl(pack.web);
                    else if (typeof window !== "undefined") window.open(pack.web, "_blank");
                  }),
                },
                children: [T("باز کردن نسخه وب", "titleSmall", {
                  style: { color: THEME.GOLD_SOFT, fontWeight: "700" },
                })],
              }
              : null,
          ], { gap: "10", alignItems: "center" }),
        ]),
      ],
    };

    /* Column → Expanded → Stack → Positioned(fill) forces tight constraints so
     * the web iframe / Godot canvas fills the whole Elpian body. */
    return {
      type: "Scaffold",
      props: { style: { backgroundColor: THEME.WOOD_DARK } },
      children: [{
        type: "Column",
        props: { style: { gap: "0", alignItems: "stretch", width: "100%", height: "100%" } },
        children: [{
          type: "Expanded",
          children: [{
            type: "Stack",
            props: { style: { width: "100%", height: "100%" } },
            children: [{
              type: "Positioned",
              props: { style: { left: "0", right: "0", top: "0", bottom: "0" } },
              children: [scene],
            }],
          }],
        }],
      }],
    };
  },

  init: function () {
    api("me").then(function (cfg) {
      app.set({ booted: true, bootError: null, cfg: cfg });
    }).catch(function (e) {
      app.set({ bootError: errText(e) });
    });
  },

  widget: {
    size: "medium",
    shape: "card",
    refreshMs: 60000,
    refresh: function () {
      api("me").then(function (cfg) { app.set({ cfg: cfg, booted: true }); });
    },
    view: function (s) {
      var title = (s.cfg && s.cfg.product) || "امپراتوری راه‌آهن پارس";
      var me = s.cfg && s.cfg.me;
      return box({ padding: "14", backgroundColor: THEME.WOOD_DARK }, [
        C([
          T(title, "titleSmall", { style: { color: THEME.CREAM, fontWeight: "700" } }),
          T(me ? (me.name + " · " + me.rating) : "ورود با گودو", "bodySmall", {
            style: { color: THEME.GOLD_SOFT },
          }),
        ], { gap: "2" }),
      ]);
    },
  },
});
