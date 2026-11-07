/* Social: friends (requests both ways, finding players), direct messages,
 * and notifications (friend requests, room invites, achievements, Forge
 * builds). */

function socialView(s, app) {
  if (!signedIn()) return C([topBar(s, app, null), X(page([title("Social", "Friends and messages"), signInCard()]))], { gap: "0" });
  var so = s.social;
  var body = s.socialError ? problem(app, "social_retry", s.socialError, loadSocial) : !so ? loading() : null;
  var u = s.unread || {};
  return C([topBar(s, app, null), box({ padding: "0 16" }, [title("Social", "Friends, messages and alerts")]),
    X(body ? box({ padding: "16" }, [body]) : { type: "Tabs", key: "social_tabs", props: { selected: s.socialTab || 0, tabs: [
      { label: "Friends", icon: "group", badge: so.friends.incoming.length ? String(so.friends.incoming.length) : undefined },
      { label: "Messages", icon: "chat", badge: u.messages ? String(u.messages) : undefined },
      { label: "Alerts", icon: "notifications", badge: u.notifications ? String(u.notifications) : undefined }] },
      events: { change: app.handler("social_tabs", function (e) { app.set({ socialTab: e.value }); if (e.value === 2) markRead(); }) },
      children: [friendsTab(s, app, so), threadsTab(s, app, so), alertsTab(s, app, so)] }),
  ], { gap: "0" });
}

function friendsTab(s, app, so) {
  var f = so.friends;
  var found = s.found || [];
  return { type: "ListView", children: [C([
    R([X(app.input("social_find", "_find", { search: true, hint: "Find players by name or @handle", live: true })),
       { type: "IconButton", key: "social_find_go", props: { icon: "person_search", variant: "tonal", tooltip: "Search", disabled: (s._find || "").trim().length < 2 }, events: { tap: app.handler("social_find_go", findPlayers) } }], { gap: "8" }),
    found.length ? { type: "ListGroup", children: found.map(function (u) { return playerTile(app, hk("found", u.handle), u, "", function () { openProfile(u.handle); }); }) } : null,
    f.incoming.length ? section("Requests", null, [{ type: "ListGroup", children: f.incoming.map(function (u) {
      return { type: "ListTile", key: hk("req", u.handle), props: { title: u.name, subtitle: "@" + u.handle + " wants to be friends", leadingAvatar: u.name, trailing: "check" },
        events: { tap: app.handler(hk("req", u.handle), function () { acceptFriend(u.handle); }) } }; }) }]) : null,
    section("Friends", f.friends.length ? f.friends.filter(function (x) { return x.online; }).length + " online" : null, [f.friends.length ? { type: "ListGroup", children: f.friends.map(function (u) {
      return { type: "ListTile", key: hk("friend", u.handle), props: { title: u.name, subtitle: "@" + u.handle + " · level " + u.level + (u.online ? " · online" : " · " + ago(u.last_seen) + " ago"), leadingAvatar: u.name, trailing: "chat" },
        events: { tap: app.handler(hk("friend", u.handle), function () { openDM(u.handle); }) } }; }) }
      : T("Find players above, or add the people you meet in rooms.", "bodyMedium", { color: "muted" })]),
    f.outgoing.length ? section("Sent", null, [{ type: "Wrap", props: { style: { gap: "8" } }, children: f.outgoing.map(function (u) { return { type: "Chip", key: hk("sent", u.handle), props: { label: "@" + u.handle, icon: "hourglass_top" } }; }) }]) : null,
  ], { padding: "12 16", gap: "16" })] };
}

function threadsTab(s, app, so) {
  if (!so.threads.length) return box({ padding: "16" }, [empty(app, "threads_empty", "chat", "No messages", "Message a friend, or someone you met in a room.", null, null)]);
  return { type: "ListView", children: [box({ padding: "12 16" }, [{ type: "ListGroup", children: so.threads.map(function (t) {
    return { type: "ListTile", key: hk("thread", t.user.handle), props: { title: t.user.name + (t.unread ? " · " + t.unread + " new" : ""), subtitle: t.last ? t.last.text : "", leadingAvatar: t.user.name, trailingText: t.last ? ago(t.last.at) : "" },
      events: { tap: app.handler(hk("thread", t.user.handle), function () { openDM(t.user.handle); }) } };
  }) }])] };
}

function alertsTab(s, app, so) {
  if (!so.notes.length) return box({ padding: "16" }, [empty(app, "alerts_empty", "notifications", "All quiet", "Friend requests, invites and trophies show up here.", null, null)]);
  var icons = { friend: "person_add", invite: "groups", achievement: "emoji_events", forge: "auto_awesome" };
  return { type: "ListView", children: [box({ padding: "12 16" }, [{ type: "ListGroup", children: so.notes.map(function (x) {
    return { type: "ListTile", key: hk("note", x.id), props: { title: x.text, leading: icons[x.kind] || "notifications", trailingText: ago(x.at), selected: !x.read },
      events: { tap: app.handler(hk("note", x.id), function () { openNote(x); }) } };
  }) }])] };
}

function openNote(x) {
  if (x.kind === "invite" && x.data.room) openRoom(x.data.room);
  else if (x.kind === "friend" && x.data.from) openProfile(x.data.from);
  else if (x.kind === "forge" && x.data.project) openForge(x.data.project);
  else if (x.kind === "achievement" && app.state.cfg.me) openProfile(app.state.cfg.me.handle);
}

function markRead() { apiPost("notifications").then(function (r) { app.set({ unread: r.unread }); }).catch(function () {}); }

function findPlayers() {
  api("users?q=" + encodeURIComponent(app.state._find || "")).then(function (r) { app.set({ found: r.users }); }).catch(function (e) { app.fail(e); });
}

function befriend(handle) {
  apiPost("friends", { handle: handle }).then(function (r) {
    app.set({ toast: r.status === "friends" ? "You are now friends" : "Friend request sent" });
    if (app.state.profile) loadProfile(handle);
    loadSocial();
  }).catch(function (e) { app.fail(e); });
}

function acceptFriend(handle, fromProfile) {
  apiPost("friends/" + encodeURIComponent(handle) + "/accept").then(function () {
    app.set({ toast: "You are now friends with @" + handle });
    if (fromProfile) loadProfile(handle);
    loadSocial();
  }).catch(function (e) { app.fail(e); });
}

// --- direct messages --------------------------------------------------------

function openDM(handle) {
  push({ name: "dm", handle: handle });
  app.set({ dm: null, dmError: null });
  loadDM(handle);
}

function loadDM(handle) {
  api("messages/" + encodeURIComponent(handle)).then(function (r) { app.set({ dm: r }); }).catch(function (e) { app.set({ dmError: errText(e) }); });
}

function dmView(s, app) {
  var d = s.dm, handle = top().handle;
  var who = d ? d["with"] : { name: "@" + handle, handle: handle };
  var list = !d ? (s.dmError ? box({ padding: "16" }, [problem(app, "dm_retry", s.dmError, function () { loadDM(handle); })]) : loading())
    : d.messages.length ? { type: "ListView", key: "dm_list", children: d.messages.map(function (m) {
        var mine = !!m.mine;
        return box({ padding: "4 12" }, [R([mine ? { type: "Spacer" } : null,
          { type: "Card", props: { tone: mine ? "primary" : undefined, variant: mine ? undefined : "filled", style: { padding: "10 14", maxWidth: "300" } }, children: [C([T(m.text, "bodyMedium"), T(ago(m.at), "labelSmall", { color: "muted" })], { gap: "2" })] },
          mine ? null : { type: "Spacer" }], { gap: "0" })]);
      }) }
    : C([T("Say hello to " + who.name + ".", "bodyMedium", { color: "muted", textAlign: "center" })], { padding: "24" });
  return C([subBar(app, "dm", who.name, "@" + who.handle + (who.online ? " · online" : ""), [
    { type: "IconButton", key: "dm_profile", props: { icon: "person", tooltip: "Profile" }, events: { tap: app.handler("dm_profile", function () { openProfile(who.handle); }) } }]),
    X(list),
    R([X(app.input("dm_text", "_dmText", { hint: "Message " + who.name, icon: "chat", live: true })),
       { type: "IconButton", key: "dm_send", props: { icon: "send", variant: "filled", tooltip: "Send", disabled: !(s._dmText || "").trim() }, events: { tap: app.handler("dm_send", sendDM) } }], { padding: "8 12", gap: "8" }),
  ], { gap: "0" });
}

function sendDM() {
  var handle = top().handle, text = (app.state._dmText || "").trim();
  if (!text) return;
  app.set({ _dmText: "" });
  apiPost("messages/" + encodeURIComponent(handle), { text: text }).then(function (r) {
    app.set({ dm: Object.assign({}, app.state.dm, { messages: r.messages }) });
  }).catch(function (e) { app.fail(e); });
}
