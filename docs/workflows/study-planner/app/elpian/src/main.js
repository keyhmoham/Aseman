/* آسمان‌درس — the app: destinations, the wizard, the agent at work, and the
 * phone widget with today's progress and the next session. */

var J0 = jOf(todayIso());

var app = App.create({
  state: { meta: null, plan: null, booted: false, bootError: null, view: "home", wizard: null, thinking: null,
           day: null, dayIso: null, cal: { jy: J0.jy, jm: J0.jm }, calDays: {}, calSel: null, weekTab: 0, toast: null, _newCourse: "" },

  view: function (s, app) {
    if (!s.booted || !s.meta) {
      if (s.bootError) return { type: "Scaffold", children: [box({ padding: "24" }, [C([
        { type: "Callout", props: { severity: "critical", title: "سرور در دسترس نیست", text: s.bootError } },
        { type: "Button", key: "boot_retry", props: { text: "تلاش دوباره", icon: "refresh", variant: "tonal" }, events: { tap: app.handler("boot_retry", function (e, app) { app.set({ bootError: null }); loadAll(); }) } }])])] };
      return { type: "Scaffold", children: [C([sky([brandRow(s, app), W("در حال آماده‌سازی…", "bodyMedium", { style: { color: BRAND.lilac } })]),
        box({ padding: "16" }, [{ type: "Shimmer", children: [C([box({ height: "140", borderRadius: "20", backgroundColor: colors().surfaceContainerHighest }), box({ height: "220", borderRadius: "20", backgroundColor: colors().surfaceContainerHighest })], { gap: "12" })] }])], { gap: "16" })] };
    }
    if (s.thinking) return thinkingView(s, app);
    if (s.wizard) return wizardView(s, app);
    var body = s.view === "calendar" ? calendarView(s, app) : s.view === "plan" ? planView(s, app) : homeView(s, app);
    var children = [body];
    if (compact()) children.push({ type: "NavigationBar", key: "nav", props: { selected: navIndex(s.view), items: navItems().map(function (n) { return { icon: n.icon, label: n.label }; }) },
      events: { change: app.handler("nav", function (e) { go(navItems()[e.value].id); }) } });
    return { type: "Scaffold", children: children };
  },

  init: function (app) {
    loadAll();
    app.every("tick", 5000, tick);
  },

  widget: {
    size: "medium",
    shape: "card",
    refreshMs: 60000,
    refresh: function () { if (app.state.plan) loadDay(); else loadAll(); },
    view: function (s) {
      var size = (Aseman.env().widget || {}).size || "medium";
      if (!s.booted) return { type: "Shimmer", children: [box({ height: "52", borderRadius: "16", backgroundColor: colors().surfaceContainerHighest })] };
      if (!s.plan) return R([X(C([T("آسمان‌درس", "titleSmallEmphasized"), T("برنامه‌ی درسی‌ات را بساز", "bodySmall", { color: "muted" })], { gap: "2" }))], { padding: "14" });
      var day = s.day || { sessions: [], minutes: 0, done_minutes: 0 }, ss = day.sessions || [];
      var done = ss.filter(function (x) { return x.done; }).length, now = nowMin(), next = null;
      for (var i = 0; i < ss.length; i++) if (!ss[i].done && toMin(ss[i].end) > now) { next = ss[i]; break; }
      return R([
        X({ type: "Stat", props: { label: "جلسه‌های امروز", value: fa(done) + " از " + fa(ss.length), icon: "auto_awesome", size: "compact" } }),
        size === "small" ? null : C([
          { type: "Tag", props: { text: next ? next.course + " · " + fa(next.start) : ss.length ? "همه انجام شد" : "روز استراحت", status: next ? "info" : "good" } },
          { type: "Progress", props: { value: day.minutes ? day.done_minutes / day.minutes : 0, showValue: false, thickness: 6 } },
        ], { gap: "6" }),
      ], { padding: "14" });
    },
  },
});
