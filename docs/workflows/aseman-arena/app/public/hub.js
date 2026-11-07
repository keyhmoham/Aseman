// The web hub: the store's games (each playable in the browser for
// practice) and the overall leaderboard, from the Arena's own API.
(function () {
  function el(tag, attrs, kids) {
    var e = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) { if (k === "text") e.textContent = attrs[k]; else e.setAttribute(k, attrs[k]); });
    (kids || []).forEach(function (k) { e.appendChild(k); });
    return e;
  }
  function get(path) {
    return fetch(path, { credentials: "same-origin" }).then(function (r) {
      if (r.status === 503) return new Promise(function (ok) { setTimeout(ok, 2500); }).then(function () { return get(path); });
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }
  get("api/config").then(function (c) {
    document.getElementById("product").textContent = c.product;
    document.title = c.product;
    if (c.android_apk) { var a = document.getElementById("apk"); a.href = c.android_apk; a.hidden = false; }
  }).catch(function () {});
  get("api/store").then(function (st) {
    var box = document.getElementById("games");
    box.innerHTML = "";
    st.games.forEach(function (g) {
      var art = el("div", { class: "art", style: "background: linear-gradient(135deg, " + g.accent + ", #10131c)" }, [el("span", { text: g.genre }), el("b", { text: g.title })]);
      var kids = [el("p", { text: g.tagline }), el("p", { class: "muted", text: (g.mode || "") + " · " + g.plays + " plays" })];
      if (g.launch.web) kids.push(el("a", { class: "play", href: "play/" + g.slug, text: "Play in the browser" }));
      box.appendChild(el("article", { class: "game" }, [art, el("div", { class: "body" }, kids)]));
    });
    if (!st.games.length) box.appendChild(el("p", { class: "muted", text: "No games yet." }));
  }).catch(function (e) { document.getElementById("games").textContent = "The store is not reachable: " + e.message; });
  get("api/leaderboard").then(function (b) {
    var ol = document.getElementById("leaders");
    ol.innerHTML = "";
    b.rows.slice(0, 10).forEach(function (r) {
      ol.appendChild(el("li", {}, [el("span", { class: "rank", text: "#" + r.rank }), el("span", { class: "dot", style: "background:" + r.color, text: (r.name || "?").charAt(0).toUpperCase() }),
        el("span", { class: "name", text: r.name + " · level " + r.level }), el("span", { class: "muted", text: r.xp + " XP" })]));
    });
    if (!b.rows.length) ol.appendChild(el("li", { class: "muted", text: "Nobody is ranked yet — be the first." }));
  }).catch(function () {});
})();
