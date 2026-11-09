(function () {
  fetch("/api/game").then(function (r) { return r.json(); }).then(function (g) {
    var a = document.getElementById("webgame");
    if (a && g.web) a.href = "/" + g.web.replace(/^\//, "");
  }).catch(function () {});
})();
