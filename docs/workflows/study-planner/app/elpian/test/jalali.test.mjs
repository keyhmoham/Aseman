// The Elpian frontend's Jalali calendar against the platform's ICU (Intl's
// persian calendar), day by day across 1300–1500 AP. Run: node --test elpian/test
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const ctx = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(new URL("../src/util.js", import.meta.url), "utf8"), ctx);
const fmt = new Intl.DateTimeFormat("en-u-ca-persian-nu-latn", { timeZone: "UTC", year: "numeric", month: "numeric", day: "numeric" });
const parts = (d) => Object.fromEntries(fmt.formatToParts(d).filter((p) => p.type !== "literal").map((p) => [p.type, +p.value]));

test("Jalali dates match ICU for two centuries", () => {
  const start = Date.UTC(1921, 2, 21), end = Date.UTC(2121, 2, 21);
  for (let t = start; t < end; t += 86400000) {
    const d = new Date(t);
    const iso = d.toISOString().slice(0, 10);
    const want = parts(d);
    const got = ctx.jOf(iso);
    assert.deepEqual([got.jy, got.jm, got.jd], [want.year, want.month, want.day], iso);
  }
});

test("round trip, weekdays and month lengths", () => {
  assert.equal(ctx.isoOfJdn(ctx.j2d(1405, 1, 1)), "2026-03-21");
  assert.equal(ctx.dayKey("2026-11-07"), "sat");
  assert.equal(ctx.dayKey("2026-11-13"), "fri");
  assert.equal(ctx.addDaysIso("2026-12-31", 1), "2027-01-01");
  for (let jy = 1390; jy < 1420; jy++) {
    const len = ctx.j2d(jy + 1, 1, 1) - ctx.j2d(jy, 12, 1);
    assert.equal(ctx.monthLength(jy, 12), len, "Esfand " + jy);
  }
  assert.equal(ctx.fa("12:05"), "۱۲:۰۵");
});
