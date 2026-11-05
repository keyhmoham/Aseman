/* The app's server: the same API as the web page. The person is the Aseman
 * person using the app ("me": the gateway names them to the server). */

function apiGet(path, query) { return Aseman.fetch("api/" + path, query ? { query: query } : {}).then(function (r) { return r.json; }); }
function apiSend(method, path, body) { return Aseman.fetch("api/" + path, { method: method, body: body }).then(function (r) { return r.json; }); }

function errText(e) {
  var j = e && e.json;
  return (j && j.error) || (e && e.message) || "خطا در ارتباط با سرور";
}

function loadAll() {
  apiGet("meta").then(function (meta) {
    app.set({ meta: meta });
    return apiGet("profiles/me");
  }).then(function (p) {
    var plan = p && p.exists ? p.plan : null;
    app.set({ plan: plan, booted: true });
    if (!plan && !app.state.wizard && !app.isWidget()) openWizard();
    loadDay();
  }).catch(function (e) { app.set({ booted: true, bootError: errText(e) }); });
}

function loadDay() {
  if (!app.state.plan) return;
  var d = todayIso();
  apiGet("profiles/me/day/" + d).then(function (day) { app.set({ day: day, dayIso: d }); })
    .catch(function (e) { app.set({ dayError: errText(e) }); });
}

function loadCalendar() {
  var c = app.state.cal;
  var first = j2d(c.jy, c.jm, 1);
  var lead = DAYS.indexOf(dayKeyOfJdn(first));
  var from = isoOfJdn(first - lead), to = isoOfJdn(first + monthLength(c.jy, c.jm) + 13);
  apiGet("profiles/me/calendar", { from: from, to: to }).then(function (r) { app.set({ calDays: r.days || {} }); })
    .catch(function (e) { app.fail(e); });
}

function toggleSession(x) {
  var done = !x.done;
  x.done = done; // the tick shows at once
  app.render();
  apiSend("PATCH", "profiles/me/sessions/" + encodeURIComponent(x.id), { done: done })
    .then(function () { loadDay(); if (app.state.view === "calendar") loadCalendar(); })
    .catch(function (e) { x.done = !done; app.fail(e); });
}

function go(view) {
  if (view === "new") { openWizard(); return; }
  app.set({ view: view, wizard: null });
  if (view === "home") loadDay();
  if (view === "calendar") loadCalendar();
}

// ---- the agent at work: start a job, follow it on the app's timer ----
function generate() {
  var w = app.state.wizard, a = w.a;
  var body = {
    grade: a.grade, field: a.field, goals: a.goals, goal_note: a.goal_note, concerns: a.concerns, concern_note: a.concern_note,
    availability: a.availability, start_date: a.start_date, weeks: a.weeks, name: a.name,
    courses: w.courses.map(function (c) { return { id: c.id, name: c.name, weight: c.weight, category: c.category, weak: !!c.weak }; }),
  };
  app.set({ thinking: { status: "queued", round: 0, error: null, job: null, since: Date.now() } });
  apiSend("POST", "profiles/me/plans", body).then(function (r) {
    app.set({ thinking: Object.assign({}, app.state.thinking, { job: r.job, status: r.status || "queued" }) });
  }).catch(function (e) {
    app.set({ thinking: Object.assign({}, app.state.thinking, { status: "failed", error: errText(e) }) });
  });
}

function poll() {
  var t = app.state.thinking;
  if (!t || !t.job || t.status === "failed" || t.status === "done" || t.polling) return;
  t.polling = true;
  apiGet("jobs/" + t.job, { profile: "me" }).then(function (st) {
    t.polling = false;
    if (st.status === "done") {
      app.set({ thinking: Object.assign({}, t, { status: "done" }) });
      return apiGet("profiles/me").then(function (p) {
        app.set({ plan: p.plan, thinking: null, wizard: null, view: "plan", weekTab: 0, toast: "برنامه ساخته شد و " + fa((p.plan ? p.plan.weeks : 0) * 7) + " روز در تقویمت ثبت شد" });
        loadDay();
      });
    }
    if (st.status === "failed") { app.set({ thinking: Object.assign({}, t, { status: "failed", error: st.error || "ساختن برنامه ناموفق بود" }) }); return; }
    if (Date.now() - t.since > 25 * 60 * 1000) { app.set({ thinking: Object.assign({}, t, { status: "failed", error: "مشاور بیش از حد معمول طول کشید" }) }); return; }
    app.set({ thinking: Object.assign({}, t, { status: st.status, round: st.round }) });
  }).catch(function (e) { t.polling = false; app.set({ thinking: Object.assign({}, t, { status: "failed", error: errText(e) }) }); });
}

function tick() {
  poll();
  var s = app.state;
  s.ticks = (s.ticks || 0) + 1;
  if (s.ticks % 12 === 0 && s.view === "home" && !s.wizard && !s.thinking) loadDay(); // every minute
  if (s.toast && s.ticks % 2 === 0) app.set({ toast: null });
}
