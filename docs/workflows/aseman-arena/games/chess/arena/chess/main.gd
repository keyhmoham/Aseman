## Arena Chess — the 3D game.
##
## A marble board and Staunton pieces (Poly Haven's "Chess Set", CC0, when the
## build fetched it; turned pieces made here otherwise), an orbiting camera,
## tap/click to move with the legal squares shown, animated moves and
## captures, promotion choice, the move list in SAN, clocks, take-back, draw
## claims and offers, resignation — against the AI opponent (chess_ai.gd) on
## a worker thread.
##
## It runs three ways:
##  * as the main scene (the Web export, or the editor);
##  * mounted inside another Godot world (the Aseman client's Scene3D loads
##    this project's resource pack and instances this scene): the host calls
##    arena_start(params) and listens to arena_event(json);
##  * headless, in tests (the same API without rendering).
##
## arena_event carries JSON: {"type": "ready" | "started" | "move" | "result", …}.
## The result: {"type":"result","game":"chess","outcome":"win|loss|draw",
## "result":"1-0","reason":"checkmate","moves":N,"pgn":"…","duration_s":N,
## "level":L,"player_color":"white"}.
extends Node3D

signal arena_event(json: String)

const Rules = preload("res://arena/chess/chess_rules.gd")
const AI = preload("res://arena/chess/chess_ai.gd")
const Pieces = preload("res://arena/chess/pieces.gd")
const UI = preload("res://arena/chess/hud.gd")

const MODEL_PATH := "res://arena/chess/models/chess_set/chess_set.gltf"
const SCALE := 10.0
const SQUARE := 0.058 * SCALE          # one square, in metres
const ORIGIN := -0.203 * SCALE         # centre of a1 on x and z
const TOP := 0.0174 * SCALE            # the board's playing surface

var rules = Rules.new()
var ai = AI.new(3)
var params := {
	"player_color": "white", "level": 3, "player_name": "You",
	"time_control": "none", "opponent_name": "Aseman AI",
}
var player_side := Rules.WHITE_SIDE
var started := false
var over := false
var started_at := 0
var san_list: PackedStringArray = PackedStringArray()
var clocks := [0.0, 0.0]      # seconds left per side; 0 = untimed
var increment := 0.0
var takebacks := 0

var _pieces := {}             # square → Node3D
var _captured := [[], []]     # by side captured
var _templates := {}          # piece code → Node3D template
var _selected := -1
var _targets := PackedInt32Array()
var _markers: Array = []
var _last_markers: Array = []
var _board_root: Node3D
var _camera: Camera3D
var _cam_yaw := 0.0
var _cam_pitch := deg_to_rad(52.0)
var _cam_dist := 6.2
var _cam_target_yaw := 0.0
var _drag := false
var _touches := {}
var _pinch_dist := 0.0
var _touch_start := Vector2.ZERO
var _touch_moved := false
var _hud
var _thread: Thread
var _ai_busy := false
var _ai_result := {}
var _ai_mutex := Mutex.new()
var _animating := 0
var _headless := false
var _standalone := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_build_world()
	_hud = UI.new()
	_hud.name = "HUD"
	add_child(_hud)
	_hud.action.connect(_on_hud_action)
	# As the main scene, start from the page's query (?level=4&color=black)
	# or defaults; mounted in a host, wait for arena_start.
	_standalone = get_tree().current_scene == self
	if _standalone:
		call_deferred("arena_start", _params_from_page())
	_emit({"type": "ready", "game": "chess"})


func _exit_tree() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


# ---------------------------------------------------------------------------
# The host's API
# ---------------------------------------------------------------------------

## Start (or restart) a game. params: player_color white|black|random,
## level 1..5, player_name, opponent_name, time_control none|M+S (e.g. 10+5),
## fen (optional start position).
func arena_start(p: Dictionary = {}) -> void:
	for k in p:
		params[k] = p[k]
	var color := str(params.get("player_color", "white"))
	if color == "random":
		color = "white" if randi() % 2 == 0 else "black"
	params.player_color = color
	player_side = Rules.BLACK_SIDE if color == "black" else Rules.WHITE_SIDE
	ai = AI.new(int(params.get("level", 3)))
	rules = Rules.new(str(params.get("fen", Rules.START_FEN)))
	san_list = PackedStringArray()
	over = false
	takebacks = 0
	_selected = -1
	_targets = PackedInt32Array()
	_ai_result = {}
	var tc := str(params.get("time_control", "none"))
	clocks = [0.0, 0.0]
	increment = 0.0
	if tc.contains("+"):
		var parts := tc.split("+")
		clocks = [float(parts[0]) * 60.0, float(parts[0]) * 60.0]
		increment = float(parts[1])
	_place_all_pieces()
	_cam_target_yaw = 0.0 if player_side == Rules.WHITE_SIDE else PI
	_cam_yaw = _cam_target_yaw
	_update_camera()
	started = true
	started_at = Time.get_ticks_msec()
	_hud.setup(params, player_side)
	_refresh_hud()
	_emit({"type": "started", "game": "chess", "player_color": color, "level": ai.level})
	if rules.side != player_side:
		_start_ai()


## The host asks the game to end now (the person left the room).
func arena_stop() -> void:
	if started and not over:
		_finish("0-1" if player_side == Rules.WHITE_SIDE else "1-0", "abandoned")


## A snapshot of the game, for hosts and tests.
func arena_state() -> Dictionary:
	return {"fen": rules.fen(), "moves": Array(san_list), "over": over,
		"turn": "white" if rules.side == Rules.WHITE_SIDE else "black",
		"player_color": params.player_color, "thinking": _ai_busy}


## Play a move for the person, in SAN or UCI (tests and accessibility).
func arena_play(text: String) -> bool:
	if over or rules.side != player_side or _ai_busy:
		return false
	var m: int = rules.move_from_san(text)
	if m < 0:
		m = rules.move_from_uci(text)
	if m < 0:
		return false
	_commit(m)
	return true


# ---------------------------------------------------------------------------
# World
# ---------------------------------------------------------------------------

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.09, 0.11, 0.17)
	mat.sky_horizon_color = Color(0.24, 0.22, 0.26)
	mat.ground_bottom_color = Color(0.05, 0.05, 0.06)
	mat.ground_horizon_color = Color(0.2, 0.18, 0.2)
	sky.sky_material = mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.glow_intensity = 0.15
	env.environment = e
	add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58, -32, 0)
	key.light_energy = 1.25
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 18.0
	add_child(key)
	var rim := OmniLight3D.new()
	rim.position = Vector3(0, 4.5, 0)
	rim.omni_range = 9.0
	rim.light_energy = 0.35
	rim.light_color = Color(1.0, 0.92, 0.8)
	add_child(rim)

	# The table the board stands on.
	var table := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 4.6
	tm.bottom_radius = 4.6
	tm.height = 0.12
	tm.radial_segments = 64
	table.mesh = tm
	table.position.y = -0.06
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.22, 0.13, 0.08)
	wood.roughness = 0.45
	table.material_override = wood
	add_child(table)

	_board_root = Node3D.new()
	_board_root.name = "Board"
	add_child(_board_root)
	if ResourceLoader.exists(MODEL_PATH):
		_load_model_set()
	if _templates.is_empty():
		Pieces.build_board(_board_root, SQUARE, ORIGIN, TOP)
		_templates = Pieces.build_templates(SQUARE)

	_camera = Camera3D.new()
	_camera.fov = 45
	_camera.current = true
	add_child(_camera)
	_update_camera()


## Poly Haven's chess set: the board as it is, the 32 pieces as templates
## (one per kind and colour), so every game places its own copies.
func _load_model_set() -> void:
	var scene = load(MODEL_PATH)
	if scene == null:
		return
	var inst: Node3D = scene.instantiate()
	inst.scale = Vector3.ONE * SCALE
	_board_root.add_child(inst)
	var kinds := {"pawn": Rules.PAWN, "knight": Rules.KNIGHT, "bishop": Rules.BISHOP,
		"rook": Rules.ROOK, "queen": Rules.QUEEN, "king": Rules.KING}
	for n in inst.find_children("piece_*", "Node3D", true, false):
		var parts := n.name.split("_")
		if parts.size() < 3 or not kinds.has(parts[1]):
			continue
		var code: int = kinds[parts[1]] | (Rules.BLACK if parts[2] == "black" else 0)
		if not _templates.has(code):
			var holder := Node3D.new()
			var copy: Node3D = n.duplicate()
			copy.position = Vector3.ZERO
			copy.scale = Vector3.ONE * SCALE
			holder.add_child(copy)
			_templates[code] = holder
		n.visible = false
	# The model's board is turned a quarter from its pieces (its a1 is a
	# light square); turn it so a1 is dark, as the Laws require.
	var board := inst.find_child("board", true, false)
	if board is Node3D:
		board.rotate_y(PI / 2)


## Square centres. The model's a-file is on +x (white sits at -z, looking
## towards +z, so +x is on white's left), ranks grow towards +z.
func square_position(s: int) -> Vector3:
	return Vector3(-(ORIGIN + Rules.file_of(s) * SQUARE), TOP, ORIGIN + Rules.rank_of(s) * SQUARE)


func square_at(world: Vector3) -> int:
	var f := int(round((-world.x - ORIGIN) / SQUARE))
	var r := int(round((world.z - ORIGIN) / SQUARE))
	if f < 0 or f > 7 or r < 0 or r > 7:
		return -1
	return Rules.sq(f, r)


func _new_piece(code: int) -> Node3D:
	var t: Node3D = _templates.get(code)
	var n: Node3D = t.duplicate() if t else Node3D.new()
	n.set_meta("code", code)
	return n


func _place_all_pieces() -> void:
	for n in _pieces.values():
		n.queue_free()
	for side_list in _captured:
		for n in side_list:
			n.queue_free()
	_pieces.clear()
	_captured = [[], []]
	for s in 64:
		var p: int = rules.piece_at(s)
		if p:
			var n := _new_piece(p)
			n.position = square_position(s)
			_board_root.add_child(n)
			_pieces[s] = n
	_clear_markers()
	_mark_last_move()


# ---------------------------------------------------------------------------
# Camera and input
# ---------------------------------------------------------------------------

func _update_camera() -> void:
	if _camera == null:
		return
	# Yaw 0: behind white (looking towards +z, black's side).
	var dir := Vector3(sin(_cam_yaw) * cos(_cam_pitch), sin(_cam_pitch), -cos(_cam_yaw) * cos(_cam_pitch))
	_camera.position = dir * _cam_dist + Vector3(0, TOP, 0)
	_camera.look_at(Vector3(0, TOP, 0), Vector3.UP)
	# Keep the board clear of the side panel on wide screens.
	var vp := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(16, 9)
	_camera.h_offset = 0.55 if vp.x / max(vp.y, 1.0) > 1.3 else 0.0


func _process(delta: float) -> void:
	if not started:
		return
	_update_camera()
	if not over and clocks[0] > 0.0 and rules.moves_played() > 0 and _animating == 0:
		var s: int = rules.side
		clocks[s] = max(0.0, clocks[s] - delta)
		if clocks[s] <= 0.0:
			# Flag fall: the other side wins unless it cannot mate at all.
			var winner := 1 - s
			if _can_mate(winner):
				_finish("1-0" if winner == Rules.WHITE_SIDE else "0-1", "time")
			else:
				_finish("1/2-1/2", "time, insufficient material")
		_hud.set_clocks(clocks)
	_poll_ai()


func _can_mate(who: int) -> bool:
	var col := Rules.BLACK if who == Rules.BLACK_SIDE else 0
	var minors := 0
	for s in 64:
		var p: int = rules.piece_at(s)
		if p and (p & Rules.BLACK) == col:
			var t := Rules.type_of(p)
			if t == Rules.PAWN or t == Rules.ROOK or t == Rules.QUEEN:
				return true
			if t == Rules.BISHOP or t == Rules.KNIGHT:
				minors += 1
	return minors >= 2


func _unhandled_input(event: InputEvent) -> void:
	if not started:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_cam_dist = clamp(_cam_dist - 0.35, 3.2, 10.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_cam_dist = clamp(_cam_dist + 0.35, 3.2, 10.0)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_drag = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_click(event.position)
	elif event is InputEventMouseMotion and _drag:
		_orbit(event.relative)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_touch_start = event.position
				_touch_moved = false
		else:
			if _touches.size() == 1 and not _touch_moved:
				_click(event.position)
			_touches.erase(event.index)
			_pinch_dist = 0.0
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			if event.position.distance_to(_touch_start) > 12.0:
				_touch_moved = true
				_orbit(event.relative)
		elif _touches.size() == 2:
			var pts: Array = _touches.values()
			var d: float = pts[0].distance_to(pts[1])
			if _pinch_dist > 0.0:
				_cam_dist = clamp(_cam_dist * _pinch_dist / max(d, 1.0), 3.2, 10.0)
			_pinch_dist = d
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F:
				_on_hud_action("flip", {})
			KEY_U:
				_on_hud_action("undo", {})
			KEY_ESCAPE:
				_deselect()

func _orbit(rel: Vector2) -> void:
	_cam_yaw -= rel.x * 0.006
	_cam_target_yaw = _cam_yaw
	_cam_pitch = clamp(_cam_pitch + rel.y * 0.004, deg_to_rad(18), deg_to_rad(84))


func _click(screen: Vector2) -> void:
	if over or _ai_busy or _animating > 0 or rules.side != player_side or _hud.modal_open():
		return
	var from := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	if abs(dir.y) < 0.0001:
		return
	var t := (TOP - from.y) / dir.y
	if t < 0:
		return
	var s := square_at(from + dir * t)
	if s < 0:
		_deselect()
		return
	tap_square(s)


## Selecting and moving by squares (the click handler, and tests).
func tap_square(s: int) -> void:
	if _selected >= 0 and s in _target_squares():
		var m: int = rules.find_move(_selected, s, Rules.QUEEN)
		if rules.is_promotion(_selected, s):
			var from := _selected
			_hud.ask_promotion(player_side, func(kind: int):
				_commit(rules.find_move(from, s, kind)))
			return
		_commit(m)
		return
	var p: int = rules.piece_at(s)
	if p and Rules.color_of(p) == player_side:
		_select(s)
	else:
		_deselect()


func _target_squares() -> PackedInt32Array:
	var out := PackedInt32Array()
	for m in _targets:
		out.append(Rules.move_to(m))
	return out


func _select(s: int) -> void:
	_deselect()
	_selected = s
	_targets = rules.legal_moves_from(s)
	var n: Node3D = _pieces.get(s)
	if n:
		var tw := create_tween()
		tw.tween_property(n, "position:y", TOP + 0.12, 0.12)
	_markers.append(_marker(s, Color(0.35, 0.75, 1.0, 0.55), 0.46))
	for m in _targets:
		var capture := (Rules.move_flags(m) & Rules.F_CAPTURE) != 0
		_markers.append(_marker(Rules.move_to(m), Color(1.0, 0.45, 0.35, 0.65) if capture else Color(0.45, 1.0, 0.6, 0.55), 0.42 if capture else 0.2))


func _deselect() -> void:
	if _selected >= 0:
		var n: Node3D = _pieces.get(_selected)
		if n:
			create_tween().tween_property(n, "position:y", TOP, 0.1)
	_selected = -1
	_targets = PackedInt32Array()
	_clear_markers()


func _marker(s: int, color: Color, radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius * SQUARE
	cm.bottom_radius = radius * SQUARE
	cm.height = 0.004
	cm.radial_segments = 32
	mi.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 0.4
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = square_position(s) + Vector3(0, 0.003, 0)
	_board_root.add_child(mi)
	return mi


func _clear_markers() -> void:
	for m in _markers:
		m.queue_free()
	_markers.clear()


func _mark_last_move() -> void:
	for m in _last_markers:
		m.queue_free()
	_last_markers.clear()
	var lm: int = rules.last_move()
	if lm >= 0:
		for s in [Rules.move_from(lm), Rules.move_to(lm)]:
			_last_markers.append(_marker(s, Color(1.0, 0.85, 0.3, 0.35), 0.5))
	if rules.in_check():
		_last_markers.append(_marker(rules.king_sq[rules.side], Color(1.0, 0.15, 0.1, 0.6), 0.5))


# ---------------------------------------------------------------------------
# Playing
# ---------------------------------------------------------------------------

func _commit(m: int) -> void:
	if m < 0:
		return
	_deselect()
	var mover: int = rules.side
	var san: String = rules.san(m)
	_animate(m)
	rules.make(m)
	san_list.append(san)
	if clocks[0] > 0.0:
		clocks[mover] += increment
	_mark_last_move()
	_emit({"type": "move", "san": san, "uci": Rules.uci(m), "fen": rules.fen(),
		"by": "player" if mover == player_side else "ai"})
	_refresh_hud()
	var st: Dictionary = rules.status()
	if st.over:
		_finish(st.result, st.reason)
		return
	# The AI claims a draw by rule when it is not ahead.
	if st.claimable != "" and mover == player_side and _ai_eval_for_ai() <= 0:
		_finish("1/2-1/2", st.claimable + " (claimed by the AI)")
		return
	if rules.side != player_side:
		_start_ai()


func _ai_eval_for_ai() -> int:
	return ai.evaluate(rules) if rules.side != player_side else -ai.evaluate(rules)


func _animate(m: int) -> void:
	var from := Rules.move_from(m)
	var to := Rules.move_to(m)
	var flags := Rules.move_flags(m)
	var n: Node3D = _pieces.get(from)
	var cap_sq := to
	if flags & Rules.F_EP:
		cap_sq = to - 8 if rules.side == Rules.WHITE_SIDE else to + 8
	var victim: Node3D = _pieces.get(cap_sq)
	if victim and victim != n:
		_pieces.erase(cap_sq)
		var by: int = rules.side
		var idx: int = _captured[by].size()
		_captured[by].append(victim)
		# Captured pieces line up beside the board, on the capturer's right.
		var side_x := -(ORIGIN + 8.6 * SQUARE) if by == Rules.WHITE_SIDE else -(ORIGIN - 1.6 * SQUARE)
		var z := (ORIGIN + (idx % 8) * SQUARE) if by == Rules.WHITE_SIDE else (ORIGIN + (7 - idx % 8) * SQUARE)
		var dest := Vector3(side_x - (idx / 8) * 0.5 * (1 if by == Rules.WHITE_SIDE else -1), TOP - 0.17, z)
		_tween_arc(victim, dest, 0.5, 0.2)
	if n:
		_pieces.erase(from)
		_pieces[to] = n
		var high := 0.55 if Rules.type_of(rules.piece_at(from)) == Rules.KNIGHT else 0.12
		_tween_arc(n, square_position(to), 0.32, high)
		if Rules.move_promo(m):
			var color_bit := rules.piece_at(from) & Rules.BLACK
			var promoted := _new_piece(Rules.move_promo(m) | color_bit)
			promoted.position = square_position(to)
			promoted.scale = Vector3.ONE * 0.01
			_board_root.add_child(promoted)
			_pieces[to] = promoted
			var tw := create_tween()
			tw.tween_interval(0.3)
			tw.tween_callback(n.queue_free)
			tw.tween_property(promoted, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK)
	if flags & Rules.F_CASTLE:
		var rook_from := from + 3 if to > from else from - 4
		var rook_to := from + 1 if to > from else from - 1
		var rook: Node3D = _pieces.get(rook_from)
		if rook:
			_pieces.erase(rook_from)
			_pieces[rook_to] = rook
			_tween_arc(rook, square_position(rook_to), 0.32, 0.35)


func _tween_arc(n: Node3D, dest: Vector3, time: float, height: float) -> void:
	if _headless:
		n.position = dest
		return
	_animating += 1
	var start := n.position
	var tw := create_tween()
	tw.tween_method(func(t: float):
		var p := start.lerp(dest, ease(t, -1.8))
		p.y = lerp(start.y, dest.y, t) + sin(t * PI) * height
		n.position = p, 0.0, 1.0, time)
	tw.tween_callback(func(): _animating -= 1)


func _start_ai() -> void:
	if over:
		return
	_ai_busy = true
	_hud.set_thinking(true)
	var snapshot = rules.clone()
	var budget := -1
	if clocks[0] > 0.0:
		# Never spend more than a thirtieth of what is left.
		budget = int(clamp(clocks[1 - player_side] / 30.0 * 1000.0, 150.0, 4000.0))
	if OS.has_feature("threads") and not _headless:
		_thread = Thread.new()
		_thread.start(_ai_work.bind(snapshot, budget))
	else:
		# No threads (a single-threaded web export): think after this frame.
		await get_tree().process_frame
		_ai_work(snapshot, budget)


func _ai_work(snapshot, budget: int) -> void:
	var r: Dictionary = ai.choose(snapshot, budget)
	_ai_mutex.lock()
	_ai_result = r
	_ai_mutex.unlock()


func _poll_ai() -> void:
	if not _ai_busy:
		return
	_ai_mutex.lock()
	var r := _ai_result
	_ai_result = {}
	_ai_mutex.unlock()
	if r.is_empty():
		return
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	_ai_busy = false
	_hud.set_thinking(false)
	if over:
		return
	var m: int = r.get("move", -1)
	if m >= 0 and m in rules.legal_moves():
		_commit(m)


## Waits (in tests and headless runs) until the AI has moved.
func await_ai() -> void:
	while _ai_busy:
		await get_tree().process_frame


func _finish(result: String, reason: String) -> void:
	if over:
		return
	over = true
	_deselect()
	var outcome := "draw"
	if result == "1-0":
		outcome = "win" if player_side == Rules.WHITE_SIDE else "loss"
	elif result == "0-1":
		outcome = "win" if player_side == Rules.BLACK_SIDE else "loss"
	var ev := {
		"type": "result", "game": "chess", "outcome": outcome, "result": result,
		"reason": reason, "moves": rules.moves_played(), "pgn": pgn(result),
		"duration_s": int((Time.get_ticks_msec() - started_at) / 1000),
		"level": ai.level, "player_color": params.player_color, "takebacks": takebacks,
		"score": _score_for(outcome),
	}
	_hud.show_result(outcome, result, reason)
	_emit(ev)


## Points for the leaderboard: a win is worth more at a higher level, a
## draw half; take-backs cost.
func _score_for(outcome: String) -> int:
	var base: int = {"win": 100, "draw": 40, "loss": 10}[outcome]
	return max(0, base * ai.level - takebacks * 15)


func pgn(result: String = "*") -> String:
	var white := str(params.player_name) if player_side == Rules.WHITE_SIDE else "%s (level %d)" % [params.opponent_name, ai.level]
	var black := str(params.player_name) if player_side == Rules.BLACK_SIDE else "%s (level %d)" % [params.opponent_name, ai.level]
	var head := '[Event "Aseman Arena"]\n[Site "Aseman"]\n[Date "%s"]\n[White "%s"]\n[Black "%s"]\n[Result "%s"]\n' % [
		Time.get_date_string_from_system().replace("-", "."), white, black, result]
	if str(params.get("fen", "")) != "":
		head += '[SetUp "1"]\n[FEN "%s"]\n' % params.fen
	var body := ""
	for i in san_list.size():
		if i % 2 == 0:
			body += "%d. " % (i / 2 + 1)
		body += san_list[i] + " "
	return head + "\n" + body + result


func _on_hud_action(what: String, data: Dictionary) -> void:
	match what:
		"undo":
			# Take back the person's last move (and the AI's answer).
			if over or _ai_busy or rules.moves_played() == 0:
				return
			var n := 2 if rules.side == player_side else 1
			if rules.moves_played() < n:
				n = rules.moves_played()
			for i in n:
				rules.unmake()
				san_list.remove_at(san_list.size() - 1)
			takebacks += 1
			_place_all_pieces()
			_refresh_hud()
			if rules.side != player_side:
				_start_ai()
		"resign":
			if not over:
				_finish("0-1" if player_side == Rules.WHITE_SIDE else "1-0", "resignation")
		"draw":
			if over:
				return
			var st: Dictionary = rules.status()
			if st.claimable != "":
				_finish("1/2-1/2", st.claimable)
			elif _ai_eval_for_ai() < -150 and rules.moves_played() >= 30:
				# The AI accepts a draw offer only when it is clearly worse.
				_finish("1/2-1/2", "agreement")
			else:
				_hud.toast("%s declines the draw." % params.opponent_name)
		"flip":
			_cam_yaw += PI
			_cam_target_yaw = _cam_yaw
		"new":
			arena_start({})
		"level":
			params.level = int(data.get("level", 3))
			arena_start({})


func _refresh_hud() -> void:
	var st: Dictionary = rules.status()
	var turn := "Your move" if rules.side == player_side else "%s is thinking…" % params.opponent_name
	if st.check and not st.over:
		turn = ("Check — " + turn)
	_hud.set_status(turn, st)
	_hud.set_moves(san_list)
	_hud.set_clocks(clocks)
	_hud.set_material(_material_balance())


func _material_balance() -> int:
	var v := [0, 1, 3, 3, 5, 9, 0]
	var score := 0
	for s in 64:
		var p: int = rules.piece_at(s)
		if p:
			score += v[p & 7] * (1 if Rules.color_of(p) == player_side else -1)
	return score


# ---------------------------------------------------------------------------
# Talking to the outside
# ---------------------------------------------------------------------------

func _emit(ev: Dictionary) -> void:
	var json := JSON.stringify(ev)
	arena_event.emit(json)
	if _standalone and OS.has_feature("web"):
		# In the browser the platform's page listens for these.
		JavaScriptBridge.eval("window.parent && window.parent.postMessage({arena: %s}, '*')" % json, true)
	if _standalone and ev.get("type") == "result":
		_report(ev)


## The browser build reports a finished game to the platform's server with
## the match's one-time token (from the page's query: ?match=…&token=…).
func _report(ev: Dictionary) -> void:
	var url := str(params.get("report_url", ""))
	if url == "":
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := ev.duplicate()
	body["token"] = str(params.get("token", ""))
	http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))


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
	var names := {"color": "player_color", "name": "player_name", "tc": "time_control", "report": "report_url"}
	for k in names:
		if out.has(k):
			out[names[k]] = out[k]
	if out.has("level"):
		out.level = int(out.level)
	return out
