## Full-app Godot shell — replaces Flutter/Elpian 5-tab UI with HUD design language.
extends Control

signal arena_event(json: String)

const Fonts = preload("res://arena/persian_rails/fonts.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")
const Assets = preload("res://arena/persian_rails/assets.gd")
const Ui = preload("res://arena/persian_rails/ui_kit.gd")
const PlatformApi = preload("res://arena/persian_rails/platform_api.gd")
const ArenaScene = preload("res://arena/persian_rails/main.tscn")

const TABS := [
	{"id": "home", "label": "خانه"},
	{"id": "play", "label": "بازی"},
	{"id": "atlas", "label": "اطلس"},
	{"id": "ranks", "label": "افتخار"},
	{"id": "rules", "label": "قوانین"},
]

var _api: Node
var _d: Dictionary = {}
var _tab := "home"
var _cfg: Dictionary = {}
var _fa: Dictionary = {}
var _booted := false
var _boot_error := ""
var _atlas = null
var _atlas_error := ""
var _board = null
var _board_error := ""
var _rules = null
var _rules_error := ""
var _play_level := 2
var _play_ai := 1
var _launching := false
var _play_error := ""
var _match: Dictionary = {}
var _outcome: Dictionary = {}
var _result_server: Dictionary = {}
var _submitting := false
var _pending := ""

var _root: Control
var _chrome: Control
var _scroll: ScrollContainer
var _body: VBoxContainer
var _nav: PanelContainer
var _nav_row: HBoxContainer
var _arena: Node = null
var _play_overlay: CanvasLayer
var _leave_btn: Button
var _result_layer: CanvasLayer


func _ready() -> void:
	layout_direction = Control.LAYOUT_DIRECTION_RTL
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_install_font()
	_api = PlatformApi.new()
	_api.name = "PlatformApi"
	add_child(_api)
	_api.response.connect(_on_api)
	_api.configure(_params_from_page())
	_build()
	get_viewport().size_changed.connect(_on_resize)
	_on_resize()
	_boot()
	# Direct match deep-link (legacy web embed with query params).
	var q := _params_from_page()
	if q.has("level") and (q.has("token") or q.has("match") or bool(q.get("autostart", false))):
		call_deferred("_autostart_match", q)


## Arena contract — host may call these on the pack root (shell).
## Bootstrap params (api_base / player_name) only configure the shell.
## A real match needs level/token/autostart (or the in-shell Play tab).
func arena_start(p: Dictionary = {}) -> void:
	_api.configure(p)
	var wants_match := p.has("level") or p.has("token") or p.has("match") or bool(p.get("autostart", false))
	if wants_match:
		_begin_arena(p)
	elif not _booted:
		_boot()


func arena_stop() -> void:
	_end_arena(false)


func arena_state() -> Dictionary:
	if _arena and _arena.has_method("arena_state"):
		return _arena.arena_state()
	return {}


func _install_font() -> void:
	var font := Fonts.regular()
	if font == null:
		return
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 22
	theme.set_font("font", "Label", font)
	theme.set_font("font", "Button", Fonts.bold() if Fonts.bold() else font)
	get_tree().root.theme = theme


func _params_from_page() -> Dictionary:
	var out := {}
	if not OS.has_feature("web"):
		return out
	var q = JavaScriptBridge.eval("window.location.search", true)
	if typeof(q) != TYPE_STRING:
		return out
	for pair in str(q).trim_prefix("?").split("&", false):
		var kv := pair.split("=")
		if kv.size() == 2:
			out[kv[0].uri_decode()] = kv[1].uri_decode()
	for k in ["level", "ai_count", "wagons"]:
		if out.has(k):
			out[k] = int(out[k])
	# Always resolve API against the platform app, even without query params.
	if not out.has("api_base"):
		var detected := PlatformApi.detect_base()
		if detected != "":
			out["api_base"] = detected
	return out


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.layout_direction = Control.LAYOUT_DIRECTION_RTL
	add_child(_root)

	var bg := Control.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	Ui.wood_backdrop(bg)

	_chrome = Control.new()
	_chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_chrome)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chrome.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	_scroll.add_child(_body)

	_nav = Ui.framed("top", 10.0, 1.0)
	_nav.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_chrome.add_child(_nav)
	_nav_row = HBoxContainer.new()
	_nav_row.add_theme_constant_override("separation", 0)
	_nav_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_nav.add_child(_nav_row)

	# No floating web/leave shortcut over the board — exit lives in the HUD top bar.
	_play_overlay = CanvasLayer.new()
	_play_overlay.layer = 40
	_play_overlay.visible = false
	add_child(_play_overlay)
	_leave_btn = null

	_result_layer = CanvasLayer.new()
	_result_layer.layer = 50
	_result_layer.visible = false
	add_child(_result_layer)


func _on_resize() -> void:
	var vp := get_viewport().get_visible_rect().size
	_d = Ui.density_for(vp)
	var s: float = float(_d.scale)
	var pad: float = float(_d.pad)
	var nav_h: float = float(_d.get("shell_nav_h", clampf(72.0 * s, 64.0, 88.0)))
	_nav.offset_left = 6
	_nav.offset_right = -6
	_nav.offset_top = -nav_h - 6.0
	_nav.offset_bottom = -6
	_nav.add_theme_stylebox_override("panel", Assets.style_tex("panel_top.png", pad * 0.7, 32.0 * minf(s, 2.0)))
	_scroll.offset_left = 0
	_scroll.offset_right = 0
	_scroll.offset_top = 0
	_scroll.offset_bottom = -nav_h - 8.0
	# Full-bleed shell content — never pinch to a narrow 420px column on phones.
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.custom_minimum_size = Vector2(maxf(280.0, vp.x - 4.0), 0)
	_rebuild_nav()
	_rebuild_body()


func _sf(key: String, fallback_key: String = "font_body") -> int:
	return int(_d.get(key, _d.get(fallback_key, 16)))


func _btn_h() -> float:
	return float(_d.get("shell_btn_h", _d.get("btn_h", 54.0)))


func _t(key: String, fallback: String = "") -> String:
	return str(_fa.get(key, fallback if fallback else key))


func _boot() -> void:
	# Never block the 5-tab shell on network — show UI immediately, refresh if API answers.
	_boot_error = ""
	_apply_offline_fallback()
	_booted = true
	_pending = "me"
	_rebuild_body()
	_api.get_json("me")


func _on_api(ok: bool, path: String, data: Dictionary, err: String) -> void:
	var p := path
	if p.begins_with("/"):
		p = p.substr(1)
	if p == "me" or (_pending == "me" and p.ends_with("me")):
		_pending = ""
		if ok and data.has("me"):
			_cfg = data
			_fa = data.get("fa", {})
			if typeof(_fa) != TYPE_DICTIONARY:
				_fa = {}
			_booted = true
			_boot_error = ""
			var me = data.get("me", {})
			if typeof(me) == TYPE_DICTIONARY:
				_api.user_name = str(me.get("name", _api.user_name))
		# Soft-fail: keep offline shell if me fails; do not trap user on a spinner.
		_rebuild_body()
		return
	if p == "atlas" or p.ends_with("atlas"):
		if ok:
			_atlas = data
			_atlas_error = ""
		else:
			_atlas = _local_atlas()
			_atlas_error = "" if _atlas != null else err
		_rebuild_body()
		return
	if p == "leaderboard" or p.ends_with("leaderboard"):
		if ok:
			_board = data
			_board_error = ""
		else:
			# Empty board is still usable; keep a soft note for retry.
			_board = {"board": [], "offline": true, "error": err}
			_board_error = ""
		_rebuild_body()
		return
	if p == "rules" or p.ends_with("rules"):
		if ok:
			_rules = data
			_rules_error = ""
		else:
			_rules = _local_rules()
			_rules_error = "" if _rules != null else err
		_rebuild_body()
		return
	if p == "matches" or (p.begins_with("matches") and not p.ends_with("/result")):
		_launching = false
		var params := _local_match_params()
		if ok:
			_play_error = ""
			_match = data.get("match", {})
			var launch: Dictionary = data.get("launch", {})
			var lp: Dictionary = launch.get("params", {})
			if typeof(lp) == TYPE_DICTIONARY:
				for k in lp.keys():
					params[k] = lp[k]
			_begin_arena(params)
		else:
			# Offline practice — still open the board with HUD chrome.
			_play_error = ""
			_match = {}
			_begin_arena(params)
		return
	if p.ends_with("/result"):
		_submitting = false
		if ok:
			_result_server = data
		else:
			_play_error = err
		_show_result_overlay()
		return


func _apply_offline_fallback() -> void:
	# Local pack still works without the platform server.
	_booted = true
	var fa_res = _load_json("res://arena/persian_rails/data/fa.json")
	if typeof(fa_res) == TYPE_DICTIONARY:
		_fa = fa_res
	_cfg = {
		"product": _t("product", "امپراتوری راه‌آهن پارس"),
		"fa": _fa,
		"me": {"name": "مهمان", "rating": 1200, "progress": {"level": 1}},
		"game": {
			"title": _t("product", "امپراتوری راه‌آهن پارس"),
			"tagline": _t("tagline", "شهرهای ایران را با لبخند به هم وصل کن"),
			"settings": {"level": {"default": 2}, "ai_count": {"default": 1}},
		},
	}
	_boot_error = ""


func _load_json(path: String):
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _local_atlas():
	var culture = _load_json("res://arena/persian_rails/data/culture.json")
	if typeof(culture) != TYPE_ARRAY:
		return null
	return {"culture": culture, "fa": _fa, "local": true}


func _local_rules() -> Dictionary:
	return {
		"title": "قوانین خودمونی",
		"turns": [
			"تو هر نوبت یکی از این سه کار رو انجام بده:",
			"۱) دو کارت رنگی بردار (از روی میز یا از دسته).",
			"۲) یک مسیر آزاد بساز و به تعداد طولش کارت بده.",
			"۳) قرارداد مقصد بردار و حداقل یکی‌ش رو نگه دار.",
		],
		"end": "وقتی واگن‌هات به ۲ یا کمتر رسید، همه یک نوبت آخر دارن.",
		"note": _t("scenario_note", "بعضی مسیرها سناریویی‌ان و با برچسب مشخص شدن."),
		"local": true,
	}


func _set_tab(id: String) -> void:
	_tab = id
	if id == "atlas" and _atlas == null and _atlas_error == "":
		_load_atlas()
	elif id == "ranks" and _board == null and _board_error == "":
		_load_board()
	elif id == "rules" and _rules == null and _rules_error == "":
		_load_rules()
	_rebuild_nav()
	_rebuild_body()


func _load_atlas() -> void:
	# Show local culture immediately, then refresh from API when available.
	_atlas = _local_atlas()
	_atlas_error = ""
	_rebuild_body()
	_api.get_json("atlas")


func _load_board() -> void:
	_board = null
	_board_error = ""
	_rebuild_body()
	_api.get_json("leaderboard")


func _load_rules() -> void:
	_rules = _local_rules()
	_rules_error = ""
	_rebuild_body()
	_api.get_json("rules")


func _local_match_params() -> Dictionary:
	var name := "تو"
	if typeof(_cfg.get("me", null)) == TYPE_DICTIONARY:
		name = str((_cfg.me as Dictionary).get("name", "تو"))
	return {
		"level": _play_level,
		"ai_count": _play_ai,
		"player_name": name,
		"wagons": 45,
	}


func _start_match() -> void:
	_launching = true
	_play_error = ""
	_outcome = {}
	_result_server = {}
	_rebuild_body()
	_api.post_json("matches", _local_match_params())


func _autostart_match(q: Dictionary) -> void:
	_play_level = int(q.get("level", 2))
	_play_ai = int(q.get("ai_count", 1))
	var params := q.duplicate()
	params["level"] = _play_level
	params["ai_count"] = _play_ai
	_begin_arena(params)


func _begin_arena(params: Dictionary) -> void:
	_end_arena(false)
	_tab = "play"
	_chrome.visible = false
	# Let the Node3D arena receive picks — shell Control must not eat input.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root:
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_play_overlay.visible = false
	_result_layer.visible = false
	_arena = ArenaScene.instantiate()
	_arena.name = "Arena"
	add_child(_arena)
	if _arena.has_signal("arena_event"):
		_arena.arena_event.connect(_on_arena_event)
	# Shell drives start; arena is not the current_scene so it won't auto-start.
	if _arena.has_method("arena_start"):
		_arena.call_deferred("arena_start", params)
	_emit({"type": "shell_playing", "game": "persian-rails"})


func _end_arena(to_lobby: bool) -> void:
	if _arena:
		if _arena.has_method("arena_stop"):
			_arena.arena_stop()
		_arena.queue_free()
		_arena = null
	_play_overlay.visible = false
	_result_layer.visible = false
	_chrome.visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _root:
		_root.mouse_filter = Control.MOUSE_FILTER_STOP
	if to_lobby:
		_tab = "play"
		_match = {}
		_outcome = {}
		_result_server = {}
		_rebuild_nav()
		_rebuild_body()


func _on_arena_event(json: String) -> void:
	arena_event.emit(json)
	var d = JSON.parse_string(json)
	if typeof(d) != TYPE_DICTIONARY:
		return
	if d.has("arena") and typeof(d.arena) == TYPE_DICTIONARY:
		d = d.arena
	var kind := str(d.get("type", ""))
	if kind == "leave":
		_end_arena(true)
		return
	if kind != "result":
		return
	if _submitting or not _outcome.is_empty():
		return
	_outcome = d
	var token := str(_match.get("token", ""))
	if token == "" and _arena and _arena.get("params") != null:
		token = str((_arena.params as Dictionary).get("token", ""))
	if token != "":
		_submitting = true
		var body := {}
		for k in d.keys():
			if typeof(d[k]) != TYPE_DICTIONARY and typeof(d[k]) != TYPE_ARRAY and str(k) != "id":
				body[k] = d[k]
		_api.post_json("matches/%s/result" % token, body)
	else:
		_show_result_overlay()


func _show_result_overlay() -> void:
	for c in _result_layer.get_children():
		c.queue_free()
	_result_layer.visible = true
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.01, 0.58)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_result_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_result_layer.add_child(center)
	var card := Ui.framed("card", 18.0 * minf(float(_d.get("scale", 1.0)), 2.0), float(_d.get("scale", 1.0)))
	card.custom_minimum_size = Vector2(minf(get_viewport().get_visible_rect().size.x - 24.0, 400.0), 0)
	center.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	card.add_child(col)
	var outcome := str(_outcome.get("outcome", "draw"))
	var head := "آفرین، بردی!" if outcome == "win" else ("مساوی شد!" if outcome == "draw" else "این‌بار نشد؛ دوباره بزن!")
	var title := Ui.body_label(head, int(_d.get("font_title", 18)) + 2, ThemeX.TEAL_DEEP if outcome == "win" else ThemeX.CLAY, true)
	Fonts.apply(title, int(_d.get("font_title", 18)) + 2, true)
	col.add_child(title)
	if not _result_server.is_empty():
		col.add_child(Ui.body_label(
			"رتبه: %s → %s · تجربه: %s" % [
				str(_result_server.get("rating_before", "?")),
				str(_result_server.get("rating_after", "?")),
				str(_result_server.get("xp", "?")),
			],
			int(_d.get("font_body", 15)), ThemeX.INK, true
		))
	else:
		col.add_child(Ui.body_label(
			"تو %d  —  حریف %d" % [int(_outcome.get("score", 0)), int(_outcome.get("ai_score", 0))],
			int(_d.get("font_body", 15)), ThemeX.INK, true
		))
	var again := Ui.make_btn("یه دست دیگه", "primary", float(_d.scale), float(_d.btn_h), int(_d.font_btn))
	again.pressed.connect(func():
		_result_layer.visible = false
		_outcome = {}
		_result_server = {}
		_start_match()
	)
	col.add_child(again)
	var done := Ui.make_btn("تمام", "secondary", float(_d.scale), float(_d.btn_h), int(_d.font_btn))
	done.pressed.connect(func():
		_end_arena(true)
		_tab = "home"
		_rebuild_nav()
		_rebuild_body()
	)
	col.add_child(done)


func _emit(obj: Dictionary) -> void:
	var json := JSON.stringify(obj)
	arena_event.emit(json)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.parent && window.parent.postMessage({arena: %s}, '*')" % json, true)


func _clear(node: Node) -> void:
	for c in node.get_children():
		c.queue_free()


func _rebuild_nav() -> void:
	_clear(_nav_row)
	var s: float = float(_d.get("scale", 1.0))
	var nav_font := _sf("shell_nav", "font_chip")
	var nav_h: float = float(_d.get("shell_nav_h", 72.0))
	var sel := _tab
	for tab in TABS:
		var id: String = tab.id
		var cell := Button.new()
		cell.text = "%s\n%s" % [_nav_glyph(id), tab.label]
		cell.focus_mode = Control.FOCUS_NONE
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.flat = true
		cell.alignment = HORIZONTAL_ALIGNMENT_CENTER
		var on := id == sel
		Fonts.apply(cell, nav_font + (1 if on else 0), on)
		cell.add_theme_color_override("font_color", ThemeX.GOLD_SOFT if on else ThemeX.CREAM)
		cell.add_theme_color_override("font_hover_color", ThemeX.GOLD_SOFT)
		cell.add_theme_color_override("font_pressed_color", ThemeX.GOLD)
		cell.add_theme_color_override("font_outline_color", ThemeX.WOOD_DARK)
		cell.add_theme_constant_override("outline_size", 3)
		cell.custom_minimum_size = Vector2(0, nav_h - 16.0)
		var empty := StyleBoxEmpty.new()
		cell.add_theme_stylebox_override("normal", empty)
		cell.add_theme_stylebox_override("hover", empty)
		cell.add_theme_stylebox_override("pressed", empty)
		cell.add_theme_stylebox_override("focus", empty)
		cell.pressed.connect(_set_tab.bind(id))
		_nav_row.add_child(cell)


func _nav_glyph(id: String) -> String:
	match id:
		"home":
			return "⌂"
		"play":
			return "▣"
		"atlas":
			return "◎"
		"ranks":
			return "★"
		"rules":
			return "☰"
		_:
			return "·"


func _page_pad() -> float:
	var dpr := float(_d.get("dpr", 1.0))
	return (12.0 if bool(_d.get("compact", true)) else 16.0) * maxf(dpr * float(_d.get("scale", 1.0)), 1.0)


func _mk_btn(text: String, kind: String) -> Button:
	return Ui.make_btn(text, kind, float(_d.get("scale", 1.0)), _btn_h(), _sf("shell_btn", "font_btn"))


func _rebuild_body() -> void:
	_clear(_body)
	var margin := MarginContainer.new()
	var p := _page_pad()
	margin.add_theme_constant_override("margin_left", int(p))
	margin.add_theme_constant_override("margin_right", int(p))
	margin.add_theme_constant_override("margin_top", int(p))
	margin.add_theme_constant_override("margin_bottom", int(p + 20))
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(col)

	if not _booted:
		if _boot_error != "":
			_fill_problem(col, _boot_error, _boot)
		else:
			_fill_loading(col, "سلام! داریم ایستگاه رو باز می‌کنیم…")
		return

	match _tab:
		"play":
			_fill_play(col)
		"atlas":
			_fill_atlas(col)
		"ranks":
			_fill_ranks(col)
		"rules":
			_fill_rules(col)
		_:
			_fill_home(col)


func _fill_loading(col: VBoxContainer, msg: String) -> void:
	var panel := Ui.framed("fantasy", float(_d.pad), float(_d.scale))
	col.add_child(panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 14)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(inner)
	var spin := ProgressBar.new()
	spin.show_percentage = false
	spin.indeterminate = true
	spin.custom_minimum_size = Vector2(0, 12)
	inner.add_child(spin)
	inner.add_child(Ui.body_label(msg, _sf("shell_body"), Color("5a4336"), true))


func _fill_problem(col: VBoxContainer, text: String, retry: Callable) -> void:
	var card := Ui.framed("card", float(_d.pad), float(_d.scale))
	col.add_child(card)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)
	card.add_child(inner)
	inner.add_child(Ui.callout("ای وای!", text, ThemeX.CLAY, _sf("shell_title"), _sf("shell_body")))
	var b := _mk_btn("دوباره امتحان کنیم", "accent")
	b.pressed.connect(retry)
	inner.add_child(b)


func _top_title(col: VBoxContainer, title: String, subtitle: String = "") -> void:
	var top := Ui.framed("top", float(_d.pad), float(_d.scale))
	col.add_child(top)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	top.add_child(inner)
	inner.add_child(Ui.cream_label(title, _sf("shell_title") + 2))
	if subtitle != "":
		inner.add_child(Ui.gold_label(subtitle, _sf("shell_body")))


func _fill_home(col: VBoxContainer) -> void:
	_top_title(col, _t("product", "امپراتوری راه‌آهن پارس"), _t("tagline", "شهرهای ایران را با لبخند به هم وصل کن"))
	var panel := Ui.framed("fantasy", float(_d.pad), float(_d.scale))
	col.add_child(panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)
	panel.add_child(inner)
	var welcome := Ui.body_label(_t("welcome", "سلام! آماده‌ای شبکه ریلی خودت رو بسازی؟"), _sf("shell_title"), ThemeX.INK, true)
	Fonts.apply(welcome, _sf("shell_title"), true)
	inner.add_child(welcome)
	var me = _cfg.get("me", null)
	if typeof(me) == TYPE_DICTIONARY:
		var prog = me.get("progress", {})
		var lvl := 1
		if typeof(prog) == TYPE_DICTIONARY:
			lvl = int(prog.get("level", 1))
		var chip_row := HBoxContainer.new()
		chip_row.alignment = BoxContainer.ALIGNMENT_CENTER
		chip_row.add_child(Ui.chip("%s · رتبه %s · سطح %d" % [str(me.get("name", "")), str(me.get("rating", "")), lvl], "gold", _sf("shell_body")))
		inner.add_child(chip_row)
	var game = _cfg.get("game", {})
	if typeof(game) == TYPE_DICTIONARY and str(game.get("tagline", "")) != "":
		inner.add_child(Ui.body_label(str(game.tagline), _sf("shell_body"), Color("5a4336"), true))
	inner.add_child(Control.new())
	var go_play := _mk_btn(_t("practice", "تمرین با حریف هوشمند"), "primary")
	if Assets.tex("train_icon.png"):
		go_play.icon = Assets.tex("train_icon.png")
		go_play.expand_icon = true
	go_play.pressed.connect(func(): _set_tab("play"))
	inner.add_child(go_play)
	var go_rules := _mk_btn(_t("rules", "قوانین خودمونی"), "secondary")
	go_rules.pressed.connect(func(): _set_tab("rules"))
	inner.add_child(go_rules)
	inner.add_child(Ui.callout(
		"نکته دوستانه",
		_t("scenario_note", "بعضی مسیرها سناریویی‌ان و با برچسب مشخص شدن."),
		ThemeX.CLAY, _sf("shell_body"), _sf("shell_body")
	))


func _fill_play(col: VBoxContainer) -> void:
	_top_title(col, _t("practice", "تمرین با حریف هوشمند"))
	var panel := Ui.framed("fantasy", float(_d.pad), float(_d.scale))
	col.add_child(panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 14)
	panel.add_child(inner)
	inner.add_child(Ui.body_label(
		"سطح حریف رو انتخاب کن و بزن بریم. نقشه ایران منتظرته!",
		_sf("shell_body"), Color("5a4336"), true
	))
	inner.add_child(_stepper("سطح", _play_level, func():
		_play_level = maxi(1, _play_level - 1)
		_rebuild_body()
	, func():
		_play_level = mini(3, _play_level + 1)
		_rebuild_body()
	))
	inner.add_child(_stepper("تعداد حریف", _play_ai, func():
		_play_ai = maxi(1, _play_ai - 1)
		_rebuild_body()
	, func():
		_play_ai = mini(3, _play_ai + 1)
		_rebuild_body()
	))
	var start := _mk_btn(_t("play", "بزن بریم"), "accent")
	start.custom_minimum_size.y = maxf(_btn_h(), 56.0)
	if Assets.tex("train_icon.png"):
		start.icon = Assets.tex("train_icon.png")
		start.expand_icon = true
	start.disabled = _launching
	start.pressed.connect(_start_match)
	inner.add_child(start)
	if _launching:
		var wait := Ui.framed("fantasy", float(_d.pad) * 0.8, float(_d.scale))
		col.add_child(wait)
		var wcol := VBoxContainer.new()
		wcol.add_theme_constant_override("separation", 10)
		wcol.alignment = BoxContainer.ALIGNMENT_CENTER
		wait.add_child(wcol)
		var spin := ProgressBar.new()
		spin.indeterminate = true
		spin.show_percentage = false
		spin.custom_minimum_size = Vector2(0, 12)
		wcol.add_child(spin)
		wcol.add_child(Ui.body_label("داریم قطار رو راه می‌ندازیم…", _sf("shell_body"), Color("5a4336"), true))
	if _play_error != "":
		col.add_child(Ui.callout("شروع نشد", _play_error, ThemeX.CLAY, _sf("shell_body"), _sf("shell_body")))


func _stepper(label: String, value: int, on_down: Callable, on_up: Callable) -> PanelContainer:
	var wrap := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.14, 0.09, 0.06, 0.10)
	st.border_color = Color(0.42, 0.26, 0.17, 0.35)
	st.set_border_width_all(1)
	st.set_corner_radius_all(20)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	wrap.add_theme_stylebox_override("panel", st)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	wrap.add_child(row)
	var lab := Ui.body_label(label, _sf("shell_title"), ThemeX.INK, false)
	Fonts.apply(lab, _sf("shell_title"), true)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lab)
	var step_h := 48.0
	var down := Ui.make_btn("−", "secondary", float(_d.scale), step_h, _sf("shell_btn"))
	down.custom_minimum_size = Vector2(52, step_h)
	down.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	down.pressed.connect(on_down)
	row.add_child(down)
	var val_box := PanelContainer.new()
	var vst := StyleBoxFlat.new()
	vst.bg_color = Color(1, 0.97, 0.93, 0.65)
	vst.border_color = ThemeX.WOOD
	vst.set_border_width_all(1)
	vst.set_corner_radius_all(16)
	vst.content_margin_left = 10
	vst.content_margin_right = 10
	val_box.add_theme_stylebox_override("panel", vst)
	val_box.custom_minimum_size = Vector2(48, step_h)
	var val := Ui.body_label(str(value), _sf("shell_title"), ThemeX.INK, true)
	Fonts.apply(val, _sf("shell_title"), true)
	val_box.add_child(val)
	row.add_child(val_box)
	var up := Ui.make_btn("+", "secondary", float(_d.scale), step_h, _sf("shell_btn"))
	up.custom_minimum_size = Vector2(52, step_h)
	up.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	up.pressed.connect(on_up)
	row.add_child(up)
	return wrap


func _fill_atlas(col: VBoxContainer) -> void:
	if _atlas_error != "":
		_fill_problem(col, _atlas_error, _load_atlas)
		return
	if _atlas == null:
		_fill_loading(col, "داریم قصه‌های ایران رو می‌آریم…")
		return
	_top_title(col, "اطلس فرهنگی", "قصه‌های کوتاه از میراث و جغرافیا")
	var cards = _atlas.get("culture", [])
	if typeof(cards) != TYPE_ARRAY:
		cards = []
	if cards.is_empty():
		var local = _load_json("res://arena/persian_rails/data/culture.json")
		if typeof(local) == TYPE_ARRAY:
			cards = local
	for c in cards:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var card := Ui.framed("card", float(_d.pad), float(_d.scale))
		col.add_child(card)
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 10)
		card.add_child(inner)
		var title := Ui.body_label(str(c.get("title", "")), _sf("shell_title"), ThemeX.TEAL_DEEP, false)
		Fonts.apply(title, _sf("shell_title"), true)
		inner.add_child(title)
		inner.add_child(Ui.body_label(str(c.get("body", "")), _sf("shell_body"), ThemeX.INK, false))
		var row := HBoxContainer.new()
		row.add_child(Ui.chip(str(c.get("topic", "")), "gold", _sf("shell_body")))
		inner.add_child(row)


func _fill_ranks(col: VBoxContainer) -> void:
	if _board_error != "":
		_fill_problem(col, _board_error, _load_board)
		return
	if _board == null:
		_fill_loading(col, "داریم جدول افتخار رو می‌چینیم…")
		return
	_top_title(col, "جدول افتخار", "رقابت دوستانه با حریف هوشمند")
	var rows = _board.get("board", [])
	if typeof(rows) != TYPE_ARRAY:
		rows = []
	if rows.is_empty():
		var panel := Ui.framed("fantasy", float(_d.pad), float(_d.scale))
		col.add_child(panel)
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 12)
		panel.add_child(inner)
		inner.add_child(Ui.body_label("هنوز کسی بازی نکرده؛ تو اولیش باش!", _sf("shell_title"), ThemeX.INK, true))
		if bool(_board.get("offline", false)):
			inner.add_child(Ui.body_label(str(_board.get("error", "")), _sf("shell_body"), Color("5a4336"), true))
			var retry := _mk_btn("دوباره از سرور بگیر", "secondary")
			retry.pressed.connect(_load_board)
			inner.add_child(retry)
		return
	var i := 0
	for u in rows:
		if typeof(u) != TYPE_DICTIONARY:
			continue
		var card := Ui.framed("card", float(_d.pad) * 0.85, float(_d.scale))
		col.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		card.add_child(row)
		var badge := PanelContainer.new()
		var bst := StyleBoxFlat.new()
		bst.bg_color = ThemeX.GOLD_SOFT if i < 3 else ThemeX.MIST
		bst.set_corner_radius_all(28)
		bst.border_color = ThemeX.WOOD_DARK
		bst.set_border_width_all(2)
		bst.content_margin_left = 10
		bst.content_margin_right = 10
		bst.content_margin_top = 8
		bst.content_margin_bottom = 8
		badge.add_theme_stylebox_override("panel", bst)
		badge.custom_minimum_size = Vector2(42, 42)
		var bn := Ui.body_label(str(i + 1), _sf("shell_body"), ThemeX.WOOD_DARK, true)
		Fonts.apply(bn, _sf("shell_body"), true)
		badge.add_child(bn)
		row.add_child(badge)
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 4)
		var name := Ui.body_label(str(u.get("name", u.get("handle", "?"))), _sf("shell_body"), ThemeX.INK, false)
		Fonts.apply(name, _sf("shell_body"), true)
		info.add_child(name)
		info.add_child(Ui.body_label("%s برد · %s مساوی" % [str(u.get("wins", 0)), str(u.get("draws", 0))], _sf("shell_body") - 1, Color("5a4336"), false))
		row.add_child(info)
		var tone := "gold" if i == 0 else ("teal" if i < 3 else "gold")
		row.add_child(Ui.chip(str(u.get("rating", "")), tone, _sf("shell_body")))
		i += 1


func _fill_rules(col: VBoxContainer) -> void:
	if _rules_error != "":
		_fill_problem(col, _rules_error, _load_rules)
		return
	if _rules == null:
		_fill_loading(col, "داریم قوانین رو می‌آریم…")
		return
	_top_title(col, str(_rules.get("title", "قوانین")))
	var panel := Ui.framed("fantasy", float(_d.pad), float(_d.scale))
	col.add_child(panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 10)
	panel.add_child(inner)
	var turns = _rules.get("turns", [])
	if typeof(turns) == TYPE_ARRAY:
		for line in turns:
			inner.add_child(Ui.body_label("• " + str(line), _sf("shell_body") + 1, ThemeX.INK, false))
	if str(_rules.get("end", "")) != "":
		inner.add_child(Ui.body_label(str(_rules.end), _sf("shell_body"), Color("5a4336"), false))
	if str(_rules.get("note", "")) != "":
		inner.add_child(Ui.callout("درباره نقشه", str(_rules.note), ThemeX.TEAL, _sf("shell_body"), _sf("shell_body")))
	var back := _mk_btn("برگرد خونه", "secondary")
	back.pressed.connect(func(): _set_tab("home"))
	col.add_child(back)
