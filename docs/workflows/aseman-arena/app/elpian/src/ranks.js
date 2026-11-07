/* Leaderboards (overall by experience, and per game: chess by Elo rating,
 * score games by best score; all time or this week), and profiles: a
 * person's level, record, ratings and ranks, trophies, recent matches and
 * rooms — with friend, message and edit actions. */

function ranksView(s, app) {
  var b = s.board, games = (s.store && s.store.games) || [];
  var gameTabs = [{ value: "", label: "Overall" }].concat(games.map(function (g) { return { value: g.slug, label: g.title }; }));
  var body;
  if (s.boardError) body = problem(app, "board_retry", s.boardError, loadBoard);
  else if (!b) body = loading("Counting the scores…");
  else if (!b.rows.length) body = empty(app, "board_empty", "emoji_events", "No one ranked yet", "Finish a match to put your name on the board.", null, null);
  else {
    var metric = function (r) { return !b.game ? r.xp : b.period === "week" ? r.week_score : b.game === "arena-chess" ? r.rating : r.best_score; };
    var unit = !b.game ? "XP" : b.period === "week" ? "points this week" : b.game === "arena-chess" ? "Elo" : "best score";
    var podium = b.rows.slice(0, 3);
    body = C([
      R(podium.map(function (r, i) {
        return X({ type: "Card", key: hk("podium", r.handle), props: { tone: i === 0 ? "primary" : undefined, variant: i === 0 ? undefined : "filled", style: { padding: "12" } },
          events: { tap: app.handler(hk("podium", r.handle), function () { openProfile(r.handle); }) },
          children: [C([T(["1st", "2nd", "3rd"][i], "labelLarge"), avatar(r, i === 0 ? 52 : 44), T(r.name, "titleSmallEmphasized", { maxLines: 1, overflow: "ellipsis", textAlign: "center" }), T(n(metric(r)), "titleMedium", { textAlign: "center" })], { alignItems: "center", gap: "6" })] });
      }), { gap: "8", alignItems: "stretch" }),
      b.me && b.me.rank ? { type: "Callout", props: { severity: "info", title: "You are #" + b.me.rank, text: b.game === "arena-chess" ? "Rating " + b.me.rating.rating + " · " + b.me.rating.wins + " wins in " + b.me.rating.games + " games" : "Best score " + n(b.me.rating.best_score) + " · " + b.me.rating.wins + " wins", icon: "trending_up" } } : null,
      { type: "ListGroup", children: b.rows.map(function (r) {
        return { type: "ListTile", key: hk("rank", r.handle), props: { overline: "#" + r.rank, title: r.name, subtitle: "@" + r.handle + " · level " + r.level + (r.title ? " · " + r.title : ""), leadingAvatar: r.name, trailingText: n(metric(r)) + " " + unit.split(" ")[0] },
          events: { tap: app.handler(hk("rank", r.handle), function () { openProfile(r.handle); }) } };
      }) },
    ], { gap: "14" });
  }
  return C([topBar(s, app, null), X(page([
    title("Leaderboards", "The best of the Arena"),
    { type: "Scroll", props: { direction: "horizontal" }, children: [{ type: "SegmentedButton", key: "board_game", props: { selected: s.boardGame || "", segments: gameTabs },
      events: { change: app.handler("board_game", function (e) { app.set({ boardGame: e.value, board: null }); loadBoard(); }) } }] },
    s.boardGame ? { type: "SegmentedButton", key: "board_period", props: { selected: s.boardPeriod, segments: [{ value: "all", label: "All time" }, { value: "week", label: "This week" }] },
      events: { change: app.handler("board_period", function (e) { app.set({ boardPeriod: e.value, board: null }); loadBoard(); }) } } : null,
    body,
  ]))], { gap: "0" });
}

// --- profiles -------------------------------------------------------------

function openProfile(handle) {
  push({ name: "profile", handle: handle });
  app.set({ profile: null, profileError: null, editing: false });
  loadProfile(handle);
}

function loadProfile(handle) {
  api("profiles/" + encodeURIComponent(handle)).then(function (p) { app.set({ profile: p }); }).catch(function (e) { app.set({ profileError: errText(e) }); });
}

function profileView(s, app) {
  var p = s.profile;
  if (!p) return C([subBar(app, "profile", "Profile"), X(s.profileError ? box({ padding: "16" }, [problem(app, "profile_retry", s.profileError, function () { loadProfile(top().handle); })]) : loading())], { gap: "0" });
  var me = s.cfg.me && s.cfg.me.handle === p.handle;
  if (me && s.editing) return editProfileView(s, app, p);
  var winRate = p.matches ? p.wins / p.matches : 0;
  var actions = me ? [{ type: "Button", key: "profile_edit", props: { text: "Edit", icon: "edit", variant: "tonal" }, events: { tap: app.handler("profile_edit", function () { app.set({ editing: true, _pName: p.name, _pTitle: p.title, _pBio: p.bio, pColor: p.color }); }) } }]
    : signedIn() ? friendActions(app, p) : [];
  return C([subBar(app, "profile", p.name, "@" + p.handle), X(page([
    box({ gradient: { colors: [hex(p.color), "#10131c"], begin: "topLeft", end: "bottomRight" }, padding: "20", borderRadius: "28" }, [C([
      R([avatar(p, 64), X(C([T(p.name, "headlineSmallEmphasized", { style: { color: "#ffffff" } }), T("@" + p.handle + (p.title ? " · " + p.title : ""), "bodyMedium", { style: { color: "#ffffffcc" } }),
        p.online ? { type: "Tag", props: { text: "online", status: "good", dot: true } } : T("seen " + ago(p.last_seen) + " ago", "labelSmall", { style: { color: "#ffffff99" } })], { gap: "4" }))]),
      p.bio ? T(p.bio, "bodyMedium", { style: { color: "#ffffffdd" } }) : null,
    ], { gap: "12" })]),
    actions.length ? R(actions, { gap: "8" }) : null,
    card([levelBar(p.progress)]),
    { type: "ResponsiveGrid", props: { minColumnWidth: 140, gap: 12 }, children: [
      card([{ type: "Stat", props: { label: "Matches", value: p.matches, icon: "sports_esports", format: "integer" } }]),
      card([{ type: "Stat", props: { label: "Wins", value: p.wins, icon: "emoji_events", format: "integer" } }]),
      card([{ type: "Stat", props: { label: "Win rate", value: winRate, icon: "insights", format: "percent" } }]),
      card([{ type: "Stat", props: { label: "Best streak", value: p.best_streak, icon: "local_fire_department", format: "integer" } }]),
    ] },
    p.ratings.length ? section("Ratings", null, [{ type: "ListGroup", children: p.ratings.map(function (r) {
      return { type: "ListTile", key: hk("prating", r.game), props: { title: r.title, subtitle: r.wins + " wins · " + r.draws + " draws · " + r.games + " games", leading: "trending_up",
        trailingText: (r.game === "arena-chess" ? r.rating + " Elo" : n(r.best_score) + " best") + (r.rank ? " · #" + r.rank : "") },
        events: { tap: app.handler(hk("prating", r.game), function () { openGame(r.game); }) } }; }) }]) : null,
    section("Trophies", p.achievements.filter(function (a) { return a.unlocked; }).length + " of " + p.achievements.length, [
      { type: "ResponsiveGrid", props: { minColumnWidth: 150, gap: 10 }, children: p.achievements.map(function (a) {
        return { type: "Card", key: hk("pach", a.id), props: { variant: a.unlocked ? "filled" : "outlined", style: { padding: "12", opacity: a.unlocked ? 1 : 0.55 } }, children: [C([
          R([{ type: "Icon", props: { icon: a.unlocked ? a.icon : "lock", size: 22 } }, X(T(a.title, "titleSmallEmphasized", { maxLines: 1, overflow: "ellipsis" }))], { gap: "8" }),
          T(a.desc, "bodySmall", { color: "muted", maxLines: 2 })], { gap: "6" })] };
      }) }]),
    p.recent.length ? section("Recent matches", null, [{ type: "ListGroup", children: p.recent.map(function (m) {
      var g = gameBySlug(m.game);
      return { type: "ListTile", key: hk("precent", m.id), props: { title: (g ? g.title : m.game) + " — " + m.outcome, subtitle: n(m.score) + " pts · " + signed(m.xp) + " XP" + (m.rating_change ? " · " + signed(m.rating_change) + " rating" : ""),
        leading: m.outcome === "win" ? "emoji_events" : m.outcome === "draw" ? "handshake" : "close", trailingText: ago(m.ended_at) } }; }) }]) : null,
    p.rooms.length ? section("Rooms", null, [{ type: "ListGroup", children: p.rooms.map(function (r) {
      return { type: "ListTile", key: hk("proom", r.id), props: { title: r.name, subtitle: r.game_title + " · " + r.members + " members", leading: "groups", trailing: "chevron_right" },
        events: { tap: app.handler(hk("proom", r.id), function () { openRoom(r.id); }) } }; }) }]) : null,
  ]))], { gap: "0" });
}

function friendActions(app, p) {
  var st = p.friendship || "none";
  var out = [];
  if (st === "none") out.push({ type: "Button", key: "pf_add", props: { text: "Add friend", icon: "person_add" }, events: { tap: app.handler("pf_add", function () { befriend(p.handle); }) } });
  if (st === "incoming") out.push({ type: "Button", key: "pf_accept", props: { text: "Accept request", icon: "check" }, events: { tap: app.handler("pf_accept", function () { acceptFriend(p.handle, true); }) } });
  if (st === "requested") out.push({ type: "Tag", props: { text: "Request sent", status: "info" } });
  if (st === "friends") out.push({ type: "Tag", props: { text: "Friends", icon: "check", status: "good" } });
  out.push({ type: "Button", key: "pf_msg", props: { text: "Message", icon: "chat", variant: "tonal" }, events: { tap: app.handler("pf_msg", function () { openDM(p.handle); }) } });
  return out;
}

function editProfileView(s, app, p) {
  var palette = ["#6aa8ff", "#ff9a5c", "#5ce1c2", "#ffd166", "#c38bff", "#ff6b8b", "#7bd88f", "#f2f2f2"];
  return C([subBar(app, "profile", "Edit profile"), X(page([
    app.input("pe_name", "_pName", { label: "Name", icon: "person", live: true }),
    app.input("pe_title", "_pTitle", { label: "Title", hint: "Rookie, Tactician, Sharpshooter…", icon: "military_tech" }),
    app.input("pe_bio", "_pBio", { label: "About you", multiline: true, maxLines: 4 }),
    section("Colour", null, [{ type: "Wrap", props: { style: { gap: "10" } }, children: palette.map(function (c) {
      return { type: "InkWell", key: hk("pe_color", c.slice(1)), events: { tap: app.handler(hk("pe_color", c.slice(1)), function () { app.set({ pColor: c }); }) },
        children: [box({ width: "40", height: "40", borderRadius: "20", backgroundColor: c, border: s.pColor === c ? "3px solid " + (colors().onSurface || "#000000") : undefined })] };
    }) }]),
    R([
      X({ type: "Button", key: "pe_save", props: { text: "Save", icon: "check", fullWidth: true, disabled: (s._pName || "").trim().length < 2 }, events: { tap: app.handler("pe_save", saveProfile) } }),
      X({ type: "Button", key: "pe_cancel", props: { text: "Cancel", variant: "text", fullWidth: true }, events: { tap: app.handler("pe_cancel", function () { app.set({ editing: false }); }) } }),
    ], { gap: "10" }),
  ]))], { gap: "0" });
}

function saveProfile() {
  var s = app.state;
  apiPatch("me", { name: s._pName, title: s._pTitle || "", bio: s._pBio || "", color: s.pColor }).then(function (p) {
    var cfg = Object.assign({}, app.state.cfg, { me: Object.assign({}, app.state.cfg.me, { name: p.name, color: p.color, title: p.title }) });
    app.set({ profile: p, editing: false, cfg: cfg, toast: "Profile saved" });
  }).catch(function (e) { app.fail(e); });
}
