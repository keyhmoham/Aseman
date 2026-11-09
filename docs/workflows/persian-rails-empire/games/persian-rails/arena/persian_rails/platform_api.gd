## Platform HTTP client — web uses window.fetch + polled result (reliable under Aseman proxy).
extends Node

signal response(ok: bool, path: String, data: Dictionary, err: String)

var base_url := ""
var user_id := "visitor"
var user_name := ""
var user_handle := ""
var _http: HTTPRequest
var _queue: Array = []
var _busy := false
var _inflight_path := ""
var _req_id := 0
var _poll_key := ""
var _poll_age := 0.0
const FETCH_TIMEOUT_S := 5.0


func _ready() -> void:
	if OS.has_feature("web"):
		_setup_js_fetch()
		set_process(true)
	else:
		_http = HTTPRequest.new()
		_http.timeout = 12.0
		add_child(_http)
		_http.request_completed.connect(_on_http_done)
		set_process(false)
	if base_url.is_empty():
		base_url = detect_base()


func _setup_js_fetch() -> void:
	JavaScriptBridge.eval("""
(function () {
  window.__railsFetch = function (id, url, method, body, headersJson) {
    var key = '__railsFetchResult_' + id;
    window[key] = null;
    var headers = {};
    try { headers = JSON.parse(headersJson || '{}'); } catch (e) {}
    var opts = { method: method || 'GET', headers: headers, credentials: 'same-origin' };
    if (body && method && method.toUpperCase() !== 'GET' && method.toUpperCase() !== 'HEAD') {
      opts.body = body;
    }
    var u = url;
    try {
      if (window.__asemanProxyFix) u = window.__asemanProxyFix(url);
    } catch (e1) {}
    fetch(u, opts).then(function (r) {
      return r.text().then(function (t) {
        window[key] = JSON.stringify({ ok: !!r.ok, code: r.status|0, body: t || '' });
      });
    }).catch(function (e) {
      window[key] = JSON.stringify({
        ok: false, code: 0, body: '', err: String(e && e.message ? e.message : e)
      });
    });
  };
})();
""", true)


func _process(delta: float) -> void:
	if _poll_key == "":
		return
	_poll_age += delta
	var raw = JavaScriptBridge.eval("window[%s]" % JSON.stringify(_poll_key), true)
	if raw != null and str(raw) != "" and str(raw) != "null" and str(raw) != "undefined":
		JavaScriptBridge.eval("window[%s] = null" % JSON.stringify(_poll_key), true)
		_poll_key = ""
		_poll_age = 0.0
		var parsed = JSON.parse_string(str(raw))
		var code := 0
		var body := ""
		var ok_http := false
		if typeof(parsed) == TYPE_DICTIONARY:
			code = int(parsed.get("code", 0))
			body = str(parsed.get("body", ""))
			ok_http = bool(parsed.get("ok", false))
		_finish(ok_http, code, body)
		return
	if _poll_age >= FETCH_TIMEOUT_S:
		JavaScriptBridge.eval("window[%s] = null" % JSON.stringify(_poll_key), true)
		_poll_key = ""
		_poll_age = 0.0
		_finish(false, 0, "")


static func detect_base() -> String:
	if OS.has_feature("web"):
		var from_q := _query_value("api_base")
		if from_q != "" and _looks_like_app_api(from_q):
			return _normalize_api_base(from_q)
		var path := str(JavaScriptBridge.eval("window.location.pathname", true))
		var idx := path.find("/games/")
		if idx >= 0:
			return _normalize_api_base(path.substr(0, idx))
		# Root-relative — Aseman proxy + __asemanProxyFix rewrite this.
		return "/api/"
	var env := OS.get_environment("RAILS_API").strip_edges()
	if env != "":
		return _normalize_api_base(env)
	return "http://127.0.0.1:8080/api/"


static func _looks_like_app_api(u: String) -> bool:
	var s := u.to_lower()
	return "/app/api" in s or s == "/api" or s.begins_with("/api/") or "/platforms/" in s


static func _query_value(key: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var q = JavaScriptBridge.eval("window.location.search", true)
	if typeof(q) != TYPE_STRING:
		return ""
	for pair in str(q).trim_prefix("?").split("&", false):
		var kv := pair.split("=")
		if kv.size() == 2 and kv[0].uri_decode() == key:
			return kv[1].uri_decode()
	return ""


static func _normalize_api_base(raw: String) -> String:
	var u := raw.strip_edges()
	if u.is_empty():
		return "/api/"
	if u.begins_with("/") and not u.begins_with("//"):
		if not u.ends_with("/"):
			u += "/"
		if not u.ends_with("api/"):
			u = u.rstrip("/") + "/api/"
		return u
	if not u.ends_with("/"):
		u += "/"
	if not u.ends_with("api/"):
		u = u.rstrip("/") + "/api/"
	return u


func configure(p: Dictionary) -> void:
	if p.has("api_base") and str(p.api_base) != "":
		var raw := str(p.api_base)
		if _looks_like_app_api(raw):
			base_url = _normalize_api_base(raw)
		else:
			base_url = detect_base()
	if p.has("user_id") and str(p.user_id) != "":
		user_id = str(p.user_id)
	if p.has("player_name") and str(p.player_name) != "":
		user_name = str(p.player_name)
	if p.has("handle") and str(p.handle) != "":
		user_handle = str(p.handle)


func get_json(path: String) -> void:
	_enqueue("GET", path, "")


func post_json(path: String, body: Dictionary) -> void:
	_enqueue("POST", path, JSON.stringify(body))


func _enqueue(method: String, path: String, body: String) -> void:
	_queue.append({"method": method, "path": path, "body": body})
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	var job: Dictionary = _queue.pop_front()
	_inflight_path = str(job.path)
	if base_url.is_empty():
		base_url = detect_base()
	var url := base_url.rstrip("/") + "/" + str(job.path).lstrip("/")
	var headers := {
		"Content-Type": "application/json",
		"Accept": "application/json",
		"X-Aseman-User": user_id,
		"X-Rails-User": user_id,
	}
	if user_name != "":
		headers["X-Aseman-Name"] = user_name
	if user_handle != "":
		headers["X-Aseman-Handle"] = user_handle

	if OS.has_feature("web"):
		_req_id += 1
		var id := _req_id
		_poll_key = "__railsFetchResult_%d" % id
		_poll_age = 0.0
		JavaScriptBridge.eval("window[%s] = null" % JSON.stringify(_poll_key), true)
		JavaScriptBridge.eval(
			"window.__railsFetch(%d, %s, %s, %s, %s)" % [
				id,
				JSON.stringify(url),
				JSON.stringify(str(job.method)),
				JSON.stringify(str(job.body)),
				JSON.stringify(JSON.stringify(headers)),
			],
			true
		)
		return

	var hdrs := PackedStringArray()
	for k in headers.keys():
		hdrs.append("%s: %s" % [k, headers[k]])
	var method := HTTPClient.METHOD_GET if str(job.method) == "GET" else HTTPClient.METHOD_POST
	var err := _http.request(url, hdrs, method, str(job.body))
	if err != OK:
		_busy = false
		var p := _inflight_path
		_inflight_path = ""
		response.emit(false, p, {}, "درخواست ارسال نشد")
		_pump()


func _on_http_done(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_finish(code >= 200 and code < 300, code, body.get_string_from_utf8())


func _finish(ok_http: bool, code: int, text: String) -> void:
	_busy = false
	var path := _inflight_path
	_inflight_path = ""
	var data: Dictionary = {}
	var parsed_ok := false
	if text != "":
		var parsed = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			data = parsed
			parsed_ok = true
	var ok := ok_http and parsed_ok
	var err := ""
	if not ok:
		if code == 0:
			err = "فعلاً به سرور وصل نیستیم. یکم بعد دوباره بیا."
		elif not parsed_ok and code >= 200 and code < 300:
			err = "آدرس API اشتباه است (پاسخ JSON نبود)."
		else:
			err = str(data.get("error", "خطای سرور (%d)" % code))
	response.emit(ok, path, data, err)
	_pump()
