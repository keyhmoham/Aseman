/* آسمان‌درس on Elpian — helpers: Persian digits, the Jalali calendar (QuickJS
 * has no Intl), dates as ISO strings and day numbers, the brand palette. */

var FA_DIGITS = "۰۱۲۳۴۵۶۷۸۹";
function fa(v) { return String(v).replace(/[0-9]/g, function (d) { return FA_DIGITS.charAt(+d); }); }

var DAYS = ["sat", "sun", "mon", "tue", "wed", "thu", "fri"];
var DAY_FA = { sat: "شنبه", sun: "یکشنبه", mon: "دوشنبه", tue: "سه‌شنبه", wed: "چهارشنبه", thu: "پنجشنبه", fri: "جمعه" };
var JMONTHS = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"];

// ---- Jalali <-> Julian day number (the jalaali algorithm, Borkowski) ----
function idiv(a, b) { return ~~(a / b); }
function imod(a, b) { return a - ~~(a / b) * b; }
var J_BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178];
function jalCal(jy) {
  var gy = jy + 621, leapJ = -14, jp = J_BREAKS[0], jm, jump = 0, n, i;
  for (i = 1; i < J_BREAKS.length; i++) {
    jm = J_BREAKS[i]; jump = jm - jp;
    if (jy < jm) break;
    leapJ = leapJ + idiv(jump, 33) * 8 + idiv(imod(jump, 33), 4);
    jp = jm;
  }
  n = jy - jp;
  leapJ = leapJ + idiv(n, 33) * 8 + idiv(imod(n, 33) + 3, 4);
  if (imod(jump, 33) === 4 && jump - n === 4) leapJ += 1;
  var leapG = idiv(gy, 4) - idiv((idiv(gy, 100) + 1) * 3, 4) - 150;
  var march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + idiv(jump + 4, 33) * 33;
  var leap = imod(imod(n + 1, 33) - 1, 4);
  if (leap === -1) leap = 4;
  return { leap: leap, gy: gy, march: march };
}
function g2d(gy, gm, gd) {
  var d = idiv((gy + idiv(gm - 8, 6) + 100100) * 1461, 4) + idiv(153 * imod(gm + 9, 12) + 2, 5) + gd - 34840408;
  return d - idiv(idiv(gy + 100100 + idiv(gm - 8, 6), 100) * 3, 4) + 752;
}
function d2g(jdn) {
  var j = 4 * jdn + 139361631;
  j = j + idiv(idiv(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
  var i = idiv(imod(j, 1461), 4) * 5 + 308;
  var gd = idiv(imod(i, 153), 5) + 1, gm = imod(idiv(i, 153), 12) + 1;
  return { gy: idiv(j, 1461) - 100100 + idiv(8 - gm, 6), gm: gm, gd: gd };
}
function j2d(jy, jm, jd) {
  var r = jalCal(jy);
  return g2d(r.gy, 3, r.march) + (jm - 1) * 31 - idiv(jm, 7) * (jm - 7) + jd - 1;
}
function d2j(jdn) {
  var gy = d2g(jdn).gy, jy = gy - 621, r = jalCal(jy), k = jdn - g2d(gy, 3, r.march);
  if (k >= 0) {
    if (k <= 185) return { jy: jy, jm: 1 + idiv(k, 31), jd: imod(k, 31) + 1 };
    k -= 186;
  } else {
    jy -= 1; k += 179;
    if (r.leap === 1) k += 1;
  }
  return { jy: jy, jm: 7 + idiv(k, 30), jd: imod(k, 30) + 1 };
}

// ---- dates as ISO strings ----
function pad2(n) { return (n < 10 ? "0" : "") + n; }
function isoOfJdn(jdn) { var g = d2g(jdn); return g.gy + "-" + pad2(g.gm) + "-" + pad2(g.gd); }
function jdnOfIso(s) { var p = String(s).split("-"); return g2d(+p[0], +p[1], +p[2]); }
function todayIso() { var d = new Date(); return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()); }
function addDaysIso(s, n) { return isoOfJdn(jdnOfIso(s) + n); }
function dayKeyOfJdn(jdn) { return DAYS[imod(imod(jdn, 7) + 2, 7)]; } // jdn % 7 == 0 is a Monday
function dayKey(iso) { return dayKeyOfJdn(jdnOfIso(iso)); }
function jOf(iso) { return d2j(jdnOfIso(iso)); }
function jlong(iso) { var j = jOf(iso); return DAY_FA[dayKey(iso)] + " " + fa(j.jd) + " " + JMONTHS[j.jm - 1] + " " + fa(j.jy); }
function jshort(iso) { var j = jOf(iso); return fa(j.jd) + " " + JMONTHS[j.jm - 1]; }
function monthLength(jy, jm) { return jm <= 6 ? 31 : jm <= 11 ? 30 : (jalCal(jy).leap === 0 ? 30 : 29); }
function nowMin() { var d = new Date(); return d.getHours() * 60 + d.getMinutes(); }
function toMin(hm) { var p = String(hm).split(":"); return (+p[0]) * 60 + (+p[1]); }
function minsFa(m) {
  m = Math.round(m);
  var h = Math.floor(m / 60), r = m % 60;
  return h ? fa(h) + " ساعت" + (r ? " و " + fa(r) + " دقیقه" : "") : fa(r) + " دقیقه";
}
function hoursFa(m) { return fa(String(Math.round(m / 6) / 10)).replace(".", "٫"); }
function span(x) { return fa(x.start) + "–" + fa(x.end); }

// ---- the brand palette (the web app's) ----
var BRAND = {
  primary: "#5b5bd6", primary2: "#8b5cf6", night1: "#1e1b4b", night2: "#312e81", night3: "#4c1d95",
  star: "#f5d0fe", lilac: "#c7d2fe", ok: "#10a37f", warn: "#d97706",
  sky: "linear-gradient(160deg, #4c1d95, #312e81, #1e1b4b)",
  accent: "linear-gradient(135deg, #5b5bd6, #8b5cf6)",
};
var CAT_HEX = { math: "#6366f1", science: "#10b981", language: "#f59e0b", humanities: "#ec4899", religion: "#14b8a6", skill: "#8b5cf6", custom: "#64748b", special: "#0ea5e9" };
var TYPE_HEX = { learn: "#6366f1", practice: "#ec4899", review: "#10b981", weekly_review: "#0ea5e9", timed_test: "#f59e0b" };
var TYPE_ICON = { learn: "menu_book", practice: "edit_note", review: "replay", weekly_review: "explore", timed_test: "timer" };
function catColor(c) { return CAT_HEX[c] || CAT_HEX.custom; }

// Material icons for the catalog items (the web app shows emoji).
var GOAL_ICON = { grades: "trending_up", final_exam: "assignment", konkur: "military_tech", catch_up: "hiking", entrance: "school", olympiad: "emoji_events", habit: "eco", deep: "travel_explore" };
var CONCERN_ICON = { adhd: "bolt", focus: "bubble_chart", test_anxiety: "psychology", stress: "spa", procrastination: "hourglass_top", sleep: "bedtime", phone: "smartphone",
  motivation: "battery_alert", learning_disorder: "translate", burnout: "local_fire_department", perfectionism: "diamond", memory: "extension",
  time_management: "explore", weak_basics: "construction", low_mood: "cloud" };
var FIELD_ICON = { math: "calculate", science: "science", humanities: "history_edu", islamic: "auto_stories", vocational: "handyman" };
