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

/* ---- layout ---------------------------------------------------------- */

// compact (phones, < 600) · medium (small tablets) · expanded (desk windows, ≥ 840)
function sizeClass() {
  var v = (Decillion.viewport && Decillion.viewport()) || {};
  if (v.sizeClass) { return v.sizeClass; }
  var w = Number(v.width) || 360;
  return w < 600 ? "compact" : w < 840 ? "medium" : "expanded";
}
function isCompact() { return sizeClass() === "compact"; }
function isExpanded() { return sizeClass() === "expanded"; }
function gutter() { return isCompact() ? "16" : "24"; }

function colors() {
  var env = Decillion.env() || {};
  return (env.theme && env.theme.colors) || {};
}

// The page's content column: full width on phones, centred and capped on wide windows.
function pageColumn(children, opts) {
  opts = opts || {};
  return { type: "Center", children: [{ type: "Container", props: { style: { maxWidth: String(opts.maxWidth || 1200), width: "100%" } }, children: [
    { type: "Column", props: { style: { padding: opts.padding || (gutter() + " " + gutter() + " 32 " + gutter()), gap: opts.gap || "20", alignItems: "stretch" } },
      children: children.filter(Boolean) },
  ] }] };
}

/* ---- what a result is about ------------------------------------------ */

var DOMAIN_ICONS = {
  shopping: "shopping_bag", classifieds: "sell", real_estate: "apartment", cars: "directions_car", food: "restaurant",
  travel_tickets: "flight", stays: "hotel", maps: "place", health: "medical_services", books: "menu_book",
  courses: "school", jobs: "work", freelance: "handshake", software: "apps", prices: "paid", stocks: "candlestick_chart",
  news: "article", media: "movie", weather_time: "wb_sunny", reference: "auto_stories", law: "account_balance", sports: "sports_soccer",
};
var SERVICE_ICONS = {
  gmaps: "place", neshan: "map", balad: "map", tgju: "paid", iran_gold: "paid", iran_crypto: "paid", wikipedia: "auto_stories",
  digikala: "shopping_bag", torob: "shopping_bag", emalls: "shopping_bag", technolife: "shopping_bag", basalam: "shopping_bag",
  snappshop: "shopping_bag", mobile: "shopping_bag", divar: "sell", sheypoor: "sell", kilid: "apartment", bama: "directions_car",
  khodro45: "directions_car", snapp: "restaurant", tapsifood: "restaurant", okala: "shopping_basket", mrbilit: "flight",
  alibaba: "flight", flytoday: "flight", raja: "train", bus: "directions_bus", snapptrip: "hotel", jabama: "hotel",
  otaghak: "hotel", eghamat24: "hotel", paziresh24: "medical_services", doctoreto: "medical_services", exiryab: "medical_services",
  darukade: "medication", iran_news: "article", iran_jobs: "work",
};

// The categories offered on the first page, each with a query that shows it off.
var CATEGORIES = [
  { id: "shopping", label: "Shopping", icon: "shopping_bag", q: "ارزان‌ترین گوشی سامسونگ زیر ۲۰ میلیون تومان" },
  { id: "travel_tickets", label: "Flights & trains", icon: "flight", q: "بلیط پرواز تهران به مشهد فردا" },
  { id: "maps", label: "Places", icon: "place", q: "کافه‌های خوب در شیراز" },
  { id: "health", label: "Doctors", icon: "medical_services", q: "دکتر پوست در اصفهان" },
  { id: "real_estate", label: "Homes", icon: "apartment", q: "اجاره آپارتمان دو خوابه در تهران" },
  { id: "cars", label: "Cars", icon: "directions_car", q: "قیمت پژو ۲۰۷ کارکرده" },
  { id: "prices", label: "Gold & currency", icon: "paid", q: "قیمت طلا و دلار امروز" },
  { id: "news", label: "News", icon: "article", q: "آخرین اخبار اقتصادی" },
];

function iconFor(serviceId, domain) {
  return SERVICE_ICONS[serviceId] || DOMAIN_ICONS[domain] || "travel_explore";
}

// Only an absolute https address is drawn: sites also answer with relative paths and http.
function imageUrl(h) {
  var u = String((h && h.image) || "").trim();
  if (u.indexOf("//") === 0) { u = "https:" + u; }
  return /^https:\/\/[^\s"'<>]+$/i.test(u) ? u : "";
}

// A rating in the hit's detail line: "★ 4.6 (1,204)" (Google Maps) or "rating: 4.5".
function ratingOf(h) {
  var d = String((h && h.detail) || "");
  var m = d.match(/★\s*([0-5](?:\.\d)?)(?:\s*\(([\d,]+)\))?/) || d.match(/rating:\s*([0-5](?:\.\d+)?)/i);
  if (!m) { return null; }
  return { value: Number(m[1]), count: m[2] ? Number(String(m[2]).replace(/,/g, "")) : 0 };
}

function compactNumber(n) {
  n = Number(n) || 0;
  if (n >= 1e9) { return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1).replace(/\.0$/, "") + "B"; }
  if (n >= 1e6) { return (n / 1e6).toFixed(n >= 1e8 ? 0 : 1).replace(/\.0$/, "") + "M"; }
  if (n >= 1e3) { return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1).replace(/\.0$/, "") + "K"; }
  return String(Math.round(n));
}

// Every hit of a search, with where it came from; `rank` keeps the services' own order.
function flatHits(results) {
  var out = [];
  if (!results) { return out; }
  var domain = ((results.frame && results.frame.domains) || [])[0];
  domain = domain ? (domain.name || domain) : "";
  (results.services || []).forEach(function (svc) {
    (svc.hits || []).forEach(function (h, i) {
      out.push({ hit: h, service: svc.id, source: svc.title, index: i, rank: i * 100 + out.length, domain: domain });
    });
  });
  return out;
}

function sortHits(items, sort) {
  var list = items.slice();
  if (sort === "price") {
    list.sort(function (a, b) {
      var pa = a.hit.price_toman || Infinity, pb = b.hit.price_toman || Infinity;
      return pa === pb ? a.rank - b.rank : pa - pb;
    });
  } else if (sort === "rating") {
    list.sort(function (a, b) {
      var ra = ratingOf(a.hit), rb = ratingOf(b.hit);
      var sa = ra ? ra.value + Math.min(ra.count, 5000) / 100000 : -1, sb = rb ? rb.value + Math.min(rb.count, 5000) / 100000 : -1;
      return sa === sb ? a.rank - b.rank : sb - sa;
    });
  } else {
    list.sort(function (a, b) { return a.rank - b.rank; });
  }
  return list;
}

// The cheapest priced hit, when at least two hits carry a price (one price is not a deal).
function lowestPrice(items) {
  var priced = items.filter(function (x) { return x.hit.price_toman > 0; });
  if (priced.length < 2) { return null; }
  return sortHits(priced, "price")[0];
}

function seconds(ms) {
  ms = Number(ms) || 0;
  return ms < 1000 ? ms + " ms" : (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + " s";
}
