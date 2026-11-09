/* Platform API helpers for the Godot shell host */

function api(path, opts) {
  return Aseman.fetch("api/" + path, opts || {}).then(function (r) { return r.json; });
}
