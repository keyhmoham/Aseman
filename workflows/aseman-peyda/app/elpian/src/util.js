/* Peyda: small helpers shared by every screen (global scope; see manifest.json). */

var EXAMPLES = [
  "ارزان‌ترین گوشی سامسونگ زیر ۲۰ میلیون تومان",
  "بلیط پرواز تهران به مشهد فردا",
  "دکتر پوست در اصفهان",
  "قیمت طلا و دلار امروز",
  "cheapest pizza near Saadat Abad",
];

function T(text, variant, extra) {
  var props = { text: String(text == null ? "" : text), variant: variant || "bodyMedium" };
  if (extra) { for (var k in extra) { props[k] = extra[k]; } }
  return { type: "Text", props: props };
}

function money(n) {
  if (!n) { return ""; }
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + " Toman";
}

function errorText(e) {
  if (e && e.status === 401) { return "Sign in to chat with Peyda."; }
  if (e && e.status === 503) { return "Peyda is waking up. Try again in a moment."; }
  if (e && e.status === 409) { return "Peyda is still answering your last message."; }
  return (e && e.message) ? String(e.message) : "Something went wrong. Please try again.";
}

function signedIn() {
  var env = Decillion.env() || {};
  return !!env.user;
}

// A link the host opens in the browser: Markdown links do that without a handler.
function linkTitle(title, url) {
  var safe = String(title || "").replace(/[\[\]]/g, " ");
  return url ? "**[" + safe + "](" + url + ")**" : "**" + safe + "**";
}

// What the model understood, as short tags for the results page.
function understood(frame) {
  var tags = [];
  if (!frame) { return tags; }
  (frame.domains || []).slice(0, 2).forEach(function (d) { tags.push({ text: String(d.name || d).replace(/_/g, " "), status: "info", icon: "category" }); });
  var s = frame.slots || {};
  if (s.product) { tags.push({ text: s.product, icon: "sell" }); }
  if (s.brand) { tags.push({ text: s.brand, icon: "storefront" }); }
  if (s.city) { tags.push({ text: s.city, icon: "location_on" }); }
  if (s.origin && s.destination) { tags.push({ text: s.origin + " → " + s.destination, icon: "route" }); }
  if (s.date) { tags.push({ text: s.date, icon: "event" }); }
  if (s.price_max_toman) { tags.push({ text: "≤ " + money(s.price_max_toman), icon: "payments" }); }
  if (s.price_min_toman) { tags.push({ text: "≥ " + money(s.price_min_toman), icon: "payments" }); }
  return tags;
}

function tagNode(t) {
  return { type: "Tag", props: { text: t.text, status: t.status, icon: t.icon } };
}

// One line for the live trace of a run.
function traceLine(ev) {
  if (ev.type === "stage") {
    var names = { plan: "Reading your message in the chat", extract: "Understanding the query", search: "Searching the services", review: "The analyst is reviewing the results", answer: "Writing the answer" };
    return (names[ev.name] || ev.name) + (ev.round > 1 ? " · round " + ev.round : "");
  }
  if (ev.type === "frame") { return "Understood: " + understood(ev.frame).map(function (t) { return t.text; }).join(" · "); }
  if (ev.type === "service") { return ev.title + ": " + (ev.status === "ok" ? ev.count + " results" : ev.status === "empty" ? "nothing found" : ev.status === "skipped" ? "needs more detail" : "not answering"); }
  if (ev.type === "review") { return "Analyst: " + (ev.verdict === "refine" ? "refining the query" : ev.verdict === "satisfied" ? "these results will do" : ev.verdict.replace("_", " ")) + (ev.reason ? " — " + ev.reason : ""); }
  if (ev.type === "note") { return ev.text; }
  if (ev.type === "results") { return "Round " + ev.round + ": " + ev.total + " results"; }
  return "";
}
