/* آسمان‌درس — the study planner's page. Vanilla JS, no build step. */
(() => {
  "use strict";

  // ------------------------------------------------------------ helpers
  const $ = (s, el = document) => el.querySelector(s);
  const FA = "۰۱۲۳۴۵۶۷۸۹";
  const fa = (v) => String(v).replace(/\d/g, (d) => FA[d]);
  const h = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const DAYS = ["sat", "sun", "mon", "tue", "wed", "thu", "fri"];
  const DAY_FA = { sat: "شنبه", sun: "یکشنبه", mon: "دوشنبه", tue: "سه‌شنبه", wed: "چهارشنبه", thu: "پنجشنبه", fri: "جمعه" };
  const JMONTHS = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"];
  const CAT_COLOR = { math: "var(--c-math)", science: "var(--c-science)", language: "var(--c-language)", humanities: "var(--c-humanities)",
    religion: "var(--c-religion)", skill: "var(--c-skill)", custom: "var(--c-custom)", special: "var(--c-special)" };
  const CAT_HEX = { math: "#6366f1", science: "#10b981", language: "#f59e0b", humanities: "#ec4899", religion: "#14b8a6", skill: "#8b5cf6", custom: "#64748b", special: "#0ea5e9" };
  const TYPE_ICON = { learn: "📖", practice: "✍️", review: "🔁", weekly_review: "🧭", timed_test: "⏱" };
  const color = (cat) => CAT_COLOR[cat] || CAT_COLOR.custom;
  const mins = (m) => { m = Math.round(m); const hh = Math.floor(m / 60), mm = m % 60; return hh ? fa(hh) + " ساعت" + (mm ? " و " + fa(mm) + " دقیقه" : "") : fa(mm) + " دقیقه"; };
  const span = (x) => `<bdi dir="ltr">${fa(x.start)}–${fa(x.end)}</bdi>`;
  const hrs = (m) => fa((Math.round(m / 6) / 10).toString()).replace(".", "٫");

  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem("asd:" + k)); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem("asd:" + k, JSON.stringify(v)); } catch (e) { /* private mode */ } },
  };
  let PID = store.get("pid");
  if (!PID || !/^[a-zA-Z0-9_-]{8,64}$/.test(PID)) {
    PID = "s" + (crypto.randomUUID ? crypto.randomUUID().replace(/-/g, "") : Math.random().toString(36).slice(2) + Date.now().toString(36));
    store.set("pid", PID);
  }

  async function api(path, opts = {}) {
    const r = await fetch("api/" + path, { headers: { "Content-Type": "application/json" }, ...opts, body: opts.body ? JSON.stringify(opts.body) : undefined });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error || "خطا در ارتباط با سرور");
    return data;
  }
  function toast(msg) { const t = $("#toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("show"), 2800); }

  // ------------------------------------------------------------ dates (Jalali via Intl)
  const iso = (d) => d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  const fromIso = (s) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d, 12); };
  const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
  const jfmt = new Intl.DateTimeFormat("en-u-ca-persian-nu-latn", { year: "numeric", month: "numeric", day: "numeric" });
  function jparts(d) {
    const o = {};
    for (const p of jfmt.formatToParts(d)) if (p.type !== "literal") o[p.type] = parseInt(p.value, 10);
    return { y: o.year, m: o.month, d: o.day };
  }
  const dayKey = (d) => DAYS[(d.getDay() + 1) % 7];
  const jlong = (d) => { const j = jparts(d); return DAY_FA[dayKey(d)] + " " + fa(j.d) + " " + JMONTHS[j.m - 1] + " " + fa(j.y); };
  const jshort = (d) => { const j = jparts(d); return fa(j.d) + " " + JMONTHS[j.m - 1]; };
  const today = () => { const n = new Date(); return new Date(n.getFullYear(), n.getMonth(), n.getDate(), 12); };
  const nowMin = () => { const n = new Date(); return n.getHours() * 60 + n.getMinutes(); };
  const toMin = (s) => { const [a, b] = s.split(":").map(Number); return a * 60 + b; };

  // ------------------------------------------------------------ state
  const S = { meta: null, plan: null, view: "home", calMonth: null, calSel: null, weekTab: 0 };

  // ------------------------------------------------------------ stars
  function stars() {
    const c = $("#stars"), ctx = c.getContext("2d");
    const draw = () => {
      const w = c.clientWidth, hh = c.clientHeight, dpr = window.devicePixelRatio || 1;
      c.width = w * dpr; c.height = hh * dpr; ctx.scale(dpr, dpr);
      let seed = 7;
      const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
      for (let i = 0; i < Math.min(160, w / 6); i++) {
        const x = rnd() * w, y = rnd() * hh * 0.85, r = rnd() * 1.3 + 0.2;
        ctx.globalAlpha = 0.25 + rnd() * 0.7; ctx.fillStyle = "#fff";
        ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill();
      }
    };
    draw(); let t; addEventListener("resize", () => { clearTimeout(t); t = setTimeout(draw, 150); });
  }

  // ------------------------------------------------------------ routing
  function route() {
    const v = (location.hash || "#home").slice(1);
    if (v === "new") { openWizard(); return; }
    S.view = ["home", "calendar", "plan"].includes(v) ? v : "home";
    document.querySelectorAll(".view").forEach((el) => el.classList.toggle("active", el.id === "view-" + S.view));
    document.querySelectorAll("#tabs a").forEach((a) => a.classList.toggle("active", a.dataset.view === S.view));
    render();
  }
  function render() {
    if (S.view === "home") renderHome();
    if (S.view === "calendar") renderCalendar();
    if (S.view === "plan") renderPlan();
  }
  function noPlan(el) {
    el.innerHTML = `<div class="hero"><h1>سلام! بیا برنامه‌ی درسی‌ات را بسازیم</h1><p>چند سؤال کوتاه، بعد مشاور هوشمند آسمان برایت برنامه می‌چیند.</p></div>
      <div class="card empty"><div class="art">🌌</div><h2>هنوز برنامه‌ای نداری</h2>
      <p class="muted">پایه و رشته‌ات، هدفت، چالش‌هایت و ساعت‌های آزادت را بگو؛ برنامه در تقویمت ثبت می‌شود و هر روز این‌جا می‌بینی‌اش.</p>
      <a class="btn primary big" href="#new">شروع کنیم ✨</a></div>`;
  }

  // ------------------------------------------------------------ home
  async function renderHome() {
    const el = $("#view-home");
    if (!S.plan) return noPlan(el);
    const d = today(), key = iso(d);
    let day;
    try { day = await api(`profiles/${PID}/day/${key}`); } catch (e) { el.innerHTML = `<div class="card">${h(e.message)}</div>`; return; }
    const ss = day.sessions || [];
    const pct = day.minutes ? Math.round((100 * day.done_minutes) / day.minutes) : 0;
    const now = nowMin();
    const next = ss.find((x) => !x.done && toMin(x.end) > now);
    const name = S.plan.profile.name ? "، " + h(S.plan.profile.name) : "";
    const inPlan = key >= S.plan.start_date && key <= S.plan.end_date;
    const tips = S.plan.advice.flatMap((c) => c.tips.map((t) => ({ t, title: c.title }))).filter((x) => x.t);
    const tip = tips.length ? tips[(d.getDate() + d.getMonth() * 31) % tips.length] : null;

    let nextCard;
    if (next) {
      const startsIn = toMin(next.start) - now;
      nextCard = `<div class="card next"><div class="muted">${startsIn > 0 ? "جلسه‌ی بعدی" : "همین حالا"}</div>
        <div class="big">${TYPE_ICON[next.type] || ""} ${h(next.course)}</div><div>${h(next.type_label)} · ${fa(next.start)} تا ${fa(next.end)}</div>
        ${next.topic ? `<div class="muted">${h(next.topic)}</div>` : ""}
        <span class="count">${startsIn > 0 ? mins(startsIn) + " دیگر" : "در جریان — تمرکز کن 🎯"}</span></div>`;
    } else if (ss.length) {
      nextCard = `<div class="card next"><div class="muted">امروز</div><div class="big">${pct >= 100 ? "همه‌ی جلسه‌ها انجام شد 🎉" : "جلسه‌ی دیگری نمانده"}</div><div>${pct >= 100 ? "عالی بود؛ حالا استراحت کن." : "جلسه‌هایی را که انجام دادی تیک بزن."}</div></div>`;
    } else {
      nextCard = `<div class="card next"><div class="muted">امروز</div><div class="big">${inPlan ? "روز استراحت 🌿" : "خارج از بازه‌ی برنامه"}</div><div>${inPlan ? "امروز جلسه‌ای نداری. کمی تحرک و خواب کافی، بخشی از برنامه است." : "برای ادامه، برنامه‌ی تازه بساز."}</div>
        ${inPlan ? "" : `<a class="btn soft" style="margin-top:10px" href="#new">برنامه‌ی تازه</a>`}</div>`;
    }

    const max7 = Math.max(60, ...day.last7.map((x) => x.minutes));
    el.innerHTML = `
      <div class="hero"><h1>${greeting()}${name}</h1><p>${jlong(d)}${ss.length ? " · " + fa(ss.length) + " جلسه، " + mins(day.minutes) : ""}</p></div>
      <div class="today-top">
        <div class="card"><div class="ring-wrap">${ring(pct)}<div><h3 style="margin:0">پیشرفت امروز</h3>
          <div class="muted">${mins(day.done_minutes)} از ${mins(day.minutes)}</div>
          <div style="margin-top:6px">${streakBadge(day.last7)}</div></div></div></div>
        ${nextCard}
      </div>
      <div class="grid g-3" style="margin-top:16px">
        <div class="card span-2"><h3>برنامه‌ی امروز <small>${jshort(d)}</small></h3>
          ${ss.length ? `<ul class="timeline">${ss.map(tlItem).join("")}</ul>` : `<p class="muted">امروز در تقویمت جلسه‌ای ثبت نشده است.</p>`}</div>
        <div class="grid">
          <div class="card"><h3>هفت روز گذشته</h3><div class="bars7">${day.last7.map((x, i) => {
            const dd = fromIso(x.date), isT = i === 6;
            return `<div class="col ${isT ? "today" : ""}" title="${jshort(dd)}: ${fa(x.done_minutes)} از ${fa(x.minutes)} دقیقه"><div class="track"><div class="plan" style="height:${(100 * x.minutes) / max7}%"></div><div class="fill" style="height:${(100 * x.done_minutes) / max7}%"></div></div><div class="lbl">${DAY_FA[dayKey(dd)].slice(0, 1)}</div></div>`;
          }).join("")}</div><div class="legend" style="margin-top:8px"><span><i style="--c:var(--primary)"></i>انجام‌شده</span><span><i style="--c:var(--primary-soft)"></i>برنامه</span></div></div>
          ${tip ? `<div class="card tip"><div class="art">💡</div><div><h3 style="margin:0 0 4px">نکته‌ی امروز</h3><div>${h(tip.t)}</div><div class="muted" style="font-size:12px;margin-top:4px">${h(tip.title)}</div></div></div>` : ""}
        </div>
      </div>`;
    el.querySelectorAll("[data-sid]").forEach((b) => b.addEventListener("click", () => toggle(b.dataset.sid, b)));
  }
  function greeting() { const hh = new Date().getHours(); return hh < 12 ? "صبح بخیر" : hh < 17 ? "روز بخیر" : "عصر بخیر"; }
  function streakBadge(last7) {
    let n = 0;
    for (let i = last7.length - 2; i >= 0; i--) { const x = last7[i]; if (!x.minutes) continue; if (x.done_minutes > 0) n++; else break; }
    if (last7[6].done_minutes > 0) n++;
    return n ? `<span class="badge">🔥 ${fa(n)} روز پشت سر هم</span>` : `<span class="badge">امروز زنجیره را شروع کن</span>`;
  }
  function tlItem(x) {
    return `<li class="tl-item" style="--c:${color(x.category)}"><div class="tl-time">${fa(x.start)}</div><span class="tl-dot"></span>
      <div class="session ${x.done ? "done" : ""}"><div><div class="t">${TYPE_ICON[x.type] || ""} ${h(x.course)} ${x.weak ? '<span class="badge star">★ تمرکز</span>' : ""}</div>
      <div class="s">${h(x.type_label)} · ${span(x)} · ${fa(x.minutes)} دقیقه${x.topic ? " · " + h(x.topic) : ""}</div>
      ${x.note ? `<div class="s">${h(x.note)}</div>` : ""}</div>
      <button class="check" data-sid="${h(x.id)}" aria-label="انجام شد"><svg viewBox="0 0 24 24"><path d="M5 12l5 5 9-10"/></svg></button></div></li>`;
  }
  async function toggle(sid, btn) {
    const box = btn.closest(".session"); const done = !box.classList.contains("done");
    box.classList.toggle("done", done);
    try { await api(`profiles/${PID}/sessions/${encodeURIComponent(sid)}`, { method: "PATCH", body: { done } }); if (done) toast("آفرین! یک جلسه‌ی دیگر 🌟"); render(); }
    catch (e) { box.classList.toggle("done", !done); toast(e.message); }
  }
  function ring(pct) {
    const r = 50, c = 2 * Math.PI * r;
    return `<svg class="ring" viewBox="0 0 120 120" role="img" aria-label="${fa(pct)} درصد"><defs><linearGradient id="rg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b5bd6"/><stop offset="1" stop-color="#c084fc"/></linearGradient></defs>
      <circle cx="60" cy="60" r="${r}" fill="none" stroke="var(--surface-2)" stroke-width="12"/>
      <circle cx="60" cy="60" r="${r}" fill="none" stroke="url(#rg)" stroke-width="12" stroke-linecap="round" stroke-dasharray="${(c * pct) / 100} ${c}" transform="rotate(-90 60 60)"/>
      <text x="60" y="68" text-anchor="middle" font-size="24" fill="var(--text)">${fa(pct)}٪</text></svg>`;
  }

  // ------------------------------------------------------------ calendar
  function monthStart(d) { const j = jparts(d); return addDays(d, -(j.d - 1)); }
  async function renderCalendar() {
    const el = $("#view-calendar");
    if (!S.plan) return noPlan(el);
    if (!S.calMonth) S.calMonth = monthStart(today());
    const first = S.calMonth, j = jparts(first);
    const days = [];
    for (let d = first; jparts(d).m === j.m; d = addDays(d, 1)) days.push(d);
    const lead = (first.getDay() + 1) % 7;
    const from = iso(addDays(first, -lead)), to = iso(addDays(days[days.length - 1], 13));
    let cal = {};
    try { cal = (await api(`profiles/${PID}/calendar?from=${from}&to=${to}`)).days; } catch (e) { toast(e.message); }
    const tk = iso(today());
    if (!S.calSel) S.calSel = tk;
    const cells = [];
    for (let i = 0; i < lead; i++) cells.push(dayCell(addDays(first, i - lead), cal, tk, true));
    days.forEach((d) => cells.push(dayCell(d, cal, tk, false)));
    while (cells.length % 7) cells.push(dayCell(addDays(days[days.length - 1], cells.length - lead - days.length + 1), cal, tk, true));
    const sel = cal[S.calSel] || [];
    const selD = fromIso(S.calSel);
    const cats = [...new Set(S.plan.stats.per_course.map((p) => p.category))];
    el.innerHTML = `
      <div class="hero"><h1>تقویم مطالعه</h1><p>برنامه از ${jshort(fromIso(S.plan.start_date))} تا ${jshort(fromIso(S.plan.end_date))} در تقویمت ثبت شده است.</p></div>
      <div class="grid g-3">
        <div class="card span-2">
          <div class="cal-head"><button class="icon-btn" id="calPrev" aria-label="ماه قبل"><svg viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></svg></button>
            <h2>${JMONTHS[j.m - 1]} ${fa(j.y)}</h2>
            <button class="btn soft" id="calToday">امروز</button>
            <button class="icon-btn" id="calNext" aria-label="ماه بعد"><svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg></button></div>
          <div class="cal-grid">${DAYS.map((k) => `<div class="cal-dow"><span class="l">${DAY_FA[k]}</span><span class="s">${DAY_FA[k].slice(0, 1)}</span></div>`).join("")}${cells.join("")}</div>
          <div class="legend" style="margin-top:12px">${cats.map((c) => `<span><i style="--c:${color(c)}"></i>${h(S.meta.categories[c] || c)}</span>`).join("")}</div>
        </div>
        <div class="card"><h3>${jlong(selD)}</h3>
          ${sel.length ? `<ul class="timeline">${sel.map(tlItem).join("")}</ul><p class="muted" style="margin:8px 0 0">${fa(sel.length)} جلسه · ${mins(sel.reduce((a, x) => a + x.minutes, 0))}</p>`
            : `<p class="muted">${S.calSel >= S.plan.start_date && S.calSel <= S.plan.end_date ? "روز استراحت 🌿" : "در این روز برنامه‌ای ثبت نشده است."}</p>`}
        </div>
      </div>`;
    $("#calPrev").onclick = () => { S.calMonth = monthStart(addDays(S.calMonth, -2)); renderCalendar(); };
    $("#calNext").onclick = () => { S.calMonth = monthStart(addDays(S.calMonth, 32)); renderCalendar(); };
    $("#calToday").onclick = () => { S.calMonth = monthStart(today()); S.calSel = tk; renderCalendar(); };
    el.querySelectorAll(".cal-day").forEach((b) => b.addEventListener("click", () => { S.calSel = b.dataset.date; renderCalendar(); }));
    el.querySelectorAll("[data-sid]").forEach((b) => b.addEventListener("click", () => toggle(b.dataset.sid, b)));
  }
  function dayCell(d, cal, tk, out) {
    const k = iso(d), ss = cal[k] || [], j = jparts(d);
    const inPlan = k >= S.plan.start_date && k <= S.plan.end_date;
    const total = ss.reduce((a, x) => a + x.minutes, 0);
    const done = ss.filter((x) => x.done).length;
    return `<button class="cal-day ${out ? "out" : ""} ${k === tk ? "today" : ""} ${k === S.calSel ? "sel" : ""} ${inPlan && !ss.length ? "rest" : ""}" data-date="${k}">
      <span class="n">${fa(j.d)}<span class="g">${fa(d.getDate())}</span></span>
      <span class="pills">${ss.slice(0, 4).map((x) => `<span class="pill ${x.done ? "done" : ""}" style="--c:${color(x.category)}"></span>`).join("")}</span>
      <span class="m">${ss.length ? (done === ss.length ? "✓ " : "") + fa(Math.round(total / 6) / 10).replace(".", "٫") + " س" : inPlan ? "استراحت" : ""}</span></button>`;
  }

  // ------------------------------------------------------------ plan
  function renderPlan() {
    const el = $("#view-plan");
    const p = S.plan;
    if (!p) return noPlan(el);
    const st = p.stats, pr = p.profile;
    const tables = p.weeks_detail && p.weeks_detail.length ? p.weeks_detail : [p.timetable];
    const wt = Math.min(S.weekTab, tables.length - 1);
    const tt = tables[wt];
    const times = DAYS.map((d) => tt[d]);
    const by = p.generated_by || {};
    el.innerHTML = `
      <div class="hero"><h1>برنامه‌ی ${h(pr.grade_name)}${pr.field_name ? " · " + h(pr.field_name) : ""}</h1>
        <p>${fa(p.weeks)} هفته، از ${jlong(fromIso(p.start_date))} · هدف: ${h([...pr.goal_titles, pr.goal_note].filter(Boolean).join("، "))}</p></div>
      <div class="card counsel"><div class="avatar">🧑‍🏫</div><div>
        <h3 style="margin:0">پیام مشاور</h3>
        <div class="by">${by.kind === "agent" ? `ساخته‌شده توسط مشاور هوشمند «برنامه‌ریز» در آسمان${by.rounds > 1 ? " · " + fa(by.rounds) + " دور بازبینی تا رعایت همه‌ی قوانین" : ""}` : "پیش‌نویس الگوریتمی (حالت آزمایشی)"}</div>
        <p style="margin:8px 0 0">${h(p.summary)}</p></div></div>
      <div class="grid g-4" style="margin-top:16px">
        <div class="card kpi"><span class="v">${hrs(st.week_minutes)}</span><span class="l">ساعت مطالعه در هفته</span></div>
        <div class="card kpi"><span class="v">${fa(st.sessions)}</span><span class="l">جلسه در هفته</span></div>
        <div class="card kpi"><span class="v">${fa(p.settings.focus)}<small style="font-size:14px"> + ${fa(p.settings.break)}</small></span><span class="l">دقیقه تمرکز + استراحت</span></div>
        <div class="card kpi"><span class="v">${fa(st.study_days)}</span><span class="l">روز مطالعه${p.rest_day ? " · استراحت: " + DAY_FA[p.rest_day] : ""}</span></div>
      </div>
      <div class="card" style="margin-top:16px"><h3>جدول هفتگی ${tables.length > 1 ? `<span class="week-tabs" style="margin-inline-start:auto">${tables.map((_, i) => `<button data-wk="${i}" class="${i === wt ? "on" : ""}">هفته‌ی ${fa(i + 1)}</button>`).join("")}</span>` : "<small>هر هفته تکرار می‌شود</small>"}</h3>
        <div class="table-scroll"><table class="tt"><thead><tr>${DAYS.map((d) => `<th>${DAY_FA[d]}</th>`).join("")}</tr></thead>
        <tbody><tr>${times.map((ss, i) => `<td><div class="tt-cell">${ss.length ? ss.map((x) => `<div class="tt-s" style="--c:${color(x.category)}"><b>${TYPE_ICON[x.type] || ""} ${h(x.course)}${x.weak ? " ★" : ""}</b><span>${span(x)}</span><br><span>${h(x.type_label)}</span>${x.topic ? `<br><span>${h(x.topic)}</span>` : ""}</div>`).join("") : `<div class="tt-rest">${p.rest_day === DAYS[i] ? "استراحت 🌿" : "—"}</div>`}</div></td>`).join("")}</tr></tbody></table></div>
        ${p.resting && p.resting[wt] && p.resting[wt].length ? `<p class="muted" style="margin:6px 0 0">این هفته نوبت استراحت این دروس است: ${h(p.resting[wt].join("، "))}</p>` : ""}
      </div>
      <div class="grid g-2" style="margin-top:16px">
        <div class="card"><h3>سهم هر درس <small>هفته‌ی اول</small></h3>${donut(st.per_course)}</div>
        <div class="card"><h3>زمان مطالعه در روزهای هفته</h3>${dayBars(st.per_day)}
          <h3 style="margin-top:18px">نوع جلسه‌ها</h3>${typeStack(st.per_type, st.week_minutes)}</div>
      </div>
      <h2 style="margin:26px 0 12px">مشاوره و توصیه‌ها</h2>
      <div class="advice">${p.advice.map(adviceCard).join("")}</div>
      <p class="muted" style="font-size:12px;margin-top:18px">منبع فهرست دروس: ${h(S.meta.source.publisher)} — <a href="${h(S.meta.source.url)}" target="_blank" rel="noopener">${h(S.meta.source.url.replace("https://", ""))}</a>. توصیه‌ها جایگزین مشاوره‌ی تخصصی نیستند.</p>`;
    el.querySelectorAll("[data-wk]").forEach((b) => b.addEventListener("click", () => { S.weekTab = +b.dataset.wk; renderPlan(); }));
  }
  function donut(items) {
    const total = items.reduce((a, x) => a + x.minutes, 0) || 1;
    const r = 60, c = 2 * Math.PI * r;
    let off = 0;
    const segs = items.map((x) => {
      const len = (x.minutes / total) * c;
      const s = `<circle cx="80" cy="80" r="${r}" fill="none" stroke="${CAT_HEX[x.category] || CAT_HEX.custom}" stroke-width="26" stroke-dasharray="${Math.max(len - 2, 0.5)} ${c}" stroke-dashoffset="${-off}" transform="rotate(-90 80 80)"><title>${h(x.name)}: ${fa(x.minutes)} دقیقه</title></circle>`;
      off += len; return s;
    }).join("");
    return `<div class="donut-wrap"><svg viewBox="0 0 160 160" width="170" height="170" role="img" aria-label="سهم دروس">${segs}
      <text x="80" y="76" text-anchor="middle" font-size="22" font-weight="800" fill="var(--text)">${hrs(total)}</text><text x="80" y="98" text-anchor="middle" font-size="12" fill="var(--muted)">ساعت در هفته</text></svg>
      <ul class="donut-legend">${items.map((x) => `<li style="--c:${color(x.category)}"><i></i>${h(x.name)}<b>${fa(Math.round(x.share * 100))}٪</b></li>`).join("")}</ul></div>`;
  }
  function dayBars(days) {
    const max = Math.max(1, ...days.map((d) => d.minutes));
    return `<div class="hbar">${days.map((d) => `<div class="row"><span>${d.name}</span><div class="track"><div class="fill" style="width:${(100 * d.minutes) / max}%"></div></div><span class="muted">${d.minutes ? hrs(d.minutes) + " س" : "—"}</span></div>`).join("")}</div>`;
  }
  function typeStack(types, total) {
    const col = { learn: "#6366f1", practice: "#ec4899", review: "#10b981", weekly_review: "#0ea5e9", timed_test: "#f59e0b" };
    return `<div class="stack">${types.map((t) => `<i style="--c:${col[t.type]};width:${(100 * t.minutes) / (total || 1)}%" title="${h(t.label)}"></i>`).join("")}</div>
      <div class="legend">${types.map((t) => `<span><i style="--c:${col[t.type]}"></i>${TYPE_ICON[t.type]} ${h(t.label)} · ${fa(Math.round((100 * t.minutes) / (total || 1)))}٪</span>`).join("")}</div>`;
  }
  function adviceCard(c) {
    const kinds = { summary: "خلاصه", help: "کمک", notice: "نکته", counsel: "مشاور", goal: "هدف", science: "پایه‌ی علمی" };
    const icons = { summary: "🗺", help: "🤝", notice: "📌", counsel: "🧑‍🏫", goal: "🎯", science: "🔬" };
    return `<div class="adv ${c.kind === "help" ? "help" : ""} ${c.kind === "counsel" ? "counsel-card" : ""}"><h4>${icons[c.kind] || "•"} ${h(c.title)}<span class="kind">${kinds[c.kind] || ""}</span></h4>
      ${c.body ? `<p>${h(c.body)}</p>` : ""}${c.tips.length ? `<ul>${c.tips.map((t) => `<li>${h(t)}</li>`).join("")}</ul>` : ""}
      ${c.sources.length ? `<div class="src">${c.sources.map((s) => (s.url ? `<a href="${h(s.url)}" target="_blank" rel="noopener">${h(s.text)}</a>` : h(s.text))).join("<br>")}</div>` : ""}</div>`;
  }

  // ------------------------------------------------------------ wizard
  const W = { step: 0, a: null, courses: null, courseSrc: null, goals: null, concerns: null, painting: null };
  const STEPS = [
    { id: "grade", label: "مقطع و پایه" },
    { id: "field", label: "رشته", when: () => W.a.grade && S.meta.grades[W.a.grade].needs_field },
    { id: "courses", label: "دروس" },
    { id: "goals", label: "هدف" },
    { id: "concerns", label: "چالش‌ها" },
    { id: "time", label: "زمان آزاد" },
    { id: "start", label: "شروع" },
  ];
  const steps = () => STEPS.filter((s) => !s.when || s.when());

  function openWizard() {
    const prev = S.plan && S.plan.profile;
    const saved = store.get("draft");
    W.a = saved && saved.v === 1 ? saved.a : {
      grade: prev ? prev.grade : null, field: prev ? prev.field : null, goals: prev ? prev.goals : [], goal_note: "", concerns: prev ? prev.concerns : [], concern_note: "",
      availability: prev ? prev.availability : {}, weeks: 4, start_date: iso(today()), name: prev ? prev.name : "",
    };
    W.a.start_date = W.a.start_date < iso(today()) ? iso(today()) : W.a.start_date;
    W.courses = saved && saved.courses ? saved.courses : null;
    W.step = 0;
    $("#wizard").hidden = false;
    document.body.style.overflow = "hidden";
    drawWizard();
  }
  function closeWizard() {
    $("#wizard").hidden = true; document.body.style.overflow = "";
    if (location.hash === "#new") history.replaceState(null, "", S.plan ? "#home" : "#home");
    route();
  }
  function saveDraft() { store.set("draft", { v: 1, a: W.a, courses: W.courses }); }

  function drawConstellation() {
    const list = steps(), n = list.length, svg = $("#constellation");
    const pts = list.map((_, i) => [30 + (640 * i) / Math.max(n - 1, 1), 30 + (i % 2 ? -12 : 10) * (i % 3 === 2 ? 0.4 : 1)]);
    const lit = pts.slice(0, W.step + 1);
    svg.innerHTML = `<polyline points="${pts.map((p) => p.join(",")).join(" ")}" fill="none" stroke="rgba(255,255,255,.18)" stroke-width="1.5" stroke-dasharray="3 4"/>
      <polyline points="${lit.map((p) => p.join(",")).join(" ")}" fill="none" stroke="#c4b5fd" stroke-width="2"/>
      ${pts.map((p, i) => `<g transform="translate(${p[0]} ${p[1]})"><circle r="${i === W.step ? 8 : 5}" fill="${i <= W.step ? "#f5d0fe" : "rgba(255,255,255,.25)"}" ${i === W.step ? 'style="filter:drop-shadow(0 0 6px #f0abfc)"' : ""}/></g>`).join("")}`;
    $("#wizLabel").textContent = "مرحله‌ی " + fa(W.step + 1) + " از " + fa(n) + " · " + list[W.step].label;
  }

  async function drawWizard() {
    drawConstellation();
    const s = steps()[W.step].id;
    const body = $("#wizBody");
    body.scrollTop = 0;
    $("#wizBack").style.visibility = W.step ? "visible" : "hidden";
    $("#wizNext").textContent = s === "start" ? "ساختن برنامه با مشاور هوشمند ✨" : s === "courses" ? "تأیید دروس" : "ادامه";
    $("#wizHint").textContent = "";
    const render = { grade: stepGrade, field: stepField, courses: stepCourses, goals: stepGoals, concerns: stepConcerns, time: stepTime, start: stepStart }[s];
    await render(body);
    validate();
  }
  function validate() {
    const s = steps()[W.step].id, a = W.a;
    let ok = true, hint = "";
    if (s === "grade") ok = !!a.grade;
    if (s === "field") ok = !!a.field;
    if (s === "courses") { ok = W.courses && W.courses.length > 0; hint = ok ? fa(W.courses.length) + " درس · " + fa(W.courses.filter((c) => c.weak).length) + " درس با تمرکز بیشتر" : ""; }
    if (s === "goals") { ok = a.goals.length > 0 || a.goal_note.trim().length > 1; hint = "تا سه هدف"; }
    if (s === "concerns") hint = a.concerns.length ? fa(a.concerns.length) + " مورد انتخاب شد" : "اگر چالشی نداری، ادامه بده";
    if (s === "time") { const m = totalFree(); ok = m >= 30; hint = ok ? "" : "دست‌کم یک ساعت انتخاب کن"; }
    $("#wizNext").disabled = !ok;
    $("#wizHint").textContent = hint;
  }
  function inner(html) { return `<div class="wiz-inner">${html}</div>`; }

  function stepGrade(body) {
    body.innerHTML = inner(`<h2>در چه پایه‌ای درس می‌خوانی؟</h2><p class="lead">بر اساس نظام آموزشی ۶-۳-۳ مدارس ایران</p>
      ${S.meta.stages.map((st) => `<div class="stage"><h4>${h(st.name)}</h4><div class="tiles">${st.grades.map((g) => {
        const gi = S.meta.grades[g];
        return `<button class="tile ${W.a.grade === g ? "on" : ""}" data-g="${g}"><div class="num">${fa(g)}</div><div class="sub">${h(gi.nick || gi.name)}</div></button>`;
      }).join("")}</div></div>`).join("")}`);
    body.querySelectorAll("[data-g]").forEach((b) => b.addEventListener("click", () => {
      const g = +b.dataset.g;
      if (g !== W.a.grade) { W.a.grade = g; W.a.field = null; W.courses = null; W.a.goals = []; }
      saveDraft(); next();
    }));
  }
  function stepField(body) {
    const fields = Object.entries(S.meta.fields);
    body.innerHTML = inner(`<h2>رشته‌ات چیست؟</h2><p class="lead">از پایه‌ی دهم، دروس هر رشته جداست.</p>
      <div class="options">${fields.map(([id, f]) => `<button class="opt ${W.a.field === id ? "on" : ""}" data-f="${id}"><span class="ic">${h(f.icon)}</span><span class="tt">${h(f.name)}</span><span class="dd">${id === "vocational" ? "دروس عمومی + دروس تخصصی رشته‌ات را خودت اضافه می‌کنی" : "شاخه‌ی نظری"}</span></button>`).join("")}</div>`);
    body.querySelectorAll("[data-f]").forEach((b) => b.addEventListener("click", () => {
      if (b.dataset.f !== W.a.field) { W.a.field = b.dataset.f; W.courses = null; }
      saveDraft(); next();
    }));
  }
  async function stepCourses(body) {
    body.innerHTML = inner(`<h2>دروس تو</h2><p class="lead">در حال دریافت فهرست رسمی دروس…</p>${'<div class="skeleton" style="margin:8px 0"></div>'.repeat(5)}`);
    if (!W.courses || W.courseKey !== W.a.grade + ":" + W.a.field) {
      try {
        const q = "grade=" + W.a.grade + (W.a.field ? "&field=" + W.a.field : "");
        const r = await api("curriculum?" + q);
        W.courses = r.courses.map((c) => ({ ...c, weak: false }));
        W.courseSrc = r.source;
      } catch (e) { body.innerHTML = inner(`<div class="card">${h(e.message)}</div>`); return; }
    }
    W.courseKey = W.a.grade + ":" + W.a.field;
    if (!W.courseSrc) W.courseSrc = S.meta.source;
    drawCourses(body);
  }
  function drawCourses(body) {
    const src = W.courseSrc;
    const groups = {};
    W.courses.forEach((c, i) => (groups[c.category] = groups[c.category] || []).push([c, i]));
    body.innerHTML = inner(`<h2>دروس ${h(S.meta.grades[W.a.grade].name)}${W.a.field ? " · " + h(S.meta.fields[W.a.field].name) : ""}</h2>
      <p class="lead">فهرست را بررسی کن: درس‌هایی را که سخت‌ترند یا نمره‌ات در آن‌ها پایین است ★ بزن، اهمیت را با نقطه‌ها تنظیم کن و اگر درسی جا مانده اضافه‌اش کن.</p>
      <div class="source"><span class="seal">✓</span><div><b>منبع رسمی:</b> ${h(src.publisher)} · سال تحصیلی ${h(src.year)}<br>
        <a href="${h(src.url)}" target="_blank" rel="noopener">${h(src.url.replace("https://", ""))}</a>${src.reviewed ? " · بازبینی: " + h(src.reviewed) : ""}</div></div>
      ${Object.entries(groups).map(([cat, list]) => `<div class="cat" style="--c:${color(cat)}"><h4><i></i>${h(S.meta.categories[cat] || cat)}</h4><div class="chips">${list.map(([c, i]) => `
        <span class="chip ${c.weak ? "weak" : ""}" style="--c:${color(cat)}">
          <button class="st" data-star="${i}" title="نیاز به تمرکز بیشتر" aria-pressed="${c.weak}">${c.weak ? "★" : "☆"}</button>
          <span class="nm">${h(c.name)}</span>
          <button class="w" data-w="${i}" title="اهمیت در برنامه (برای تغییر بزن)">${[1, 2, 3].map((n) => `<i class="${n <= c.weight ? "f" : ""}"></i>`).join("")}</button>
          <button class="rm" data-rm="${i}" title="حذف">×</button></span>`).join("")}</div></div>`).join("")}
      <div class="add-row"><input class="input" id="newCourse" maxlength="60" placeholder="درس دیگری داری؟ مثلاً «ریاضی تقویتی» یا درس تخصصی رشته‌ات"><button class="btn soft" id="addCourse">افزودن</button></div>
      <p class="muted" style="font-size:12.5px">${h(src.note || "")}</p>`);
    body.querySelectorAll("[data-star]").forEach((b) => b.onclick = () => { const c = W.courses[+b.dataset.star]; c.weak = !c.weak; saveDraft(); drawCourses(body); validate(); });
    body.querySelectorAll("[data-w]").forEach((b) => b.onclick = () => { const c = W.courses[+b.dataset.w]; c.weight = (c.weight % 3) + 1; saveDraft(); drawCourses(body); });
    body.querySelectorAll("[data-rm]").forEach((b) => b.onclick = () => { W.courses.splice(+b.dataset.rm, 1); saveDraft(); drawCourses(body); validate(); });
    const add = () => {
      const v = $("#newCourse").value.trim();
      if (!v) return;
      W.courses.push({ id: "custom_" + Date.now().toString(36), name: v, weight: 2, category: "custom", weak: false, exam: false });
      saveDraft(); drawCourses(body); validate(); $("#newCourse").focus();
    };
    $("#addCourse").onclick = add;
    $("#newCourse").onkeydown = (e) => { if (e.key === "Enter") add(); };
  }
  async function stepGoals(body) {
    if (!W.goals || W.goalsGrade !== W.a.grade) { W.goals = (await api("goals?grade=" + W.a.grade)).goals; W.goalsGrade = W.a.grade; }
    W.a.goals = W.a.goals.filter((g) => W.goals.some((x) => x.id === g));
    body.innerHTML = inner(`<h2>هدفت از این برنامه چیست؟</h2><p class="lead">تا سه هدف انتخاب کن یا هدف خودت را بنویس.</p>
      <div class="options">${W.goals.map((g) => `<button class="opt ${W.a.goals.includes(g.id) ? "on" : ""}" data-goal="${g.id}"><span class="ic">${g.icon}</span><span class="tt">${h(g.title)}</span><span class="dd">${h(g.desc)}</span></button>`).join("")}</div>
      <div class="note"><label for="goalNote">هدف خودم (اختیاری)</label><textarea class="input" id="goalNote" rows="2" maxlength="300" placeholder="مثلاً: معدل ۱۹ در ترم اول، یا قبولی در دبیرستان نمونه‌ی شهرمان">${h(W.a.goal_note)}</textarea></div>`);
    body.querySelectorAll("[data-goal]").forEach((b) => b.onclick = () => {
      const id = b.dataset.goal, on = W.a.goals.includes(id);
      if (!on && W.a.goals.length >= 3) { toast("حداکثر سه هدف"); return; }
      W.a.goals = on ? W.a.goals.filter((x) => x !== id) : [...W.a.goals, id];
      b.classList.toggle("on", !on); saveDraft(); validate();
    });
    $("#goalNote").oninput = (e) => { W.a.goal_note = e.target.value; saveDraft(); validate(); };
  }
  async function stepConcerns(body) {
    if (!W.concerns) W.concerns = await api("concerns");
    const cat = W.concerns;
    body.innerHTML = inner(`<h2>چه چیزی درس خواندن را برایت سخت می‌کند؟</h2><p class="lead">هر کدام که درباره‌ی تو صدق می‌کند انتخاب کن؛ برنامه و توصیه‌ها بر اساس پژوهش‌های علمی برایش تنظیم می‌شوند.</p>
      <div class="disclaimer"><span>ℹ️</span><span>${h(cat.disclaimer)}</span></div>
      <div class="options">${cat.concerns.map((c) => `<div class="opt ${W.a.concerns.includes(c.id) ? "on" : ""}" data-c="${c.id}" role="button" tabindex="0" aria-pressed="${W.a.concerns.includes(c.id)}">
        <span class="ic">${c.icon}</span><span class="tt">${h(c.title)}</span><span class="dd">${h(c.desc)}</span>
        <button class="why" data-why="${c.id}">چرا و بر چه اساسی؟</button>
        <div class="evidence" hidden>${h(c.why)}<div class="src">${c.sources.map((s) => h(s.text)).join("<br>")}</div></div></div>`).join("")}</div>
      <div class="note"><label for="concernNote">چالش دیگری داری؟ (اختیاری)</label><textarea class="input" id="concernNote" rows="2" maxlength="300" placeholder="مثلاً: سرویس مدرسه دیر می‌رسد و عصرها خسته‌ام">${h(W.a.concern_note)}</textarea></div>`);
    body.querySelectorAll("[data-c]").forEach((b) => {
      const flip = () => {
        const id = b.dataset.c, on = W.a.concerns.includes(id);
        W.a.concerns = on ? W.a.concerns.filter((x) => x !== id) : [...W.a.concerns, id];
        b.classList.toggle("on", !on); b.setAttribute("aria-pressed", !on); saveDraft(); validate();
      };
      b.addEventListener("click", (e) => { if (!e.target.closest(".why, .evidence")) flip(); });
      b.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); flip(); } });
    });
    body.querySelectorAll("[data-why]").forEach((b) => b.onclick = (e) => { e.stopPropagation(); const ev = b.nextElementSibling; ev.hidden = !ev.hidden; });
    $("#concernNote").oninput = (e) => { W.a.concern_note = e.target.value; saveDraft(); };
  }

  const HOURS = Array.from({ length: 18 }, (_, i) => i + 6); // 06..23
  function totalFree() { return DAYS.reduce((a, d) => a + (W.a.availability[d] || []).length * 60, 0); }
  function stepTime(body) {
    const av = W.a.availability;
    const late = W.a.grade <= 6 ? 20 : W.a.grade <= 9 ? 22 : 23;
    body.innerHTML = inner(`<h2>چه ساعت‌هایی در هفته آزادی؟</h2><p class="lead">روی خانه‌ها بکش تا رنگی شوند (ساعت‌هایی که می‌توانی درس بخوانی). بعد از مدرسه، رفت‌وآمد و کلاس‌های دیگرت را حساب کن.</p>
      <div class="paint-tools">
        <button class="btn soft" data-preset="afternoon">عصرها (۱۶ تا ۱۹)</button>
        <button class="btn soft" data-preset="weekend">صبح پنجشنبه و جمعه</button>
        <button class="btn soft" data-preset="evening">شب‌ها (۱۹ تا ۲۱)</button>
        <button class="btn ghost" data-preset="clear">پاک کردن</button>
        <span class="total" id="freeTotal"></span></div>
      <div class="paint" id="paint"><div></div>${DAYS.map((d) => `<div class="dh"><span class="l">${DAY_FA[d]}</span><span class="s">${DAY_FA[d].slice(0, 1)}</span></div>`).join("")}
        ${HOURS.map((hh) => `<div class="hh">${fa(hh)}</div>${DAYS.map((d) => `<div class="cell ${(av[d] || []).includes(hh) ? "on" : ""} ${hh >= late ? "night" : ""}" data-d="${d}" data-h="${hh}" title="${DAY_FA[d]} ${fa(hh)}:۰۰ تا ${fa(hh + 1)}:۰۰"></div>`).join("")}`).join("")}</div>
      <p class="muted" style="font-size:12.5px;margin-top:10px">خانه‌های هاشورخورده نزدیک وقت خواب‌اند؛ برنامه در آن‌ها جلسه‌ی کمتری می‌گذارد تا خوابت کافی باشد.</p>`);
    const paint = $("#paint");
    const upd = () => { $("#freeTotal").textContent = fa(totalFree() / 60) + " ساعت آزاد در هفته"; saveDraft(); validate(); };
    const set = (cell, on) => {
      const d = cell.dataset.d, hh = +cell.dataset.h, list = new Set(av[d] || []);
      on ? list.add(hh) : list.delete(hh);
      av[d] = [...list].sort((a, b) => a - b);
      cell.classList.toggle("on", on);
    };
    paint.addEventListener("pointerdown", (e) => {
      const cell = e.target.closest(".cell"); if (!cell) return;
      W.painting = !cell.classList.contains("on"); set(cell, W.painting); upd();
      paint.setPointerCapture(e.pointerId);
    });
    paint.addEventListener("pointermove", (e) => {
      if (W.painting == null) return;
      const cell = document.elementFromPoint(e.clientX, e.clientY);
      if (cell && cell.classList.contains("cell") && cell.classList.contains("on") !== W.painting) { set(cell, W.painting); upd(); }
    });
    const stop = () => { W.painting = null; };
    paint.addEventListener("pointerup", stop); paint.addEventListener("pointercancel", stop);
    body.querySelectorAll("[data-preset]").forEach((b) => b.onclick = () => {
      const p = b.dataset.preset;
      if (p === "clear") DAYS.forEach((d) => (av[d] = []));
      const add = (days, hs) => days.forEach((d) => (av[d] = [...new Set([...(av[d] || []), ...hs])].sort((x, y) => x - y)));
      if (p === "afternoon") add(["sat", "sun", "mon", "tue", "wed"], [16, 17, 18]);
      if (p === "weekend") add(["thu", "fri"], [9, 10, 11]);
      if (p === "evening") add(["sat", "sun", "mon", "tue", "wed"], [19, 20]);
      stepTime(body); validate();
    });
    upd();
  }
  function stepStart(body) {
    const a = W.a;
    const goals = (W.goals || []).filter((g) => a.goals.includes(g.id)).map((g) => g.title).concat(a.goal_note ? [a.goal_note] : []);
    const concerns = ((W.concerns && W.concerns.concerns) || []).filter((c) => a.concerns.includes(c.id)).map((c) => c.title).concat(a.concern_note ? [a.concern_note] : []);
    body.innerHTML = inner(`<h2>آماده‌ای؟</h2><p class="lead">مشاور هوشمند «برنامه‌ریز» در آسمان با این اطلاعات برایت برنامه و توصیه می‌نویسد و جلسه‌ها را در تقویمت ثبت می‌کند.</p>
      <div class="grid g-2">
        <div class="card"><div class="note" style="margin:0"><label for="nm">اسمت (اختیاری)</label><input class="input" id="nm" maxlength="40" value="${h(a.name)}" placeholder="برای سلام در صفحه‌ی اصلی"></div>
          <div class="note"><label>شروع برنامه</label><div class="seg" id="startSeg">${[0, 1, 2].map((n) => { const d = addDays(today(), n === 2 ? (7 - ((today().getDay() + 1) % 7)) % 7 || 7 : n); return `<button data-start="${iso(d)}" class="${a.start_date === iso(d) ? "on" : ""}">${n === 0 ? "امروز" : n === 1 ? "فردا" : "شنبه‌ی آینده"}</button>`; }).join("")}</div>
            <div class="muted" style="font-size:13px;margin-top:4px" id="startLbl">${jlong(fromIso(a.start_date))}</div></div>
          <div class="note"><label>طول برنامه</label><div class="seg" id="weeksSeg">${[1, 2, 4, 8].map((n) => `<button data-weeks="${n}" class="${a.weeks === n ? "on" : ""}">${fa(n)} هفته</button>`).join("")}</div></div></div>
        <div class="review">
          <div class="row"><b>پایه</b><span>${h(S.meta.grades[a.grade].name)}${a.field ? " · " + h(S.meta.fields[a.field].name) : ""}</span></div>
          <div class="row"><b>دروس</b><span>${fa(W.courses.length)} درس${W.courses.some((c) => c.weak) ? " · ★ " + h(W.courses.filter((c) => c.weak).map((c) => c.name).join("، ")) : ""}</span></div>
          <div class="row"><b>هدف</b><span>${h(goals.join("، "))}</span></div>
          <div class="row"><b>چالش‌ها</b><span>${concerns.length ? h(concerns.join("، ")) : "—"}</span></div>
          <div class="row"><b>زمان آزاد</b><span>${fa(totalFree() / 60)} ساعت در هفته، ${fa(DAYS.filter((d) => (a.availability[d] || []).length).length)} روز</span></div>
        </div></div>`);
    $("#nm").oninput = (e) => { a.name = e.target.value; saveDraft(); };
    body.querySelectorAll("[data-start]").forEach((b) => b.onclick = () => { a.start_date = b.dataset.start; saveDraft(); stepStart(body); });
    body.querySelectorAll("[data-weeks]").forEach((b) => b.onclick = () => { a.weeks = +b.dataset.weeks; saveDraft(); stepStart(body); });
  }

  function next() { if (W.step < steps().length - 1) { W.step++; drawWizard(); } else generate(); }

  // ------------------------------------------------------------ the agent at work
  async function generate() {
    const a = W.a;
    const body = { ...a, courses: W.courses.map(({ id, name, weight, category, weak }) => ({ id, name, weight, category, weak })) };
    const th = $("#thinking");
    th.hidden = false; $("#thinkActions").hidden = true; $("#thinkTitle").textContent = "مشاور هوشمند در حال برنامه‌ریزی است";
    $("#thinkNote").textContent = "این کار معمولاً یک تا دو دقیقه طول می‌کشد.";
    stage("queued", 0);
    try {
      const { job } = await api(`profiles/${PID}/plans`, { method: "POST", body });
      const t0 = Date.now();
      for (;;) {
        await new Promise((r) => setTimeout(r, 1500));
        const st = await api(`jobs/${job}?profile=${PID}`);
        stage(st.status, st.round);
        if (st.status === "done") break;
        if (st.status === "failed") throw new Error(st.error || "ساختن برنامه ناموفق بود");
        if (Date.now() - t0 > 25 * 60 * 1000) throw new Error("مشاور بیش از حد معمول طول کشید");
      }
      await loadPlan();
      store.set("draft", null);
      th.hidden = true; $("#wizard").hidden = true; document.body.style.overflow = "";
      S.weekTab = 0; S.calMonth = null; S.calSel = null;
      location.hash = "#plan"; route();
      toast("برنامه ساخته شد و " + fa(S.plan.weeks * 7) + " روز در تقویمت ثبت شد ✨");
    } catch (e) {
      $("#thinkTitle").textContent = "برنامه ساخته نشد";
      $("#thinkNote").textContent = e.message;
      $("#thinkActions").hidden = false;
    }
  }
  function stage(s, round) {
    const order = ["queued", "thinking", "checking", "repairing", "saving", "done"];
    const idx = order.indexOf(s);
    document.querySelectorAll("#thinkSteps li").forEach((li) => {
      const i = order.indexOf(li.dataset.stage);
      li.classList.toggle("now", i === idx);
      li.classList.toggle("past", i < idx);
      if (li.dataset.stage === "repairing") li.textContent = "اصلاح برنامه توسط مشاور" + (s === "repairing" && round ? " (دور " + fa(round) + ")" : "");
    });
  }

  async function loadPlan() {
    const r = await api("profiles/" + PID);
    S.plan = r.exists ? r.plan : null;
  }

  // ------------------------------------------------------------ boot
  async function boot() {
    stars();
    $("#wizClose").onclick = closeWizard;
    $("#wizBack").onclick = () => { if (W.step) { W.step--; drawWizard(); } };
    $("#wizNext").onclick = () => { if (!$("#wizNext").disabled) next(); };
    $("#thinkRetry").onclick = () => generate();
    $("#thinkCancel").onclick = () => { $("#thinking").hidden = true; };
    addEventListener("hashchange", route);
    try {
      S.meta = await api("meta");
      document.title = S.meta.product;
      $("#brandName").textContent = S.meta.product;
      await loadPlan();
    } catch (e) {
      $("#view-home").innerHTML = `<div class="card">سرور در دسترس نیست: ${h(e.message)}</div>`;
      $("#view-home").classList.add("active");
      return;
    }
    route();
    if (!S.plan && !location.hash) location.hash = "#new";
    setInterval(() => { if (S.view === "home" && $("#wizard").hidden) renderHome(); }, 60000);
  }
  boot();
})();
