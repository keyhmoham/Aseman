## Persian Rails Empire — production 2.5D board game vs AI.
extends Node3D

signal arena_event(json: String)

const Rules = preload("res://arena/persian_rails/rules.gd")
const AIScript = preload("res://arena/persian_rails/ai.gd")
const MapView = preload("res://arena/persian_rails/map_view.gd")
const Hud = preload("res://arena/persian_rails/hud.gd")
const Tutorial = preload("res://arena/persian_rails/tutorial.gd")
const Models = preload("res://arena/persian_rails/models.gd")
const Fonts = preload("res://arena/persian_rails/fonts.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")

var rules = Rules.new()
var ai = AIScript.new(2)
var models = Models.new()
var params := {
	"level": 2, "ai_count": 1, "wagons": 45,
	"player_name": "تو", "opponent_name": "حریف هوشمند",
}
var started := false
var over := false
var claim_mode := false
var _map: Node3D
var _hud
var _tutorial
var _camera: Camera3D
var _cam_yaw := 0.1
var _cam_pitch := deg_to_rad(66.0)
var _cam_dist := 18.0
var _target := Vector3(0.0, 0.0, -0.6)
var _drag := false
var _drag_mode := "pan"
var _headless := false
var _standalone := false
var _ai_busy := false
var _touches := {}
var _pinch_dist := 0.0
var _env: WorldEnvironment


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_install_persian_font()
	_fit_camera_defaults()
	rules.load_data()
	_build_world()
	_hud = Hud.new()
	_hud.name = "HUD"
	add_child(_hud)
	_hud.action.connect(_on_hud)
	_tutorial = Tutorial.new()
	_tutorial.name = "Tutorial"
	add_child(_tutorial)
	_tutorial.bind_hud(_hud)
	_tutorial.finished.connect(_on_tutorial_finished)
	_tutorial.practice_claim.connect(_on_tutorial_practice_claim)
	get_viewport().size_changed.connect(_place_camera)
	_standalone = get_tree().current_scene == self
	if _standalone:
		call_deferred("arena_start", _params_from_page())
	_emit({"type": "ready", "game": "persian-rails"})


func _install_persian_font() -> void:
	var font := Fonts.regular()
	if font == null:
		return
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 18
	theme.set_font("font", "Label", font)
	theme.set_font("font", "Button", Fonts.bold() if Fonts.bold() else font)
	get_tree().root.theme = theme


func _fit_camera_defaults() -> void:
	var vp := get_viewport().get_visible_rect().size
	if vp.x <= 0.0:
		return
	# Slightly closer + flatter so Iran fills the free band between HUD chrome.
	if vp.x < 720.0:
		_cam_dist = 14.2
		_cam_pitch = deg_to_rad(62.0)
		_cam_yaw = 0.04
	else:
		_cam_dist = 14.6
		_cam_pitch = deg_to_rad(58.0)


func arena_start(p: Dictionary = {}) -> void:
	for k in p:
		params[k] = p[k]
	ai = AIScript.new(int(params.get("level", 2)))
	rules.load_data()
	rules.start(
		str(params.get("player_name", "تو")),
		int(params.get("ai_count", 1)),
		int(params.get("wagons", 45)),
		int(params.get("seed", 0))
	)
	started = true
	over = false
	claim_mode = false
	_target = Vector3(0.0, 0.0, -0.6)
	if _map:
		_map.setup(rules, models)
		if _map.has_method("set_claim_glow"):
			_map.set_claim_glow(false)
	if _hud:
		_hud.hide_modal()
		_hud.set_strings(rules.fa)
		_hud.set_claim_mode(false)
		_refresh_ui()
	if _tutorial:
		_tutorial.set_strings(rules.fa)
		_tutorial.bind_hud(_hud)
	_place_camera()
	_emit({"type": "started", "game": "persian-rails", "level": int(params.get("level", 2))})
	var show_tut := _should_show_tutorial()
	# One-shot flags so a later restart does not keep forcing/skipping the coach.
	params.erase("force_tutorial")
	params.erase("skip_tutorial")
	if show_tut:
		_tutorial.begin()
		_refresh_ui()
	else:
		if _hud and _hud.has_method("flash_turn"):
			_hud.flash_turn(str(rules.fa.get("your_turn", "نوبت توئه")))
		_maybe_ai()


func arena_stop() -> void:
	started = false
	over = true


func arena_state() -> Dictionary:
	return rules.snapshot() if started else {}


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
	if out.has("level"):
		out.level = int(out.level)
	if out.has("ai_count"):
		out.ai_count = int(out.ai_count)
	if out.has("wagons"):
		out.wagons = int(out.wagons)
	return out


func _build_world() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 38, 0)
	sun.light_energy = 1.35
	sun.light_color = Color("fff1dc")
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -150, 0)
	fill.light_energy = 0.4
	fill.light_color = Color("b7d7ef")
	add_child(fill)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-10, 120, 0)
	rim.light_energy = 0.22
	rim.light_color = Color("ffe0b0")
	add_child(rim)

	_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = ThemeX.SKY_TOP
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("ffe6cc")
	env.ambient_light_energy = 0.68
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1
	env.adjustment_contrast = 1.05
	_env.environment = env
	add_child(_env)

	# Gradient sky cards (cheap, readable backdrop)
	_sky_card(Vector3(0, 8, -18), Vector2(48, 22), ThemeX.SKY_TOP)
	_sky_card(Vector3(0, -1.2, -18), Vector2(48, 10), ThemeX.SKY_BOT)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 40.0
	_camera.near = 0.05
	_camera.far = 140.0
	add_child(_camera)
	_place_camera()

	_map = MapView.new()
	_map.name = "Map"
	add_child(_map)
	_map.city_tapped.connect(_on_city)
	_map.route_tapped.connect(_on_route)


func _sky_card(pos: Vector3, size: Vector2, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	var m := ThemeX.mat(color, 1.0)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	mi.position = pos
	add_child(mi)


func _place_camera() -> void:
	if _camera == null:
		return
	var look := _target
	var vp := get_viewport().get_visible_rect().size
	if vp.y > 0.0 and _hud and _hud.has_method("chrome_insets"):
		var insets: Vector2 = _hud.chrome_insets()
		var top_frac := insets.x / vp.y
		var bot_frac := insets.y / vp.y
		var mid := (top_frac + (1.0 - bot_frac)) * 0.5
		var bias := (0.5 - mid) * _cam_dist * 0.6
		look += Vector3(0, 0, bias)
	var offset := Vector3(
		sin(_cam_yaw) * cos(_cam_pitch),
		sin(_cam_pitch),
		cos(_cam_yaw) * cos(_cam_pitch)
	) * _cam_dist
	_camera.position = look + offset
	_camera.look_at(look, Vector3.UP)
	_camera.fov = 38.0 if vp.x < 720.0 else 40.0
	if _map and _map.has_method("set_label_lod"):
		_map.set_label_lod(_cam_dist)


func _should_show_tutorial() -> bool:
	## Coach runs every time the player enters a match (unless a test opts out).
	if _tutorial == null:
		return false
	if bool(params.get("skip_tutorial", false)):
		return false
	return true


func _on_tutorial_finished(_skipped: bool) -> void:
	claim_mode = false
	if _hud:
		_hud.set_claim_mode(false)
		if _hud.has_method("pulse_action"):
			_hud.pulse_action("", false)
		if _hud.has_method("flash_turn"):
			_hud.flash_turn(str(rules.fa.get("your_turn", "نوبت توئه")))
	if _map and _map.has_method("set_claim_glow"):
		_map.set_claim_glow(false)
	_refresh_ui()
	_maybe_ai()


func _on_tutorial_practice_claim(on: bool) -> void:
	claim_mode = on
	if _hud:
		_hud.set_claim_mode(on)
	if _map and _map.has_method("set_claim_glow"):
		_map.set_claim_glow(on)
	if on and _hud:
		_hud.toast(str(rules.fa.get("tut_route_hint", rules.fa.get("claim_hint", "یک مسیر آزاد لمس کن"))))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_drag = mb.pressed
			_drag_mode = "pan"
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag = mb.pressed
			_drag_mode = "orbit"
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist = maxf(9.5, _cam_dist - 0.65)
			_place_camera()
			if _tutorial and _tutorial.is_blocking():
				_tutorial.notify_zoom()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist = minf(24.0, _cam_dist + 0.65)
			_place_camera()
			if _tutorial and _tutorial.is_blocking():
				_tutorial.notify_zoom()
	elif event is InputEventMouseMotion and _drag:
		var mm := event as InputEventMouseMotion
		if _drag_mode == "orbit":
			_cam_yaw -= mm.relative.x * 0.0045
			_cam_pitch = clampf(_cam_pitch - mm.relative.y * 0.0035, deg_to_rad(48.0), deg_to_rad(78.0))
			if _tutorial and _tutorial.is_blocking():
				_tutorial.notify_pan(mm.relative.length())
		else:
			_pan_by(mm.relative)
		_place_camera()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
			if _touches.size() == 1:
				_drag = true
				_drag_mode = "pan"
			elif _touches.size() == 2:
				_drag = false
				var pts: Array = _touches.values()
				_pinch_dist = pts[0].distance_to(pts[1])
		else:
			_touches.erase(st.index)
			_drag = _touches.size() == 1
			_drag_mode = "pan"
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_touches[sd.index] = sd.position
		if _touches.size() == 2:
			var pts2: Array = _touches.values()
			var d: float = pts2[0].distance_to(pts2[1])
			if _pinch_dist > 0.0:
				_cam_dist = clampf(_cam_dist * (_pinch_dist / maxf(d, 1.0)), 9.5, 24.0)
				_place_camera()
				if _tutorial and _tutorial.is_blocking():
					_tutorial.notify_zoom()
			_pinch_dist = d
		elif _drag:
			_pan_by(sd.relative)
			_place_camera()


func _pan_by(rel: Vector2) -> void:
	var sens := _cam_dist * 0.0017
	var right := Vector3(cos(_cam_yaw), 0, -sin(_cam_yaw))
	var forward := Vector3(sin(_cam_yaw), 0, cos(_cam_yaw))
	_target -= right * rel.x * sens
	_target += forward * rel.y * sens
	_target.x = clampf(_target.x, -6.0, 6.0)
	_target.z = clampf(_target.z, -6.5, 6.5)
	if _tutorial and _tutorial.is_blocking():
		_tutorial.notify_pan(rel.length())


func _on_hud(kind: String, _data: Dictionary) -> void:
	if _tutorial and _tutorial.is_blocking():
		if _tutorial.notify_action(kind):
			return
		# Block unrelated actions while the coach is teaching a specific tap.
		if kind != "restart":
			return
	if not started or over:
		if kind == "restart":
			arena_start(params)
		return
	if rules.players[rules.current].is_ai:
		return
	match kind:
		"leave":
			# Host shell handles returning to the lobby.
			_emit({"type": "leave", "game": "persian-rails"})
		"draw_trains":
			_do_action({"type": "draw_trains"})
		"draw_tickets":
			_do_action({"type": "draw_tickets"})
		"claim_mode":
			claim_mode = true
			_hud.set_claim_mode(true)
			if _map.has_method("set_claim_glow"):
				_map.set_claim_glow(true)
			_hud.toast(str(rules.fa.get("claim_hint", "یک مسیر آزاد روی نقشه لمس کن")))
		"restart":
			arena_start(params)


func _on_city(city_id: String) -> void:
	if _tutorial and _tutorial.is_blocking() and _tutorial.current_kind() == "tap_route":
		return
	var c = rules.city_by_id(city_id)
	if c.is_empty():
		return
	_hud.toast("%s — %s" % [str(c.name_fa), str(c.name_en)])
	_map.highlight_city(city_id, true)


func _on_route(route_id: String) -> void:
	if _tutorial and _tutorial.is_blocking():
		if _tutorial.notify_route(route_id):
			if _map.has_method("highlight_route"):
				_map.highlight_route(route_id, true)
			_hud.toast(str(rules.fa.get("tut_route_done", "آفرین! تو مسیر رو انتخاب کردی")))
			return
		return
	if not started or over or rules.players[rules.current].is_ai:
		return
	if not claim_mode:
		var r = rules.route_by_id(route_id)
		if _map.has_method("highlight_route"):
			_map.highlight_route(route_id, true)
		_hud.toast("مسیر %s → %s · %d واگن" % [
			rules.city_by_id(str(r.from)).get("name_fa", "?"),
			rules.city_by_id(str(r.to)).get("name_fa", "?"),
			rules.cost_for_route(r)])
		return
	claim_mode = false
	if _hud:
		_hud.set_claim_mode(false)
	if _map.has_method("set_claim_glow"):
		_map.set_claim_glow(false)
	_do_action({"type": "claim", "route": route_id})


func _do_action(action: Dictionary) -> void:
	var ev := rules.apply(action)
	if not ev.get("ok", false):
		var err := str(ev.get("error", ""))
		match err:
			"need_cards":
				_hud.toast(str(rules.fa.get("need_cards", "کارت کافی نداری")))
			"route_unavailable":
				_hud.toast(str(rules.fa.get("route_taken", "این مسیر گرفته شده")))
			_:
				_hud.toast("نشد انجام بشه")
		return
	_emit({"type": "move", "action": action.get("type"), "player": 0})
	_after_move()


func _after_move() -> void:
	_map.refresh_claims()
	_refresh_ui()
	if rules.over:
		_finish()
	else:
		_maybe_ai()


func _maybe_ai() -> void:
	if not started or rules.over or _ai_busy:
		return
	if _tutorial and _tutorial.is_blocking():
		return
	if not rules.players[rules.current].is_ai:
		_refresh_ui()
		return
	_ai_busy = true
	_refresh_ui()
	if _headless:
		_run_ai_burst()
	else:
		get_tree().create_timer(0.55).timeout.connect(_run_ai_burst)


func _run_ai_burst() -> void:
	var guard := 0
	while started and not rules.over and rules.players[rules.current].is_ai and guard < 8:
		var act := ai.choose(rules)
		var ev := rules.apply(act)
		if not ev.get("ok", false):
			rules.apply({"type": "draw_trains"})
		_emit({"type": "move", "action": act.get("type"), "player": rules.current, "ai": true})
		guard += 1
		if not rules.players[rules.current].is_ai:
			break
	_ai_busy = false
	_map.refresh_claims()
	_refresh_ui()
	if rules.over:
		_finish()
	elif rules.players[rules.current].is_ai:
		_maybe_ai()


func _finish() -> void:
	over = true
	var res := rules.final_result()
	res["level"] = int(params.get("level", 2))
	# Shell-hosted matches show the Godot shell result card (with rating).
	# Standalone / legacy embeds keep the in-HUD modal.
	if _standalone and _hud:
		_hud.show_result(res)
	_emit(res)


func _refresh_ui() -> void:
	if _hud == null:
		return
	var human_turn: bool = started and (not rules.over) and (not bool(rules.players[rules.current].get("is_ai", false)))
	_hud.show_state(rules, human_turn)


func _emit(obj: Dictionary) -> void:
	var json := JSON.stringify(obj)
	arena_event.emit(json)
	if _standalone and OS.has_feature("web"):
		JavaScriptBridge.eval("window.parent && window.parent.postMessage({arena: %s}, '*')" % json, true)
