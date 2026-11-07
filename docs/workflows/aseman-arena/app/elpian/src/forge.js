/* The Game Forge: describe a game, talk it through with the Forge agent, and
 * it builds it — a Godot game against AI opponents — on the platform's
 * computer. When the build is in, play-test it from here (and in a private
 * room), then publish it to the store, where anyone can host it in a room. */

var GENRES = ["arcade", "board", "puzzle", "racing", "shooter", "strategy", "sports", "platformer"];

function openForgeList() {
  if (!signedIn()) return;
  push({ name: "forgelist" });
  app.set({ forgeList: null, forgeListError: null, newGame: false });
  loadForgeList();
}

function loadForgeList() {
  api("forge").then(function (r) { app.set({ forgeList: r }); }).catch(function (e) { app.set({ forgeListError: errText(e) }); });
}

function forgeListView(s, app) {
  var fl = s.forgeList;
  var status = { drafting: ["Drafting", "info"], building: ["Building", "warning"], ready: ["Ready to test", "good"], published: ["Published", "good"] };
  return C([subBar(app, "forgelist", "Game Forge", "Describe a game — an AI agent builds it"), X(page([
    box({ gradient: { colors: ["#3b2a6b", "#10131c"], begin: "topLeft", end: "bottomRight" }, padding: "20", borderRadius: "28" }, [C([
      R([{ type: "Icon", props: { icon: "auto_awesome", size: 28, style: { color: "#ffffff" } } }, X(T("Make a game by talking", "titleLargeEmphasized", { style: { color: "#ffffff" } }))]),
      T("Tell the Forge what you want to play. It designs it with you, builds it in Godot with AI opponents and CC0 3D models, tests it, and hands it to you to play-test and publish to the store.", "bodyMedium", { style: { color: "#ffffffcc" } }),
      fl && !fl.connected ? { type: "Tag", props: { text: "The Forge agent is offline right now", status: "warning" } } : null,
    ], { gap: "10" })]),
    s.newGame ? card([
      T("A new game", "titleMediumEmphasized"),
      app.input("ng_title", "_ngTitle", { label: "Working title", icon: "edit", live: true }),
      { type: "Wrap", props: { style: { gap: "8" } }, children: GENRES.map(function (g) {
        return { type: "Chip", key: hk("ng_genre", g), props: { label: g, selected: s.ngGenre === g, variant: "filter" }, events: { change: app.handler(hk("ng_genre", g), function () { app.set({ ngGenre: g }); }) } }; }) },
      app.input("ng_brief", "_ngBrief", { label: "Describe it", hint: "A neon racing game on a rooftop circuit against three AI drivers who draft and block…", multiline: true, maxLines: 6, live: true }),
      R([X({ type: "Button", key: "ng_start", props: { text: "Start forging", icon: "auto_awesome", fullWidth: true, loading: !!s.ngBusy, disabled: (s._ngTitle || "").trim().length < 3 || (s._ngBrief || "").trim().length < 20 }, events: { tap: app.handler("ng_start", startProject) } }),
         { type: "Button", key: "ng_cancel", props: { text: "Cancel", variant: "text" }, events: { tap: app.handler("ng_cancel", function () { app.set({ newGame: false }); }) } }], { gap: "8" }),
    ]) : { type: "Button", key: "forge_new", props: { text: "Forge a new game", icon: "add", size: "m", fullWidth: true }, events: { tap: app.handler("forge_new", function () { app.set({ newGame: true, ngGenre: "arcade" }); }) } },
    s.forgeListError ? problem(app, "forge_retry", s.forgeListError, loadForgeList) : !fl ? loading() :
      fl.projects.length ? section("Your projects", null, [{ type: "ListGroup", children: fl.projects.map(function (p) {
        var st = status[p.status] || [p.status, "info"];
        return { type: "ListTile", key: hk("fp", p.id), props: { title: p.title, subtitle: st[0] + " · " + (p.genre || "game") + " · " + ago(p.updated_at) + " ago", leading: p.status === "published" ? "verified" : "construction", trailing: "chevron_right" },
          events: { tap: app.handler(hk("fp", p.id), function () { openForge(p.id); }) } }; }) }])
      : T("Your games will be listed here.", "bodyMedium", { color: "muted" }),
  ]))], { gap: "0" });
}

function startProject() {
  var s = app.state;
  app.set({ ngBusy: true });
  apiPost("forge", { title: s._ngTitle, brief: s._ngBrief, genre: s.ngGenre || "" }).then(function (r) {
    app.set({ ngBusy: false, newGame: false, _ngTitle: "", _ngBrief: "" });
    openForge(r.project.id, r);
  }).catch(function (e) { app.set({ ngBusy: false }); app.fail(e); });
}

function openForge(id, data) {
  push({ name: "forge", id: id });
  app.set({ forge: data || null, forgeError: null });
  if (!data) loadForge(id);
}

function loadForge(id) {
  api("forge/" + id).then(function (r) { app.set({ forge: r }); }).catch(function (e) { app.set({ forgeError: errText(e) }); });
}

function forgeThinking(f) {
  return !!(f && f.messages.some(function (m) { return m.state === "thinking"; }));
}

function forgeView(s, app) {
  var f = s.forge;
  if (!f) return C([subBar(app, "forge", "Forge"), X(s.forgeError ? box({ padding: "16" }, [problem(app, "forge_load_retry", s.forgeError, function () { loadForge(top().id); })]) : loading())], { gap: "0" });
  var p = f.project, thinking = forgeThinking(f);
  var msgs = f.messages.filter(function (m) { return m.state !== "thinking"; }).map(function (m) {
    return { role: m.role === "user" ? "user" : "assistant", text: m.state === "failed" ? "⚠ " + m.text : m.text, name: m.role === "user" ? "You" : "Forge", time: ago(m.at) };
  });
  var g = f.game;
  var ready = p.status === "ready" || p.status === "published";
  return C([
    subBar(app, "forge", p.title, (p.genre || "game") + " · " + (thinking ? "the Forge is working…" : p.status)),
    ready && g ? box({ padding: "0 16 8 16" }, [card([
      R([X(C([T(g.title + " v" + g.version, "titleSmallEmphasized"), T(p.status === "published" ? "In the store" : "Built — play-test it, then publish", "labelMedium", { color: "muted" })], { gap: "2" })),
         { type: "Button", key: "forge_test", props: { text: "Play-test", icon: "play_arrow", variant: "tonal", loading: !!s.launching }, events: { tap: app.handler("forge_test", function () { startMatch(g.slug, null, {}); }) } },
         p.status !== "published" ? { type: "Button", key: "forge_publish", props: { text: "Publish", icon: "rocket_launch", loading: !!s.publishing }, events: { tap: app.handler("forge_publish", publishProject) } } : null], { gap: "8" }),
    ], { padding: "12" }, { tone: "primary" })]) : null,
    X({ type: "Chat", key: "forge_chat", props: { messages: msgs, typing: thinking, showAvatars: true,
      suggestions: thinking ? [] : ready ? ["Make the AI tougher", "Add a power-up", "Change the colours"] : ["Sounds good — build it", "Make it 3D", "Add more AI opponents"] },
      events: { select: app.handler("forge_suggest", function (e) { sendForge(e.text); }) } }),
    R([X(app.input("forge_text", "_forgeText", { hint: thinking ? "The Forge is working…" : "Tell the Forge what to change", icon: "auto_awesome", live: true })),
       { type: "IconButton", key: "forge_send", props: { icon: "send", variant: "filled", tooltip: "Send", disabled: thinking || !(s._forgeText || "").trim() }, events: { tap: app.handler("forge_send", function () { sendForge(app.state._forgeText); }) } }], { padding: "8 12", gap: "8" }),
  ], { gap: "0" });
}

function sendForge(text) {
  text = String(text || "").trim();
  var f = app.state.forge;
  if (!text || !f) return;
  app.set({ _forgeText: "" });
  apiPost("forge/" + f.project.id + "/messages", { text: text }).then(function (r) { app.set({ forge: Object.assign({}, f, r) }); }).catch(function (e) { app.fail(e); });
}

function publishProject() {
  var f = app.state.forge;
  app.set({ publishing: true });
  apiPost("forge/" + f.project.id + "/publish").then(function (r) {
    app.set({ publishing: false, store: null, toast: "Published to the store" });
    loadForge(f.project.id);
    loadStore();
  }).catch(function (e) { app.set({ publishing: false }); app.fail(e); });
}
