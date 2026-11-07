/* Shared pieces of the interface: avatars, player rows, game art, the
 * level bar, empty and error states, the top bar of a sub-screen. */

function avatar(u, size) {
  return { type: "Avatar", props: { name: (u && (u.name || u.handle)) || "?", size: size || 40 } };
}

function levelBar(p) {
  p = p || { level: 1, into: 0, span: 100 };
  return C([
    R([T("Level " + p.level, "labelLarge"), X(T(n(p.into) + " / " + n(p.span) + " XP", "labelSmall", { color: "muted", textAlign: "right" }))]),
    { type: "Progress", props: { value: p.span ? p.into / p.span : 0, showValue: false, thickness: 8 } },
  ], { gap: "6" });
}

function onlineTag(u) {
  return u && u.online ? { type: "Tag", props: { text: "online", status: "good", dot: true, variant: "tonal" } } : null;
}

// The game's art: its colour, initial and genre, drawn (no image needed).
function gameArt(g, height) {
  var acc = hex(g.accent || g.game_accent, "#6aa8ff");
  var icon = (g.genre || "") === "board" ? "extension" : (g.genre || "") === "shooter" ? "my_location" : "sports_esports";
  return box({ height: String(height || 96), borderRadius: "20", gradient: { colors: [acc, "#10131c"], begin: "topLeft", end: "bottomRight" }, padding: "14" }, [
    R([
      box({ width: "44", height: "44", borderRadius: "14", backgroundColor: "#00000055", alignItems: "center", justifyContent: "center" }, [
        { type: "Icon", props: { icon: icon, size: 26, style: { color: "#ffffff" } } }]),
      X(C([T(g.title || g.game_title || "", "titleMediumEmphasized", { style: { color: "#ffffff" }, maxLines: 1, overflow: "ellipsis" }),
           T(g.genre ? g.genre.toUpperCase() : "GAME", "labelSmall", { style: { color: "#ffffffcc" } })], { gap: "2" })),
    ], { alignItems: "flex-start" }),
  ]);
}

function stars(v, size) {
  return { type: "Rating", props: { value: Number(v || 0), max: 5, size: size || 16 } };
}

// The top bar of a pushed screen: back, title, actions.
function subBar(app, key, text, sub, actions) {
  return R([
    { type: "IconButton", key: key + "_back", props: { icon: "arrow_back", tooltip: "Back" }, events: { tap: app.handler(key + "_back", function () { back(); }) } },
    X(C([T(text, "titleLargeEmphasized", { maxLines: 1, overflow: "ellipsis" }), sub ? T(sub, "labelMedium", { color: "muted", maxLines: 1, overflow: "ellipsis" }) : null], { gap: "2" })),
  ].concat(actions || []), { padding: "8 12 8 4", gap: "4" });
}

function loading(text) {
  return C([{ type: "LoadingIndicator", props: { size: 48 } }, T(text || "Loading…", "bodyMedium", { color: "muted", textAlign: "center" })], { alignItems: "center", padding: "48", gap: "12" });
}

function problem(app, key, text, retry) {
  return C([
    { type: "Callout", props: { severity: "critical", title: "Something went wrong", text: text } },
    retry ? { type: "Button", key: key, props: { text: "Try again", icon: "refresh", variant: "tonal" }, events: { tap: app.handler(key, retry) } } : null,
  ], { gap: "12" });
}

function empty(app, key, icon, head, text, action, fn) {
  return { type: "EmptyState", key: key, props: { icon: icon, title: head, text: text, action: action || undefined },
           events: action ? { action: app.handler(key, fn) } : undefined };
}

// A player in a list.
function playerTile(app, key, u, trailing, onTap) {
  return { type: "ListTile", key: key, props: { title: u.name || u.handle, subtitle: "@" + u.handle + " · level " + (u.level || 1) + (u.online ? " · online" : ""),
    leadingAvatar: u.name || u.handle, trailingText: trailing || undefined },
    events: { tap: app.handler(key, onTap || function () { openProfile(u.handle); }) } };
}

function signInCard() {
  return card([
    R([{ type: "Icon", props: { icon: "login", size: 28 } }, X(C([T("Sign in to play", "titleMediumEmphasized"),
      T("Your garage, rooms, ratings and friends are waiting. Sign in with your Arena account in this app.", "bodyMedium", { color: "muted" })], { gap: "4" }))]),
  ], {}, { tone: "primary" });
}
