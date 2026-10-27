// A calculator written the way generated apps often are, with two defects
// that only show after "÷" then "=": the view calls toFixed on a null result,
// and the error state puts a TextField straight into a Row. check.mjs must
// find both (it explores states), with the steps that lead there.
var KEYS = [["7", "8", "9", "÷"], ["4", "5", "6", "×"], ["1", "2", "3", "−"], ["C", "0", "=", "+"]];
var app = App.create({
  state: { a: null, op: null, entry: "0", result: 0, shown: "entry", error: null, note: "" },
  view: function (s, app) {
    var display = s.shown === "result" ? s.result.toFixed(2) : s.entry; // throws when result is null
    return { type: "Column", props: { style: { padding: "16", gap: "12" } }, children: [
      { type: "Text", props: { text: display, variant: "displayMediumEmphasized", textAlign: "right" } },
      s.error ? { type: "Row", children: [
        { type: "Icon", props: { icon: "error" } },
        { type: "TextField", key: "note", props: { hint: "Add a note" }, events: { input: app.handler("note", function (e, app) { app.set({ note: e.value }, { silent: true }); }) } },
      ] } : null,
      { type: "Column", props: { style: { gap: "8" } }, children: KEYS.map(function (row, r) {
        return { type: "Row", props: { style: { gap: "8" } }, children: row.map(function (k) {
          return { type: "Expanded", children: [{ type: "Button", props: { text: k, variant: /[0-9]/.test(k) ? "tonal" : "filled", size: "m" },
            events: { tap: app.handler("key_" + k, function () { press(k); }) } }] };
        }) };
      }) },
    ] };
  },
  widget: { static: true, view: function (s) { return { type: "Stat", props: { label: "Last result", value: s.result || 0 } }; } },
});
function press(k) {
  var s = app.state;
  if (/[0-9]/.test(k)) return app.set({ entry: s.entry === "0" || s.shown === "result" ? k : s.entry + k, shown: "entry", error: null });
  if (k === "C") return app.set({ a: null, op: null, entry: "0", shown: "entry", error: null });
  if (k === "=") {
    if (s.op === null) return;
    var b = Number(s.entry), r;
    if (s.op === "÷" && b === 0) { r = null; app.set({ error: "Cannot divide by zero" }); }
    else r = s.op === "+" ? s.a + b : s.op === "−" ? s.a - b : s.op === "×" ? s.a * b : s.a / b;
    return app.set({ result: r, shown: "result", a: null, op: null, entry: "0" });
  }
  app.set({ a: Number(s.entry), op: k, entry: "0", shown: "entry" });
}
