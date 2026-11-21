/* Peyda: calls to the app's own server (api/…). Nothing here talks to a model. */

function loadInfo() {
  Decillion.fetch("api/info").then(function (r) { app.set({ info: r.json }); }).catch(function () { /* the home page works without it */ });
}

function runSearch(q) {
  q = (q || "").trim();
  if (!q) { return; }
  app.set({ mode: "results", q: q, searching: true, searchError: null, results: null, filter: "all", item: null });
  Decillion.fetch("api/search", { method: "POST", body: { q: q, limit: 8 } })
    .then(function (r) { if (app.state.q === q) { app.set({ results: r.json, searching: false }); } })
    .catch(function (e) { app.set({ searching: false, searchError: errorText(e) }); });
}

function loadChats() {
  if (!signedIn()) { return; }
  Decillion.fetch("api/chats").then(function (r) { app.set({ chats: r.json.chats || [] }); }).catch(function () {});
}

function openChat(id) {
  if (isExpanded()) { loadChats(); }
  app.set({ mode: "chat", chat: id, messages: [], chatError: null, run: null, events: [], showAll: false });
  Decillion.fetch("api/chats/" + id)
    .then(function (r) { if (app.state.chat === id) { app.set({ messages: r.json.messages || [] }); } })
    .catch(function (e) { app.set({ chatError: errorText(e) }); });
}

function newChat(first) {
  if (!signedIn()) { app.set({ mode: "chat", chat: null, messages: [], chatError: "signin" }); return; }
  app.set({ mode: "chat", chat: null, messages: [], chatError: null, run: null, events: [], showAll: false });
  if (isExpanded()) { loadChats(); }
  if (first) { sendMessage(first); }
}

function sendMessage(text) {
  text = (text || "").trim();
  if (!text || app.state.run || app.state.sending) { return; }
  if (!signedIn()) { app.set({ mode: "chat", chatError: "signin" }); return; }
  var messages = app.state.messages.concat([{ id: "local_" + app.state.messages.length, role: "user", text: text, payload: {} }]);
  app.set({ messages: messages, composer: "", sending: true, chatError: null, events: [] });
  var ensure = app.state.chat
    ? Decillion.Task.resolve(app.state.chat)
    : Decillion.fetch("api/chats", { method: "POST", body: {} }).then(function (r) { app.set({ chat: r.json.id }); return r.json.id; });
  ensure
    .then(function (id) { return Decillion.fetch("api/chats/" + id + "/messages", { method: "POST", body: { text: text } }); })
    .then(function (r) { app.set({ run: r.json.run, sending: false }); follow(r.json.run, 0); })
    .catch(function (e) { app.set({ sending: false, run: null, chatError: (e && e.status === 401) ? "signin" : errorText(e) }); });
}

// The run is followed by holding a request open on the server until it has
// something new (Elpian timers tick no faster than every 5 s).
function follow(runId, after) {
  Decillion.fetch("api/runs/" + runId, { query: { after: after, wait: 20 } })
    .then(function (r) {
      if (app.state.run !== runId) { return; }
      var d = r.json;
      var events = app.state.events.concat(d.events || []);
      if (d.status === "running") { app.set({ events: events }); follow(runId, d.next); return; }
      var patch = { run: null, events: [] };
      if (d.status === "done" && d.message) {
        var have = app.state.messages.some(function (m) { return m.id === d.message.id; });
        patch.messages = have ? app.state.messages : app.state.messages.concat([d.message]);
      }
      if (d.status === "error") { patch.chatError = d.error || "Something went wrong. Please try again."; }
      app.set(patch);
      loadChats();
    })
    .catch(function (e) { app.set({ run: null, chatError: errorText(e) }); });
}

function cancelRun() {
  var id = app.state.run;
  if (!id) { return; }
  Decillion.fetch("api/runs/" + id + "/cancel", { method: "POST" }).catch(function () {});
  app.set({ run: null, events: [] });
}

function removeChat(id) {
  Decillion.fetch("api/chats/" + id, { method: "DELETE" })
    .then(function () { app.set({ chats: app.state.chats.filter(function (c) { return c.id !== id; }) }); })
    .catch(function (e) { app.fail(e); });
}
