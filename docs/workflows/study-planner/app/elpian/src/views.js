/* The three destinations: today (from the calendar), the Jalali calendar,
 * and the plan (counsel, weekly table, charts, advice). */

function greeting() { var h = new Date().getHours(); return h < 12 ? "صبح بخیر" : h < 17 ? "روز بخیر" : "عصر بخیر"; }

function page(s, app, heroChildren, body) {
  return { type: "ListView", children: [C([
    sky([brandRow(s, app)].concat(heroChildren)),
    s.toast ? box({ padding: "0 16" }, [{ type: "Callout", key: "toast", props: { severity: "good", icon: "auto_awesome", text: s.toast } }]) : null,
    box({ padding: compact() ? "0 16 24 16" : "0 24 32 24" }, [C(body, { gap: "16" })]),
  ], { gap: "16" })] };
}

function emptyPlan(s, app) {
  return page(s, app, [W("سلام! بیا برنامه‌ی درسی‌ات را بسازیم", "headlineSmallEmphasized"), W("چند سؤال کوتاه، بعد مشاور هوشمند آسمان برایت برنامه می‌چیند.", "bodyMedium", { style: { color: BRAND.lilac } })], [
    { type: "EmptyState", key: "no_plan", props: { icon: "auto_awesome", title: "هنوز برنامه‌ای نداری",
      text: "پایه و رشته‌ات، هدفت، چالش‌هایت و ساعت‌های آزادت را بگو؛ برنامه در تقویمت ثبت می‌شود و هر روز این‌جا می‌بینی‌اش.", action: "شروع کنیم", actionIcon: "auto_awesome" },
      events: { action: app.handler("start_wizard", function () { openWizard(); }) } },
  ]);
}

function sessionRow(x, key, app) {
  var c = catColor(x.category);
  return R([
    box({ width: "46" }, [T(fa(x.start), "labelLarge", { color: "muted", textAlign: "center" })]),
    dot(c, 12),
    X(box({ padding: "10 12", borderRadius: "14", backgroundColor: colors().surfaceContainer, border: { right: { width: 4, color: c } }, opacity: x.done ? 0.6 : 1 }, [R([
      { type: "Icon", props: { icon: TYPE_ICON[x.type] || "menu_book", size: 20, style: { color: c } } },
      X(C([
        T(x.course + (x.weak ? "  ★" : ""), "titleSmallEmphasized", { style: x.done ? { textDecoration: "line-through" } : {} }),
        T(x.type_label + " · " + span(x) + " · " + fa(x.minutes) + " دقیقه" + (x.topic ? " · " + x.topic : ""), "bodySmall", { color: "muted" }),
        x.note ? T(x.note, "bodySmall", { color: "muted" }) : null,
      ], { gap: "2" })),
      { type: "Checkbox", key: key, props: { value: !!x.done }, events: { change: app.handler(key, function () { toggleSession(x); }) } },
    ], { gap: "10" })])),
  ], { gap: "8", alignItems: "center" });
}

// ---------------------------------------------------------------- today

function homeView(s, app) {
  var p = s.plan;
  if (!p) return emptyPlan(s, app);
  var d = todayIso(), day = s.day, name = p.profile.name ? "، " + p.profile.name : "";
  var hero = [W(greeting() + name, "headlineMediumEmphasized"),
    W(jlong(d) + (day && day.sessions.length ? " · " + fa(day.sessions.length) + " جلسه، " + minsFa(day.minutes) : ""), "bodyMedium", { style: { color: BRAND.lilac } })];
  if (!day) return page(s, app, hero, [{ type: "Shimmer", children: [C([box({ height: "120", borderRadius: "20", backgroundColor: colors().surfaceContainerHighest }), box({ height: "220", borderRadius: "20", backgroundColor: colors().surfaceContainerHighest })], { gap: "12" })] }]);
  var ss = day.sessions || [], pct = day.minutes ? Math.round(100 * day.done_minutes / day.minutes) : 0, now = nowMin();
  var next = null;
  for (var i = 0; i < ss.length; i++) if (!ss[i].done && toMin(ss[i].end) > now) { next = ss[i]; break; }
  var inPlan = d >= p.start_date && d <= p.end_date;

  var progress = card([R([
    { type: "Progress", props: { value: pct / 100, variant: "circular", showValue: true, size: "l", thickness: 10 } },
    X(C([T("پیشرفت امروز", "titleMediumEmphasized"), T(minsFa(day.done_minutes) + " از " + minsFa(day.minutes), "bodyMedium", { color: "muted" }), R([streakTag(day.last7), { type: "Spacer" }])], { gap: "4" })),
  ], { gap: "16" })]);

  var nextCard;
  if (next) {
    var inMin = toMin(next.start) - now;
    nextCard = box({ gradient: BRAND.accent, padding: "18", borderRadius: "24" }, [C([
      W(inMin > 0 ? "جلسه‌ی بعدی" : "همین حالا", "labelLarge", { style: { color: "#e0e7ff" } }),
      W(next.course, "headlineSmallEmphasized"),
      W(next.type_label + " · " + span(next), "bodyMedium"),
      next.topic ? W(next.topic, "bodySmall", { style: { color: "#e0e7ff" } }) : null,
      R([pill(inMin > 0 ? minsFa(inMin) + " دیگر" : "در جریان — تمرکز کن", "rgba(255,255,255,0.22)"), { type: "Spacer" }]),
    ], { gap: "4" })]);
  } else {
    var msg = ss.length ? (pct >= 100 ? ["همه‌ی جلسه‌ها انجام شد", "عالی بود؛ حالا استراحت کن."] : ["جلسه‌ی دیگری نمانده", "جلسه‌هایی را که انجام دادی تیک بزن."])
      : inPlan ? ["روز استراحت", "امروز جلسه‌ای نداری. کمی تحرک و خواب کافی، بخشی از برنامه است."] : ["خارج از بازه‌ی برنامه", "برای ادامه، برنامه‌ی تازه بساز."];
    nextCard = box({ gradient: BRAND.accent, padding: "18", borderRadius: "24" }, [C([W("امروز", "labelLarge", { style: { color: "#e0e7ff" } }), W(msg[0], "headlineSmallEmphasized"), W(msg[1], "bodyMedium"),
      !ss.length && !inPlan ? R([{ type: "Button", key: "home_new", props: { text: "برنامه‌ی تازه", variant: "tonal", icon: "auto_awesome" }, events: { tap: app.handler("home_new", function () { openWizard(); }) } }, { type: "Spacer" }]) : null], { gap: "4" })]);
  }

  var tips = [];
  p.advice.forEach(function (c) { c.tips.forEach(function (t) { tips.push({ t: t, title: c.title }); }); });
  var tip = tips.length ? tips[jdnOfIso(d) % tips.length] : null;
  var last7 = day.last7.map(function (x) { return { day: DAY_FA[dayKey(x.date)], planned: x.minutes, done: x.done_minutes }; });

  var timeline = card([sectionTitle("برنامه‌ی امروز", jshort(d)),
    ss.length ? C(ss.map(function (x, i) { return sessionRow(x, "today_" + x.id, app); }), { gap: "8" }) : T("امروز در تقویمت جلسه‌ای ثبت نشده است.", "bodyMedium", { color: "muted" })]);
  var side = C([
    card([sectionTitle("هفت روز گذشته"), { type: "Chart", props: { type: "bar", data: last7, x: "day", height: 150, legend: true,
      series: [{ field: "done", label: "انجام‌شده", color: BRAND.primary }, { field: "planned", label: "برنامه", color: "#c7d2fe" }] } }]),
    tip ? card([R([{ type: "Icon", props: { icon: "lightbulb", size: 26, style: { color: BRAND.warn } } }, X(C([T("نکته‌ی امروز", "titleSmallEmphasized"), T(tip.t, "bodyMedium"), T(tip.title, "labelSmall", { color: "muted" })], { gap: "4" }))], { alignItems: "flex-start" })]) : null,
  ], { gap: "16" });

  var top = compact() ? C([progress, nextCard], { gap: "16" }) : R([X(progress, 6), X(nextCard, 5)], { alignItems: "stretch", gap: "16" });
  var bottom = compact() ? C([timeline, side], { gap: "16" }) : R([X(timeline, 2), X(side, 1)], { alignItems: "flex-start", gap: "16" });
  return page(s, app, hero, [top, bottom]);
}

function streakTag(last7) {
  var n = 0;
  if (last7[6].done_minutes > 0) n++;
  for (var i = last7.length - 2; i >= 0; i--) { var x = last7[i]; if (!x.minutes) continue; if (x.done_minutes > 0) n++; else break; }
  return { type: "Tag", props: { text: n ? fa(n) + " روز پشت سر هم" : "امروز زنجیره را شروع کن", icon: "local_fire_department", status: n ? "warning" : "info" } };
}

// ---------------------------------------------------------------- calendar

function calendarView(s, app) {
  var p = s.plan;
  if (!p) return emptyPlan(s, app);
  var c = s.cal, days = s.calDays || {}, t = todayIso(), sel = s.calSel || t;
  var first = j2d(c.jy, c.jm, 1), len = monthLength(c.jy, c.jm), lead = DAYS.indexOf(dayKeyOfJdn(first));
  var cells = [];
  for (var i = -lead; i < len; i++) cells.push(first + i);
  while (cells.length % 7) cells.push(cells[cells.length - 1] + 1);
  var weeks = [];
  for (var k = 0; k < cells.length; k += 7) weeks.push(cells.slice(k, k + 7));

  function cell(jdn) {
    var iso = isoOfJdn(jdn), j = d2j(jdn), out = j.jm !== c.jm, ss = days[iso] || [];
    var inPlan = iso >= p.start_date && iso <= p.end_date, total = 0, done = 0;
    ss.forEach(function (x) { total += x.minutes; if (x.done) done++; });
    var isSel = iso === sel, isToday = iso === t;
    return X({ type: "Container", key: "day_" + iso, props: { style: {
      minHeight: compact() ? "58" : "78", padding: "5", borderRadius: "12", opacity: out ? 0.38 : 1,
      backgroundColor: isSel ? "rgba(91,91,214,0.16)" : colors().surfaceContainer,
      borderWidth: isToday ? 2 : 0, borderColor: isToday ? BRAND.primary : "#00000000" } },
      events: { tap: app.handler("day_" + iso, function (e, app) { app.set({ calSel: iso }); }) },
      children: [C([
        T(fa(j.jd), "labelLarge", { textAlign: "center", color: isToday ? "primary" : undefined }),
        C(ss.slice(0, 4).map(function (x) { return box({ height: "4", borderRadius: "3", backgroundColor: catColor(x.category), opacity: x.done ? 0.35 : 1 }); }), { gap: "2" }),
        compact() ? null : T(ss.length ? (done === ss.length ? "✓ " : "") + hoursFa(total) + " س" : inPlan ? "استراحت" : "", "labelSmall", { textAlign: "center", color: "muted" }),
      ], { gap: "3" })] });
  }
  var head = R(DAYS.map(function (d) { return X(T(compact() ? DAY_FA[d].charAt(0) : DAY_FA[d], "labelMedium", { textAlign: "center", color: "muted" })); }), { gap: "4" });
  var grid = C([head].concat(weeks.map(function (w) { return R(w.map(cell), { gap: "4", alignItems: "stretch" }); })), { gap: "4" });

  var selSessions = days[sel] || [];
  var cats = [];
  p.stats.per_course.forEach(function (x) { if (cats.indexOf(x.category) < 0) cats.push(x.category); });
  var month = card([
    R([{ type: "IconButton", key: "cal_prev", props: { icon: "chevron_right", tooltip: "ماه قبل", variant: "tonal" }, events: { tap: app.handler("cal_prev", function () { shiftMonth(-1); }) } },
       X(T(JMONTHS[c.jm - 1] + " " + fa(c.jy), "titleLargeEmphasized")),
       { type: "Button", key: "cal_today", props: { text: "امروز", variant: "tonal", size: "xs" }, events: { tap: app.handler("cal_today", function () { var j = jOf(todayIso()); app.set({ cal: { jy: j.jy, jm: j.jm }, calSel: todayIso() }); loadCalendar(); }) } },
       { type: "IconButton", key: "cal_next", props: { icon: "chevron_left", tooltip: "ماه بعد", variant: "tonal" }, events: { tap: app.handler("cal_next", function () { shiftMonth(1); }) } }]),
    grid,
    { type: "Wrap", props: { style: { gap: "12" } }, children: cats.map(function (k) { return R([dot(catColor(k), 10), T(s.meta.categories[k] || k, "labelSmall", { color: "muted" })], { gap: "6" }); }) },
  ]);
  var detail = card([T(jlong(sel), "titleMediumEmphasized"),
    selSessions.length ? C(selSessions.map(function (x) { return sessionRow(x, "cal_" + x.id, app); }).concat([T(fa(selSessions.length) + " جلسه · " + minsFa(selSessions.reduce(function (a, x) { return a + x.minutes; }, 0)), "bodySmall", { color: "muted" })]), { gap: "8" })
      : T(sel >= p.start_date && sel <= p.end_date ? "روز استراحت" : "در این روز برنامه‌ای ثبت نشده است.", "bodyMedium", { color: "muted" })]);
  var hero = [W("تقویم مطالعه", "headlineMediumEmphasized"), W("برنامه از " + jshort(p.start_date) + " تا " + jshort(p.end_date) + " در تقویمت ثبت شده است.", "bodyMedium", { style: { color: BRAND.lilac } })];
  return page(s, app, hero, [compact() ? C([month, detail], { gap: "16" }) : R([X(month, 2), X(detail, 1)], { alignItems: "flex-start", gap: "16" })]);
}

function shiftMonth(n) {
  var c = app.state.cal, m = c.jm + n, y = c.jy;
  if (m < 1) { m = 12; y--; }
  if (m > 12) { m = 1; y++; }
  app.set({ cal: { jy: y, jm: m } });
  loadCalendar();
}

// ---------------------------------------------------------------- plan

function planView(s, app) {
  var p = s.plan;
  if (!p) return emptyPlan(s, app);
  var st = p.stats, pr = p.profile, by = p.generated_by || {};
  var tables = p.weeks_detail && p.weeks_detail.length ? p.weeks_detail : [p.timetable];
  var wt = Math.min(s.weekTab || 0, tables.length - 1), tt = tables[wt];
  var hero = [W("برنامه‌ی " + pr.grade_name + (pr.field_name ? " · " + pr.field_name : ""), "headlineMediumEmphasized"),
    W(fa(p.weeks) + " هفته، از " + jlong(p.start_date) + " · هدف: " + pr.goal_titles.concat(pr.goal_note ? [pr.goal_note] : []).join("، "), "bodyMedium", { style: { color: BRAND.lilac } })];

  var counsel = { type: "Card", props: { tone: "primary", style: { padding: "18" } }, children: [R([
    box({ width: "52", height: "52", borderRadius: "16", gradient: BRAND.sky }, [{ type: "Center", children: [{ type: "Icon", props: { icon: "support_agent", size: 28, style: { color: "#ffffff" } } }] }]),
    X(C([T("پیام مشاور", "titleMediumEmphasized"),
      T(by.kind === "agent" ? "ساخته‌شده توسط مشاور هوشمند «برنامه‌ریز» در آسمان" + (by.rounds > 1 ? " · " + fa(by.rounds) + " دور بازبینی تا رعایت همه‌ی قوانین" : "") : "پیش‌نویس الگوریتمی (حالت آزمایشی)", "labelSmall", { color: "muted" }),
      T(p.summary, "bodyLarge")], { gap: "4" })),
  ], { alignItems: "flex-start", gap: "14" })] };

  var kpis = { type: "ResponsiveGrid", props: { minColumnWidth: 150, gap: 12 }, children: [
    { label: "ساعت مطالعه در هفته", value: hoursFa(st.week_minutes), icon: "schedule" },
    { label: "جلسه در هفته", value: fa(st.sessions), icon: "event_note" },
    { label: "دقیقه تمرکز + استراحت", value: fa(p.settings.focus) + " + " + fa(p.settings.break), icon: "timer" },
    { label: "روز مطالعه" + (p.rest_day ? " · استراحت: " + DAY_FA[p.rest_day] : ""), value: fa(st.study_days), icon: "calendar_month" },
  ].map(function (k) { return card([R([{ type: "Icon", props: { icon: k.icon, size: 22, style: { color: BRAND.primary } } }, { type: "Spacer" }]), T(k.value, "headlineMediumEmphasized"), T(k.label, "labelMedium", { color: "muted" })], { gap: "4" }); }) };

  function sessionCard(x) {
    var c = catColor(x.category);
    return box({ padding: "7 9", borderRadius: "10", backgroundColor: colors().surfaceContainerHigh, border: { right: { width: 3, color: c } } }, [C([
      T(x.course + (x.weak ? " ★" : ""), "labelLarge", { maxLines: 2 }), T(span(x), "labelSmall", { color: "muted" }), T(x.type_label, "labelSmall", { color: "muted" }),
      x.topic ? T(x.topic, "labelSmall", { color: "muted", maxLines: 2 }) : null], { gap: "1" })]);
  }
  var restCell = function (d) { return box({ padding: "10", borderRadius: "10", backgroundColor: "rgba(16,163,127,0.10)" }, [T(p.rest_day === d ? "استراحت" : "—", "labelMedium", { textAlign: "center", style: { color: BRAND.ok } })]); };
  var table;
  if (compact()) {
    table = C(DAYS.map(function (d) {
      return C([T(DAY_FA[d], "titleSmallEmphasized", { color: "muted" }), tt[d].length ? { type: "Wrap", props: { style: { gap: "6" } }, children: tt[d].map(sessionCard) } : restCell(d)], { gap: "6" });
    }), { gap: "12" });
  } else {
    table = R(DAYS.map(function (d) { return X(C([T(DAY_FA[d], "labelLarge", { textAlign: "center", color: "muted" })].concat(tt[d].length ? tt[d].map(sessionCard) : [restCell(d)]), { gap: "6" })); }), { alignItems: "flex-start", gap: "6" });
  }
  var weekCard = card([
    R([X(T("جدول هفتگی", "titleMediumEmphasized")), tables.length > 1 ? { type: "SegmentedButton", key: "week_tab", props: { selected: String(wt), size: "s",
      segments: tables.map(function (_, i) { return { value: String(i), label: "هفته‌ی " + fa(i + 1) }; }).reverse() }, events: { change: app.handler("week_tab", function (e, app) { app.set({ weekTab: +e.value }); }) } }
      : T("هر هفته تکرار می‌شود", "labelMedium", { color: "muted" })]),
    table,
    p.resting && p.resting[wt] && p.resting[wt].length ? T("این هفته نوبت استراحت این دروس است: " + p.resting[wt].join("، "), "bodySmall", { color: "muted" }) : null,
  ]);

  var donut = card([sectionTitle("سهم هر درس", "هفته‌ی اول"), { type: "Chart", props: { type: "donut", height: 240, label: "name", value: "minutes", legend: true,
    data: st.per_course.map(function (x) { return { name: x.name, minutes: x.minutes, color: catColor(x.category) }; }) } }]);
  var perDay = card([sectionTitle("زمان مطالعه در روزهای هفته"), { type: "Chart", props: { type: "bar", horizontal: true, height: 220, x: "name",
      series: [{ field: "hours", label: "ساعت", color: BRAND.primary2 }], data: st.per_day.map(function (d) { return { name: d.name, hours: Math.round(d.minutes / 6) / 10 }; }) } },
    sectionTitle("نوع جلسه‌ها"),
    { type: "SegmentedBar", props: { showPercent: true, legend: true, data: st.per_type.map(function (t) { return { label: t.label, value: t.minutes, color: TYPE_HEX[t.type] }; }) } }]);

  var kinds = { summary: "خلاصه", help: "کمک", notice: "نکته", counsel: "مشاور", goal: "هدف", science: "پایه‌ی علمی" };
  var icons = { summary: "map", help: "volunteer_activism", notice: "push_pin", counsel: "support_agent", goal: "flag", science: "science" };
  var advice = { type: "ResponsiveGrid", props: { minColumnWidth: 300, gap: 14 }, children: p.advice.map(function (a, i) {
    return { type: "Card", key: "adv_" + i, props: { variant: a.kind === "counsel" ? "outlined" : "filled", tone: a.kind === "help" ? "error" : undefined, style: { padding: "16" } }, children: [C([
      R([{ type: "Icon", props: { icon: icons[a.kind] || "info", size: 22, style: { color: a.kind === "help" ? undefined : BRAND.primary } } }, X(T(a.title, "titleSmallEmphasized")), { type: "Tag", props: { text: kinds[a.kind] || "", variant: "tonal" } }]),
      a.body ? T(a.body, "bodyMedium") : null,
      a.tips.length ? C(a.tips.map(function (t) { return T("• " + t, "bodyMedium"); }), { gap: "3" }) : null,
      a.sources.length ? { type: "Divider" } : null,
      a.sources.length ? T(a.sources.map(function (x) { return x.text; }).join("\n"), "labelSmall", { color: "muted", textAlign: "left" }) : null,
    ], { gap: "8" })] };
  }) };

  return page(s, app, hero, [
    counsel, kpis, weekCard,
    compact() ? C([donut, perDay], { gap: "16" }) : R([X(donut), X(perDay)], { alignItems: "flex-start", gap: "16" }),
    T("مشاوره و توصیه‌ها", "headlineSmallEmphasized"),
    advice,
    T("منبع فهرست دروس: " + s.meta.source.publisher + " — " + String(s.meta.source.url).replace("https://", "") + ". توصیه‌ها جایگزین مشاوره‌ی تخصصی نیستند.", "bodySmall", { color: "muted" }),
  ]);
}
