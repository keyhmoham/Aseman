/* Playing: a match starts on the server (a one-time token, the settings),
 * the game's resource pack is mounted in a full-screen Scene3D and started
 * with them, and when the game reports its result the program hands it to
 * the server, which rates it — then the person sees what it earned. */

function startMatch(slug, roomId, choices) {
  if (!signedIn()) return;
  app.set({ launching: true });
  var path = roomId ? "rooms/" + roomId + "/matches" : "matches";
  apiPost(path, Object.assign({ game: slug }, choices || {})).then(function (out) {
    app.set({ launching: false, play: { launch: out.launch, match: out.match, room: roomId || "", scene: gameScene(out.launch), progress: null, error: null, result: null, outcome: null, submitting: false } });
    push({ name: "play" });
  }).catch(function (e) { app.set({ launching: false }); app.fail(e); });
}

function playView(s, app) {
  var p = s.play;
  if (!p) return C([subBar(app, "play", "Play"), X(loading())], { gap: "0" });
  var g = gameBySlug(p.match.game) || { title: p.match.game };
  var scene = { type: "Scene3D", key: "game", props: { scene: p.scene },
    events: { gameevent: app.handler("game_event", onGameEvent), assetprogress: app.handler("game_progress", onGameProgress),
              asseterror: app.handler("game_error", onGameError), assetload: app.handler("game_loaded", function () { patchPlay({ progress: null, loaded: true }); }) },
    children: [playPlaceholder(s, app, p, g)] };
  var overlay = null;
  if (p.outcome) overlay = resultCard(s, app, p);
  else if (p.progress && p.progress.total > 0) overlay = card([T("Downloading " + g.title + "…", "titleSmallEmphasized"),
    { type: "Progress", props: { value: p.progress.loaded / p.progress.total, showValue: true, wavy: true } }], { padding: "14" });
  else if (p.error) overlay = { type: "Callout", props: { severity: "critical", title: "The game could not start", text: p.error } };
  return C([
    subBar(app, "play", g.title, p.room ? "In the room · match " + p.match.id.slice(-6) : "Practice · match " + p.match.id.slice(-6), [
      !p.outcome ? { type: "Button", key: "play_quit", props: { text: "Leave", icon: "logout", variant: "text" }, events: { tap: app.handler("play_quit", quitMatch) } } : null]),
    X(overlay ? { type: "Stack", children: [scene, { type: "Positioned", props: { style: { left: "12", right: "12", bottom: "12" } }, children: [overlay] }] } : scene),
  ], { gap: "0" });
}

function patchPlay(p) { app.set({ play: Object.assign({}, app.state.play, p) }); }

function playPlaceholder(s, app, p, g) {
  var base = (s.cfg || {}).asset_base || "";
  var web = p.launch.web && base ? base + p.launch.web : "";
  return box({ gradient: { colors: [hex(g.accent, "#6aa8ff"), "#0b1020"], begin: "topLeft", end: "bottomRight" }, padding: "20", alignItems: "center", justifyContent: "center" }, [
    C([{ type: "Icon", props: { icon: "sports_esports", size: 44, style: { color: "#ffffff" } } },
       T(g.title, "headlineSmallEmphasized", { style: { color: "#ffffff" }, textAlign: "center" }),
       T("This device has no 3D engine for games. Play this match in your browser — its result still counts.", "bodyMedium", { style: { color: "#ffffffcc" }, textAlign: "center" }),
       web ? { type: "Markdown", props: { text: "[Play " + g.title + " in the browser](" + web + ")" } } : null],
      { alignItems: "center", gap: "10" })]);
}

function onGameProgress(e) {
  var d = e.data || e;
  patchPlay({ progress: { loaded: Number(d.loaded || 0), total: Number(d.total || 0) } });
}

function onGameError(e) {
  var d = e.data || e;
  patchPlay({ error: d.message || "the game could not be loaded", progress: null });
}

function onGameEvent(e) {
  // The game's own JSON is the event's data (the event's own type is
  // "gameevent"; the game's is data.type).
  var d = e.data || {};
  var p = app.state.play;
  if (!p || d.type !== "result" || p.submitting || p.outcome) return;
  patchPlay({ submitting: true, outcome: d.outcome });
  var body = { token: p.match.token };
  for (var k in d) if (k !== "id" && typeof d[k] !== "object") body[k] = d[k];
  apiPost("matches/" + p.match.id + "/result", body).then(function (res) {
    patchPlay({ result: res, submitting: false });
    if (res.achievements && res.achievements.length) app.set({ toast: "Achievement unlocked: " + res.achievements[0].title });
  }).catch(function (err) { patchPlay({ submitting: false, error: errText(err) }); });
}

function resultCard(s, app, p) {
  var r = p.result, win = p.outcome === "win", draw = p.outcome === "draw";
  var head = win ? "Victory" : draw ? "Draw" : "Defeat";
  return { type: "Card", props: { tone: win ? "primary" : draw ? "secondary" : "error", style: { padding: "16", gap: "10" } }, children: [C([
    R([X(T(head, "headlineSmallEmphasized")), r ? { type: "Tag", props: { text: signed(r.rating_change) + " rating", status: r.rating_change >= 0 ? "good" : "serious" } } : null]),
    r ? R([
      X({ type: "Stat", props: { label: "Score", value: r.score, format: "integer", size: "compact" } }),
      X({ type: "Stat", props: { label: "XP", value: r.xp, format: "+integer", size: "compact" } }),
      X({ type: "Stat", props: { label: "Rating", value: r.rating, format: "integer", size: "compact" } }),
    ], { gap: "8" }) : p.submitting ? R([{ type: "LoadingIndicator", props: { size: 24 } }, T("Recording the result…", "bodyMedium")]) : null,
    r && r.achievements && r.achievements.length ? { type: "Wrap", props: { style: { gap: "6" } }, children: r.achievements.map(function (a) {
      return { type: "Chip", key: hk("ach", a.id), props: { label: a.title, icon: a.icon } }; }) } : null,
    r && r.progress ? levelBar(r.progress) : null,
    R([
      X({ type: "Button", key: "play_again", props: { text: "Play again", icon: "replay", fullWidth: true }, events: { tap: app.handler("play_again", playAgain) } }),
      X({ type: "Button", key: "play_done", props: { text: p.room ? "Back to the room" : "Done", variant: "tonal", fullWidth: true }, events: { tap: app.handler("play_done", finishPlay) } }),
    ], { gap: "8" }),
  ], { gap: "10" })] };
}

function playAgain() {
  var p = app.state.play;
  back();
  startMatch(p.match.game, p.room, p.match.settings);
}

function finishPlay() {
  var p = app.state.play;
  app.set({ play: null });
  back();
  if (p && p.room) loadRoom(p.room);
  loadGarage();
}

function quitMatch() {
  var p = app.state.play;
  // Leaving counts as a loss only once the game itself says so (arena_stop
  // makes it report "abandoned"); the Scene3D going away stops it.
  app.set({ play: null });
  back();
  if (p && p.room) loadRoom(p.room);
}
