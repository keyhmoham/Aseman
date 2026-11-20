/* The agentic page: a conversation with the Peyda Analyst, who runs the
   GLiNER2 → iran-mcp loop and answers in the thread. The newest exchange is
   always on screen: earlier ones fold away (the engine has no scroll-to-end). */

function chatHeader(s, app) {
  return { type: "Column", props: { style: { padding: "8 12 4 12", gap: "2", alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { gap: "4", alignItems: "center" } }, children: [
      { type: "IconButton", key: "home", props: { icon: "arrow_back", tooltip: "Back to search" },
        events: { tap: app.handler("chat_home", function () { app.set({ mode: "home" }); }) } },
      { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "0" } }, children: [
        T("Peyda", "titleMediumEmphasized"),
        T(s.run ? "Working on it…" : "Agentic search", "labelSmall", { color: "muted" }),
      ] }] },
      { type: "IconButton", key: "hist", props: { icon: "history", tooltip: "Chat history" },
        events: { tap: app.handler("chat_history", function () { loadChats(); app.set({ mode: "history" }); }) } },
      { type: "IconButton", key: "new", props: { icon: "comment", tooltip: "New chat", variant: "tonal" },
        events: { tap: app.handler("chat_new", function () { newChat(); }) } },
    ] },
    { type: "Row", props: { style: { padding: "0 8" } }, children: [agenticSwitch(s, app)] },
  ] };
}

function userBubble(m) {
  return { type: "Row", key: "m_" + m.id, props: { style: { justifyContent: "flex-end" } }, children: [
    { type: "Card", props: { tone: "primary", radius: 20, style: { padding: "10 14", maxWidth: "300" } }, children: [T(m.text, "bodyLarge")] },
  ] };
}

function roundsTrace(rounds, mid) {
  if (!rounds || !rounds.length) { return null; }
  return { type: "Expandable", props: { title: "How I searched · " + rounds.length + (rounds.length === 1 ? " round" : " rounds"), icon: "manage_search", expanded: false }, children: [
    { type: "Column", props: { style: { gap: "8" } }, children: rounds.map(function (r, i) {
      return { type: "Column", key: "round_" + mid + "_" + i, props: { style: { gap: "2" } }, children: [
        T("Round " + r.n + " · " + r.total + " results", "labelLarge"),
        T("“" + r.query + "”", "bodySmall", { color: "muted" }),
        r.reason ? T("Analyst: " + r.reason, "bodySmall", { color: "muted" }) : null,
      ].filter(Boolean) };
    }) },
  ] };
}

function assistantBubble(m) {
  var p = m.payload || {};
  var parts = [
    { type: "Card", props: { variant: "filled", radius: 20, style: { padding: "12 14", gap: "8" } }, children: [{ type: "Markdown", props: { text: m.text } }] },
  ];
  if (p.degraded) {
    parts.push({ type: "Tag", props: { text: "The analyst was unavailable: results shown as they came", status: "warning", icon: "warning" } });
    if (p.degraded_reason) { parts.push(T("Why: " + p.degraded_reason, "bodySmall", { color: "muted" })); }
  }
  (p.cards || []).forEach(function (c, i) { parts.push(Object.assign({}, hitCard(c, c.source), { key: "card_" + m.id + "_" + i })); });
  var trace = roundsTrace(p.rounds, m.id);
  if (trace) { parts.push(trace); }
  if (p.suggestions && p.suggestions.length && m.id === lastAssistantId()) {
    parts.push({ type: "Wrap", props: { style: { gap: "8" } }, children: p.suggestions.map(function (t, i) {
      return { type: "Chip", key: "sg_" + m.id + "_" + i, props: { label: t, variant: "suggestion" }, events: { tap: app.handler("sg_" + m.id + "_" + i, function () { sendMessage(t); }) } };
    }) });
  }
  return { type: "Row", key: "m_" + m.id, props: { style: { gap: "8", alignItems: "flex-start" } }, children: [
    { type: "Avatar", props: { name: "Peyda", size: 32 } },
    { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "8", alignItems: "stretch" } }, children: parts }] },
  ] };
}

function lastAssistantId() {
  var ms = app.state.messages;
  for (var i = ms.length - 1; i >= 0; i--) { if (ms[i].role === "assistant") { return ms[i].id; } }
  return null;
}

function liveCard(s, app) {
  var lines = s.events.map(traceLine).filter(Boolean);
  var last = lines.slice(-4);
  return { type: "Row", key: "live", props: { style: { gap: "8", alignItems: "flex-start" } }, children: [
    { type: "Avatar", props: { name: "Peyda", size: 32 } },
    { type: "Expanded", children: [{ type: "Card", props: { variant: "filled", radius: 20, style: { padding: "12 14", gap: "8" } }, children: [
      { type: "Row", props: { style: { gap: "10", alignItems: "center" } }, children: [
        { type: "LoadingIndicator", props: { size: 28 } },
        { type: "Expanded", children: [T(last.length ? last[last.length - 1] : "Starting…", "bodyMedium")] },
        { type: "Button", key: "cancel", props: { text: "Stop", variant: "text", size: "xs" }, events: { tap: app.handler("cancel", function () { cancelRun(); }) } },
      ] },
      last.length > 1 ? { type: "Column", props: { style: { gap: "2" } }, children: last.slice(0, -1).map(function (l, i) { return T(l, "labelSmall", { color: "muted", maxLines: 2, overflow: "ellipsis" }); }) } : null,
    ].filter(Boolean) }] },
  ] };
}

// Pairs of (user, assistant) so the newest exchange can stay open.
function exchanges(messages) {
  var out = [], cur = null;
  messages.forEach(function (m) {
    if (m.role === "user") { cur = { user: m, replies: [] }; out.push(cur); }
    else if (cur) { cur.replies.push(m); }
  });
  return out;
}

function transcript(s, app) {
  var ex = exchanges(s.messages);
  var keep = 2;
  var hidden = s.showAll ? 0 : Math.max(0, ex.length - keep);
  var nodes = [];
  if (hidden) {
    nodes.push({ type: "Button", key: "earlier", props: { text: "Show " + hidden + " earlier " + (hidden === 1 ? "exchange" : "exchanges"), icon: "expand_less", variant: "text" },
      events: { tap: app.handler("earlier", function () { app.set({ showAll: true }); }) } });
  }
  ex.slice(hidden).forEach(function (x) {
    nodes.push(userBubble(x.user));
    x.replies.forEach(function (r) { nodes.push(assistantBubble(r)); });
  });
  if (s.run || s.sending) { nodes.push(liveCard(s, app)); }
  if (s.chatError && s.chatError !== "signin") {
    nodes.push({ type: "Callout", key: "chat_error", props: { title: "Peyda could not answer", text: s.chatError, severity: "critical", icon: "error" } });
  }
  return nodes;
}

function chatBody(s, app) {
  if (!signedIn() || s.chatError === "signin") {
    return { type: "EmptyState", props: { icon: "lock", title: "Sign in to chat with Peyda", text: "The analyst works on your account. You can still search without it.", action: "Search without the agent", actionIcon: "search" },
      events: { action: app.handler("signin_plain", function () { app.set({ agentic: false, mode: "home", chatError: null }); }) } };
  }
  if (!s.messages.length && !s.run && !s.sending) {
    return { type: "Column", props: { style: { gap: "16", alignItems: "center", padding: "24 16" } }, children: [
      { type: "EmptyState", props: { icon: "auto_awesome", title: "Ask about anything in Iran", text: "Prices, tickets, doctors, homes, news. I will search, check the results and refine the query until it is right." } },
      { type: "Wrap", props: { style: { gap: "8", justifyContent: "center" } }, children: EXAMPLES.slice(0, 3).map(function (ex, i) {
        return { type: "Chip", key: "cx_" + i, props: { label: ex, variant: "suggestion" }, events: { tap: app.handler("cx_" + i, function () { sendMessage(ex); }) } };
      }) },
    ] };
  }
  return { type: "Column", props: { style: { gap: "16", alignItems: "stretch" } }, children: transcript(s, app) };
}

function composer(s, app) {
  var busy = !!(s.run || s.sending);
  var ok = !!(s.composer || "").trim() && !busy && signedIn();
  return { type: "Row", props: { style: { padding: "8 12 12 12", gap: "8", alignItems: "center" } }, children: [
    { type: "Expanded", children: [{ type: "TextField", key: "composer", props: { hint: busy ? "Peyda is working…" : "Message Peyda", value: s.composer, disabled: !signedIn() },
      events: { input: app.handler("composer_input", function (e, app) { app.set({ composer: e.value || "" }); }),
                submit: app.handler("composer_submit", function () { sendMessage(app.state.composer); }) } }] },
    { type: "IconButton", key: "send", props: { icon: "send", variant: "filled", tooltip: "Send", disabled: !ok },
      events: { tap: app.handler("send", function () { sendMessage(app.state.composer); }) } },
  ] };
}

function chatView(s, app) {
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      chatHeader(s, app),
      { type: "Expanded", children: [{ type: "ListView", children: [
        { type: "Column", props: { style: { padding: "8 16 16 16", gap: "16", alignItems: "stretch" } }, children: [chatBody(s, app)] },
      ] }] },
      composer(s, app),
    ] },
  ] };
}
