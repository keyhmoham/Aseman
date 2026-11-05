/* The step-by-step wizard: grade, field (from grade 10), the official
 * courses to confirm, goals, concerns, the free hours, and the start. */

var HOURS = [];
for (var hh = 6; hh <= 23; hh++) HOURS.push(hh);

function openWizard() {
  var prev = app.state.plan && app.state.plan.profile;
  app.set({ view: "new", thinking: null, wizard: {
    step: 0, courses: null, courseKey: null, source: null, goals: null, concerns: null, canvasW: 300, newCourse: "",
    a: {
      grade: prev ? prev.grade : null, field: prev ? prev.field : null, goals: prev ? prev.goals.slice() : [], goal_note: "",
      concerns: prev ? prev.concerns.slice() : [], concern_note: "", availability: prev ? JSON.parse(JSON.stringify(prev.availability)) : {},
      weeks: 4, start_date: todayIso(), name: prev ? prev.name : "",
    },
  } });
}

function wizSteps(w) {
  var meta = app.state.meta, list = [{ id: "grade", label: "مقطع و پایه" }];
  if (w.a.grade && meta.grades[String(w.a.grade)].needs_field) list.push({ id: "field", label: "رشته" });
  return list.concat([{ id: "courses", label: "دروس" }, { id: "goals", label: "هدف" }, { id: "concerns", label: "چالش‌ها" }, { id: "time", label: "زمان آزاد" }, { id: "start", label: "شروع" }]);
}
function wizPatch(patch) { app.set({ wizard: Object.assign({}, app.state.wizard, patch) }); }
function wizA(patch) { var w = app.state.wizard; wizPatch({ a: Object.assign({}, w.a, patch) }); }

function freeMinutes(a) { var m = 0; DAYS.forEach(function (d) { m += ((a.availability[d] || []).length) * 60; }); return m; }

function wizOk(w) {
  var id = wizSteps(w)[w.step].id, a = w.a;
  if (id === "grade") return !!a.grade;
  if (id === "field") return !!a.field;
  if (id === "courses") return !!(w.courses && w.courses.length);
  if (id === "goals") return a.goals.length > 0 || String(a.goal_note).trim().length > 1;
  if (id === "time") return freeMinutes(a) >= 30;
  return true;
}
function wizHint(w) {
  var id = wizSteps(w)[w.step].id, a = w.a;
  if (id === "courses" && w.courses) return fa(w.courses.length) + " درس · " + fa(w.courses.filter(function (c) { return c.weak; }).length) + " با تمرکز بیشتر";
  if (id === "goals") return "تا سه هدف";
  if (id === "concerns") return a.concerns.length ? fa(a.concerns.length) + " مورد انتخاب شد" : "اگر چالشی نداری، ادامه بده";
  if (id === "time") return freeMinutes(a) >= 30 ? fa(freeMinutes(a) / 60) + " ساعت آزاد در هفته" : "دست‌کم یک ساعت انتخاب کن";
  return "";
}

function wizNext() {
  var w = app.state.wizard, steps = wizSteps(w);
  if (!wizOk(w)) return;
  if (w.step < steps.length - 1) { wizPatch({ step: w.step + 1 }); wizEnter(); } else generate();
}
function wizBack() { var w = app.state.wizard; if (w.step) { wizPatch({ step: w.step - 1 }); wizEnter(); } }
function wizClose() { app.set({ wizard: null, view: app.state.plan ? "home" : "home" }); loadDay(); }

// What a step needs from the server, fetched on the way in.
function wizEnter() {
  var w = app.state.wizard, id = wizSteps(w)[w.step].id, a = w.a;
  var key = a.grade + ":" + (a.field || "");
  if (id === "courses" && (!w.courses || w.courseKey !== key)) {
    wizPatch({ courses: null, courseKey: key, courseError: null });
    apiGet("curriculum", a.field ? { grade: String(a.grade), field: a.field } : { grade: String(a.grade) }).then(function (r) {
      wizPatch({ courses: r.courses.map(function (c) { return Object.assign({}, c, { weak: false }); }), source: r.source });
    }).catch(function (e) { wizPatch({ courseError: errText(e) }); });
  }
  if (id === "goals" && (!w.goals || w.goalsGrade !== a.grade)) {
    apiGet("goals", { grade: String(a.grade) }).then(function (r) {
      var ids = r.goals.map(function (g) { return g.id; });
      wizPatch({ goals: r.goals, goalsGrade: a.grade, a: Object.assign({}, app.state.wizard.a, { goals: app.state.wizard.a.goals.filter(function (g) { return ids.indexOf(g) >= 0; }) }) });
    }).catch(function (e) { app.fail(e); });
  }
  if (id === "concerns" && !w.concerns) {
    apiGet("concerns").then(function (r) { wizPatch({ concerns: r }); }).catch(function (e) { app.fail(e); });
  }
}

// ---------------------------------------------------------------- the screen

function wizardView(s, app) {
  var w = s.wizard, steps = wizSteps(w), step = steps[w.step];
  var body = { grade: stepGrade, field: stepField, courses: stepCourses, goals: stepGoals, concerns: stepConcerns, time: stepTime, start: stepStart }[step.id](s, w, app);
  var last = step.id === "start";
  return { type: "Scaffold", children: [
    { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
      box({ gradient: BRAND.sky, padding: "10 16 8 16" }, [C([
        R([{ type: "IconButton", key: "wiz_close", props: { icon: "close", tooltip: "بستن", variant: "tonal" }, events: { tap: app.handler("wiz_close", wizClose) } },
           X({ type: "Canvas", key: "constellation", props: { height: 40, commands: constellation(w, steps.length) },
               events: { resize: app.handler("constellation_resize", function (e, app) { if (e.width && Math.abs(e.width - app.state.wizard.canvasW) > 2) wizPatch({ canvasW: e.width }); }) } })]),
        W("مرحله‌ی " + fa(w.step + 1) + " از " + fa(steps.length) + " · " + step.label, "labelMedium", { style: { color: BRAND.lilac } }),
      ], { gap: "4" })]),
      X({ type: "ListView", children: [box({ padding: "20 16 28 16" }, [C(body, { gap: "16" })])] }),
      box({ padding: "10 16", backgroundColor: colors().surfaceContainer }, [R([
        { type: "Button", key: "wiz_back", props: { text: "قبلی", variant: "text", disabled: w.step === 0 }, events: { tap: app.handler("wiz_back", wizBack) } },
        X(T(wizHint(w) || " ", "labelMedium", { color: "muted", textAlign: "center", maxLines: 1, overflow: "ellipsis" })),
        { type: "Button", key: "wiz_next", props: { text: last ? "ساختن برنامه با مشاور هوشمند" : step.id === "courses" ? "تأیید دروس" : "ادامه",
          icon: last ? "auto_awesome" : "chevron_left", disabled: !wizOk(w) }, events: { tap: app.handler("wiz_next", wizNext) } },
      ])]),
    ] },
  ] };
}

function constellation(w, n) {
  var width = w.canvasW || 300, cmds = [], pts = [];
  for (var i = 0; i < n; i++) pts.push({ x: width - 16 - (width - 32) * i / Math.max(n - 1, 1), y: 20 + (i % 2 ? -9 : 8) });
  cmds.push({ type: "setStrokeStyle", params: { color: "rgba(255,255,255,0.22)" } }, { type: "setLineWidth", params: { width: 1.5 } }, { type: "beginPath", params: {} });
  pts.forEach(function (p, i) { cmds.push({ type: i ? "lineTo" : "moveTo", params: p }); });
  cmds.push({ type: "stroke", params: {} });
  cmds.push({ type: "setStrokeStyle", params: { color: "#c4b5fd" } }, { type: "setLineWidth", params: { width: 2.5 } }, { type: "beginPath", params: {} });
  pts.slice(0, w.step + 1).forEach(function (p, i) { cmds.push({ type: i ? "lineTo" : "moveTo", params: p }); });
  cmds.push({ type: "stroke", params: {} });
  pts.forEach(function (p, i) {
    cmds.push({ type: "setFillStyle", params: { color: i <= w.step ? BRAND.star : "rgba(255,255,255,0.28)" } });
    cmds.push({ type: "fillCircle", params: { x: p.x, y: p.y, radius: i === w.step ? 7 : 4.5 } });
  });
  return cmds;
}

function lead(title, text) { return C([T(title, "headlineSmallEmphasized"), text ? T(text, "bodyMedium", { color: "muted" }) : null], { gap: "4" }); }

function selectable(key, on, children, fn) {
  return { type: "Card", key: key, props: { variant: on ? "filled" : "outlined", tone: on ? "primary" : undefined, style: { padding: "14", gap: "6" } },
    events: { tap: app.handler(key, fn) }, children: [C(children, { gap: "6" })] };
}

function stepGrade(s, w, app) {
  var meta = s.meta;
  return [lead("در چه پایه‌ای درس می‌خوانی؟", "بر اساس نظام آموزشی ۶-۳-۳ مدارس ایران")].concat(meta.stages.map(function (st) {
    return C([T(st.name, "titleSmall", { color: "muted" }),
      { type: "ResponsiveGrid", props: { minColumnWidth: 96, gap: 10 }, children: st.grades.map(function (g) {
        var gi = meta.grades[String(g)], on = w.a.grade === g;
        return selectable("grade_" + g, on, [
          T(fa(g), "displaySmallEmphasized", { textAlign: "center", color: on ? undefined : "primary" }),
          T(gi.nick || gi.name, "labelMedium", { textAlign: "center", color: "muted", maxLines: 2 }),
        ], function () {
          var a = app.state.wizard.a;
          var patch = g === a.grade ? {} : { grade: g, field: null, goals: [] };
          wizPatch({ a: Object.assign({}, a, patch), courses: g === a.grade ? app.state.wizard.courses : null });
          wizNext();
        });
      }) }], { gap: "8" });
  }));
}

function stepField(s, w, app) {
  var fields = s.meta.fields;
  return [lead("رشته‌ات چیست؟", "از پایه‌ی دهم، دروس هر رشته جداست."),
    { type: "ResponsiveGrid", props: { minColumnWidth: 220, gap: 12 }, children: Object.keys(fields).map(function (id) {
      var on = w.a.field === id;
      return selectable("field_" + id, on, [
        R([{ type: "Icon", props: { icon: FIELD_ICON[id] || "school", size: 28, style: { color: BRAND.primary } } }, X(T(fields[id].name, "titleMediumEmphasized"))]),
        T(id === "vocational" ? "دروس عمومی + دروس تخصصی رشته‌ات را خودت اضافه می‌کنی" : "شاخه‌ی نظری", "bodySmall", { color: "muted" }),
      ], function () {
        var a = app.state.wizard.a;
        wizPatch({ a: Object.assign({}, a, { field: id }), courses: id === a.field ? app.state.wizard.courses : null });
        wizNext();
      });
    }) }];
}

function stepCourses(s, w, app) {
  var meta = s.meta, a = w.a;
  var title = "دروس " + meta.grades[String(a.grade)].name + (a.field ? " · " + meta.fields[a.field].name : "");
  if (w.courseError) return [lead(title), { type: "Callout", props: { severity: "critical", title: "فهرست دروس دریافت نشد", text: w.courseError } },
    { type: "Button", key: "courses_retry", props: { text: "تلاش دوباره", icon: "refresh", variant: "tonal" }, events: { tap: app.handler("courses_retry", function () { wizPatch({ courses: null, courseKey: null }); wizEnter(); }) } }];
  if (!w.courses) return [lead(title, "در حال دریافت فهرست رسمی دروس…"), { type: "Shimmer", children: [C([1, 2, 3, 4].map(function () { return box({ height: "40", borderRadius: "12", backgroundColor: colors().surfaceContainerHighest }); }), { gap: "10" })] }];
  var src = w.source || meta.source, groups = {}, order = [];
  w.courses.forEach(function (c) { if (!groups[c.category]) { groups[c.category] = []; order.push(c.category); } groups[c.category].push(c); });
  return [
    lead(title, "فهرست را بررسی کن: درس‌های سخت‌تر را ستاره بزن، اهمیت را تنظیم کن و اگر درسی جا مانده اضافه‌اش کن."),
    { type: "Callout", props: { severity: "good", icon: "verified", title: "منبع رسمی: " + src.publisher, text: "سال تحصیلی " + src.year + " · " + String(src.url).replace("https://", "") + (src.reviewed ? " · بازبینی: " + src.reviewed : "") } },
  ].concat(order.map(function (cat) {
    return C([R([dot(catColor(cat), 8), X(T(meta.categories[cat] || cat, "labelLarge", { color: "muted" }))], { gap: "6" }),
      { type: "Wrap", props: { style: { gap: "8" } }, children: groups[cat].map(function (c) { return courseChip(c, app); }) }], { gap: "8" });
  })).concat([
    R([X(app.input("new_course", "_newCourse", { label: "درس دیگری داری؟", hint: "مثلاً «ریاضی تقویتی» یا درس تخصصی رشته‌ات", icon: "add", live: true })),
       { type: "Button", key: "add_course", props: { text: "افزودن", variant: "tonal", disabled: !String(s._newCourse || "").trim() }, events: { tap: app.handler("add_course", addCourse) } }]),
    T(src.note || "", "bodySmall", { color: "muted" }),
  ]);
}

function courseChip(c, app) {
  var weak = !!c.weak, dots = "";
  for (var i = 1; i <= 3; i++) dots += i <= c.weight ? "●" : "○";
  return box({ padding: "2 4", borderRadius: "14", borderWidth: 1.5, borderColor: weak ? "#f59e0b" : catColor(c.category), backgroundColor: weak ? "rgba(245,158,11,0.12)" : colors().surface }, [R([
    { type: "IconButton", key: "star_" + c.id, props: { icon: weak ? "star" : "star_border", size: "xs", tooltip: "نیاز به تمرکز بیشتر", selected: weak },
      events: { tap: app.handler("star_" + c.id, function () { editCourse(c.id, function (x) { x.weak = !x.weak; }); }) } },
    T(c.name, "labelLarge"),
    { type: "Button", key: "weight_" + c.id, props: { text: dots, variant: "text", size: "xs", tooltip: "اهمیت در برنامه" },
      events: { tap: app.handler("weight_" + c.id, function () { editCourse(c.id, function (x) { x.weight = (x.weight % 3) + 1; }); }) } },
    { type: "IconButton", key: "remove_" + c.id, props: { icon: "close", size: "xs", tooltip: "حذف" },
      events: { tap: app.handler("remove_" + c.id, function () { wizPatch({ courses: app.state.wizard.courses.filter(function (x) { return x.id !== c.id; }) }); }) } },
  ], { gap: "2" })]);
}
function editCourse(id, fn) {
  wizPatch({ courses: app.state.wizard.courses.map(function (x) { if (x.id !== id) return x; var y = Object.assign({}, x); fn(y); return y; }) });
}
function addCourse(e, app) {
  var name = String(app.state._newCourse || "").trim().slice(0, 60);
  if (!name) return;
  var list = app.state.wizard.courses.concat([{ id: "custom_" + Date.now().toString(36), name: name, weight: 2, category: "custom", weak: false, exam: false }]);
  app.state._newCourse = "";
  wizPatch({ courses: list });
}

function toggleIn(list, id, max) {
  var i = list.indexOf(id);
  if (i >= 0) return list.filter(function (x) { return x !== id; });
  if (max && list.length >= max) { app.set({ toast: "حداکثر سه هدف" }); return list; }
  return list.concat([id]);
}

function stepGoals(s, w, app) {
  if (!w.goals) return [lead("هدفت از این برنامه چیست؟"), { type: "LoadingIndicator", props: { size: 40 } }];
  return [lead("هدفت از این برنامه چیست؟", "تا سه هدف انتخاب کن یا هدف خودت را بنویس."),
    { type: "ResponsiveGrid", props: { minColumnWidth: 240, gap: 12 }, children: w.goals.map(function (g) {
      var on = w.a.goals.indexOf(g.id) >= 0;
      return selectable("goal_" + g.id, on, [
        R([{ type: "Icon", props: { icon: on ? "check_circle" : (GOAL_ICON[g.id] || "flag"), size: 26, style: { color: on ? BRAND.primary2 : BRAND.primary } } }, X(T(g.title, "titleSmallEmphasized"))]),
        T(g.desc, "bodySmall", { color: "muted" }),
      ], function () { wizA({ goals: toggleIn(app.state.wizard.a.goals, g.id, 3) }); });
    }) },
    { type: "TextField", key: "goal_note", props: { label: "هدف خودم (اختیاری)", hint: "مثلاً: معدل ۱۹ در ترم اول", value: w.a.goal_note, multiline: true, maxLines: 3, icon: "edit" },
      events: { input: app.handler("goal_note", function (e) { app.state.wizard.a.goal_note = String(e.value || "").slice(0, 300); var ok = wizOk(app.state.wizard); if (ok !== app.state._goalOk) { app.state._goalOk = ok; app.render(); } }) } },
  ];
}

function stepConcerns(s, w, app) {
  var cat = w.concerns;
  if (!cat) return [lead("چه چیزی درس خواندن را برایت سخت می‌کند؟"), { type: "LoadingIndicator", props: { size: 40 } }];
  return [lead("چه چیزی درس خواندن را برایت سخت می‌کند؟", "هر کدام که درباره‌ی تو صدق می‌کند انتخاب کن؛ برنامه و توصیه‌ها بر اساس پژوهش‌های علمی برایش تنظیم می‌شوند."),
    { type: "Callout", props: { severity: "info", icon: "info", text: cat.disclaimer } },
    { type: "ResponsiveGrid", props: { minColumnWidth: 260, gap: 12 }, children: cat.concerns.map(function (c) {
      var on = w.a.concerns.indexOf(c.id) >= 0;
      return selectable("concern_" + c.id, on, [
        R([{ type: "Icon", props: { icon: on ? "check_circle" : (CONCERN_ICON[c.id] || "help"), size: 26, style: { color: on ? BRAND.primary2 : BRAND.primary } } }, X(T(c.title, "titleSmallEmphasized"))]),
        T(c.desc, "bodySmall", { color: "muted" }),
        { type: "Expandable", key: "why_" + c.id, props: { title: "چرا و بر چه اساسی؟", icon: "lightbulb" }, children: [C([
          T(c.why, "bodySmall"),
          T(c.sources.map(function (x) { return x.text; }).join("\n"), "labelSmall", { color: "muted", textAlign: "left" }),
        ], { gap: "6" })] },
      ], function () { wizA({ concerns: toggleIn(app.state.wizard.a.concerns, c.id) }); });
    }) },
    { type: "TextField", key: "concern_note", props: { label: "چالش دیگری داری؟ (اختیاری)", hint: "مثلاً: سرویس مدرسه دیر می‌رسد و عصرها خسته‌ام", value: w.a.concern_note, multiline: true, maxLines: 3, icon: "edit" },
      events: { input: app.handler("concern_note", function (e) { app.state.wizard.a.concern_note = String(e.value || "").slice(0, 300); }) } },
  ];
}

function setHours(days, hours, on) {
  var a = app.state.wizard.a, av = JSON.parse(JSON.stringify(a.availability));
  days.forEach(function (d) {
    var set = {};
    (av[d] || []).forEach(function (h) { set[h] = true; });
    hours.forEach(function (h) { if (on) set[h] = true; else delete set[h]; });
    av[d] = Object.keys(set).map(Number).sort(function (x, y) { return x - y; });
  });
  wizA({ availability: av });
}

function stepTime(s, w, app) {
  var av = w.a.availability, late = w.a.grade <= 6 ? 20 : w.a.grade <= 9 ? 22 : 23, cell = compact() ? "28" : "30";
  var head = R([box({ width: "40" })].concat(DAYS.map(function (d) { return X(T(compact() ? DAY_FA[d].charAt(0) : DAY_FA[d], "labelMedium", { textAlign: "center", color: "muted" })); })), { gap: "3" });
  var rows = HOURS.map(function (h) {
    return R([
      { type: "InkWell", key: "hour_" + h, events: { tap: app.handler("hour_" + h, function () {
        var all = DAYS.every(function (d) { return (av[d] || []).indexOf(h) >= 0; });
        setHours(DAYS, [h], !all);
      }) }, children: [box({ width: "40", height: cell }, [T(fa(h), "labelSmall", { textAlign: "center", color: "muted" })])] },
    ].concat(DAYS.map(function (d) {
      var on = (av[d] || []).indexOf(h) >= 0;
      return X({ type: "Container", key: "cell_" + d + "_" + h, props: { style: {
        height: cell, borderRadius: "7",
        gradient: on ? BRAND.accent : undefined,
        backgroundColor: on ? undefined : (h >= late ? colors().surfaceContainerHighest : colors().surfaceContainer),
        opacity: on && h >= late ? 0.75 : 1 } },
        events: { tap: app.handler("cell_" + d + "_" + h, function () { setHours([d], [h], !on); }) } });
    })), { gap: "3" });
  });
  function preset(key, label, days, hours) {
    return { type: "Button", key: "preset_" + key, props: { text: label, variant: "tonal", size: "xs" }, events: { tap: app.handler("preset_" + key, function () { setHours(days, hours, true); }) } };
  }
  return [lead("چه ساعت‌هایی در هفته آزادی؟", "روی خانه‌ها بزن تا رنگی شوند: ساعت‌هایی که می‌توانی درس بخوانی. زدن روی ساعت، آن ساعت را در همه‌ی روزها روشن یا خاموش می‌کند."),
    { type: "Wrap", props: { style: { gap: "8" } }, children: [
      preset("afternoon", "عصرها (۱۶ تا ۱۹)", ["sat", "sun", "mon", "tue", "wed"], [16, 17, 18]),
      preset("weekend", "صبح پنجشنبه و جمعه", ["thu", "fri"], [9, 10, 11]),
      preset("evening", "شب‌ها (۱۹ تا ۲۱)", ["sat", "sun", "mon", "tue", "wed"], [19, 20]),
      { type: "Button", key: "preset_clear", props: { text: "پاک کردن", variant: "text", size: "xs", icon: "delete" }, events: { tap: app.handler("preset_clear", function () { wizA({ availability: {} }); }) } },
    ] },
    T(fa(freeMinutes(w.a) / 60) + " ساعت آزاد در هفته", "titleSmallEmphasized", { color: "primary" }),
    C([head].concat(rows), { gap: "3" }),
    T("خانه‌های تیره‌تر نزدیک وقت خواب‌اند؛ برنامه در آن‌ها جلسه‌ی کمتری می‌گذارد تا خوابت کافی باشد.", "bodySmall", { color: "muted" }),
  ];
}

function stepStart(s, w, app) {
  var a = w.a, meta = s.meta, t = todayIso();
  var nextSat = addDaysIso(t, ((7 - DAYS.indexOf(dayKey(t))) % 7) || 7);
  var goals = (w.goals || []).filter(function (g) { return a.goals.indexOf(g.id) >= 0; }).map(function (g) { return g.title; }).concat(a.goal_note ? [a.goal_note] : []);
  var concerns = ((w.concerns && w.concerns.concerns) || []).filter(function (c) { return a.concerns.indexOf(c.id) >= 0; }).map(function (c) { return c.title; }).concat(a.concern_note ? [a.concern_note] : []);
  var weak = (w.courses || []).filter(function (c) { return c.weak; }).map(function (c) { return c.name; });
  function row(k, v) { return R([box({ width: "84" }, [T(k, "labelLarge", { color: "muted" })]), X(T(v, "bodyMedium"))], { alignItems: "flex-start" }); }
  return [lead("آماده‌ای؟", "مشاور هوشمند «برنامه‌ریز» در آسمان با این اطلاعات برایت برنامه و توصیه می‌نویسد و جلسه‌ها را در تقویمت ثبت می‌کند."),
    { type: "ResponsiveGrid", props: { minColumnWidth: 300, gap: 16 }, children: [
      card([
        { type: "TextField", key: "student_name", props: { label: "اسمت (اختیاری)", hint: "برای سلام در صفحه‌ی اصلی", value: a.name, icon: "person" },
          events: { input: app.handler("student_name", function (e) { app.state.wizard.a.name = String(e.value || "").slice(0, 40); }) } },
        T("شروع برنامه", "labelLarge", { color: "muted" }),
        { type: "SegmentedButton", key: "start_date", props: { selected: a.start_date, segments: [
          { value: nextSat, label: "شنبه‌ی آینده" }, { value: addDaysIso(t, 1), label: "فردا" }, { value: t, label: "امروز" }] },
          events: { change: app.handler("start_date", function (e) { wizA({ start_date: e.value }); }) } },
        T(jlong(a.start_date), "bodySmall", { color: "muted" }),
        T("طول برنامه", "labelLarge", { color: "muted" }),
        { type: "SegmentedButton", key: "weeks", props: { selected: String(a.weeks), segments: ["8", "4", "2", "1"].map(function (n) { return { value: n, label: fa(n) + " هفته" }; }) },
          events: { change: app.handler("weeks", function (e) { wizA({ weeks: +e.value }); }) } },
      ]),
      card([
        row("پایه", meta.grades[String(a.grade)].name + (a.field ? " · " + meta.fields[a.field].name : "")),
        row("دروس", fa((w.courses || []).length) + " درس" + (weak.length ? " · ★ " + weak.join("، ") : "")),
        row("هدف", goals.join("، ") || "—"),
        row("چالش‌ها", concerns.join("، ") || "—"),
        row("زمان آزاد", fa(freeMinutes(a) / 60) + " ساعت در هفته، " + fa(DAYS.filter(function (d) { return (a.availability[d] || []).length; }).length) + " روز"),
      ]),
    ] },
  ];
}

// ---------------------------------------------------------------- the agent at work

var THINK_STEPS = [
  { id: "queued", text: "پاسخ‌هایت به مشاور «برنامه‌ریز» در آسمان رسید" },
  { id: "thinking", text: "مشاور برنامه و توصیه‌ها را می‌نویسد" },
  { id: "checking", text: "بررسی برنامه با قوانین علمی و زمان آزادت" },
  { id: "repairing", text: "اصلاح برنامه توسط مشاور" },
  { id: "saving", text: "ثبت جلسه‌ها در تقویم" },
];
function thinkingView(s, app) {
  var t = s.thinking, failed = t.status === "failed";
  var order = ["queued", "thinking", "checking", "repairing", "saving", "done"], idx = order.indexOf(t.status);
  return { type: "Scaffold", children: [box({ gradient: BRAND.sky, padding: "24" }, [
    { type: "Center", children: [box({ maxWidth: "460" }, [C([
      failed ? { type: "Icon", props: { icon: "cloud", size: 64, style: { color: BRAND.lilac } } }
             : { type: "Center", children: [{ type: "LoadingIndicator", props: { size: 72, contained: true } }] },
      W(failed ? "برنامه ساخته نشد" : "مشاور هوشمند در حال برنامه‌ریزی است", "headlineSmallEmphasized", { textAlign: "center" }),
      failed ? null : C(THINK_STEPS.map(function (x) {
        var i = order.indexOf(x.id), now = i === idx, past = i < idx;
        var label = x.text + (x.id === "repairing" && now && t.round ? " (دور " + fa(t.round) + ")" : "");
        return R([{ type: "Icon", props: { icon: past ? "check_circle" : now ? "auto_awesome" : "radio_button_unchecked", size: 20, style: { color: now ? BRAND.star : BRAND.lilac } } },
                  X(W(label, now ? "bodyLargeEmphasized" : "bodyMedium", { style: { color: now || past ? "#ffffff" : BRAND.lilac } }))], { gap: "10" });
      }), { gap: "10" }),
      W(failed ? t.error : "این کار معمولاً یک تا دو دقیقه طول می‌کشد.", "bodyMedium", { textAlign: "center", style: { color: BRAND.lilac } }),
      failed ? R([
        { type: "Button", key: "think_retry", props: { text: "تلاش دوباره", icon: "refresh" }, events: { tap: app.handler("think_retry", function () { generate(); }) } },
        { type: "Button", key: "think_back", props: { text: "بازگشت", variant: "text" }, events: { tap: app.handler("think_back", function (e, app) { app.set({ thinking: null }); }) } },
      ], { justifyContent: "center" }) : null,
    ], { gap: "18" })])] },
  ])] };
}
