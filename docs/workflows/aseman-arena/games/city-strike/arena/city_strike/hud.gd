## City Strike's interface: crosshair (opens with spread), hit marker,
## health and armour, ammunition and reload, wave and enemies left, score,
## a radar of nearby enemies, the kill feed, a red edge towards whoever
## hits you, the wave banner and the result card — plus touch controls
## (a move stick, look by dragging, fire / aim / reload / jump) on
## touchscreens.
extends CanvasLayer

signal action(what: String)

const ACCENT := Color(0.42, 0.66, 1.0)
const PANEL := Color(0.05, 0.07, 0.1, 0.72)
const TEXT := Color(0.94, 0.96, 1.0)
const DANGER := Color(1.0, 0.32, 0.28)

var player
var game
var _health: ProgressBar
var _armor: ProgressBar
var _ammo: Label
var _wave: Label
var _score: Label
var _feed: VBoxContainer
var _banner: Label
var _hitmarker := 0.0
var _hurt := 0.0
var _hurt_dir := 0.0
var _canvas: Control
var _modal: Control
var _touch := false
var _stick_center := Vector2.ZERO
var _stick_index := -1
var _stick_vec := Vector2.ZERO
var _look_index := -1
var _buttons := {}


func _ready() -> void:
	layer = 10
	_touch = DisplayServer.is_touchscreen_available()
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_overlay)
	add_child(_canvas)

	var status := _panel(Vector2(16, -112), Vector2(300, 96), false, true)
	var col := VBoxContainer.new()
	status.add_child(col)
	_label(col, "HEALTH", 11, Color(0.7, 0.75, 0.85))
	_health = _bar(col, Color(0.35, 0.9, 0.55))
	_label(col, "ARMOUR", 11, Color(0.7, 0.75, 0.85))
	_armor = _bar(col, ACCENT)

	var ammo_panel := _panel(Vector2(-236, -112), Vector2(220, 96), true, true)
	_ammo = _label(ammo_panel, "30 / 120", 30, TEXT)
	_ammo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var top := _panel(Vector2(-180, 12), Vector2(360, 54), false, false)
	top.anchor_left = 0.5
	top.anchor_right = 0.5
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	top.add_child(row)
	_wave = _label(row, "WAVE 1", 18, TEXT)
	_score = _label(row, "0", 18, Color(1.0, 0.85, 0.4))

	_feed = VBoxContainer.new()
	_feed.anchor_left = 1.0
	_feed.anchor_right = 1.0
	_feed.offset_left = -330
	_feed.offset_right = -16
	_feed.offset_top = 196
	_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_feed)

	_banner = _label(self, "", 44, TEXT)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_top = 110
	_banner.offset_left = -400
	_banner.offset_right = 400
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0

	if _touch:
		_build_touch()


func _process(delta: float) -> void:
	if player == null:
		return
	_health.value = player.health / player.max_health * 100.0
	_armor.value = player.armor
	var w = player.weapon
	_ammo.text = ("RELOADING" if w.reloading else "%d / %d" % [w.magazine, w.reserve])
	_hitmarker = max(0.0, _hitmarker - delta * 4.0)
	_hurt = max(0.0, _hurt - delta * 1.5)
	if game:
		_wave.text = "WAVE %d / %d  ·  %d LEFT" % [game.wave, game.waves, game.enemies_left()]
		_score.text = "%d PTS" % game.score
	_canvas.queue_redraw()
	if _touch:
		player.touch_move = _stick_vec


func hit(headshot: bool) -> void:
	_hitmarker = 1.6 if headshot else 1.0


func hurt(from: Vector3) -> void:
	_hurt = 1.0
	if player and player.camera:
		var to: Vector3 = from - player.global_position
		var fwd: Vector3 = -player.camera.global_transform.basis.z
		_hurt_dir = atan2(to.x, to.z) - atan2(fwd.x, fwd.z)


func feed(text: String, color: Color = TEXT) -> void:
	var l := _label(_feed, text, 15, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var tw := l.create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(l, "modulate:a", 0.0, 0.6)
	tw.tween_callback(l.queue_free)
	while _feed.get_child_count() > 6:
		_feed.get_child(0).queue_free()
		_feed.remove_child(_feed.get_child(0))


func banner(text: String) -> void:
	_banner.text = text
	var tw := create_tween()
	tw.tween_property(_banner, "modulate:a", 1.0, 0.25)
	tw.tween_interval(1.8)
	tw.tween_property(_banner, "modulate:a", 0.0, 0.5)


func show_result(won: bool, summary: Dictionary) -> void:
	if _modal:
		_modal.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_modal = dim
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(Color(0.07, 0.09, 0.14, 0.97), 24))
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	dim.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	card.add_child(col)
	var t := _label(col, "CITY SECURED" if won else "ELIMINATED", 36, Color(0.5, 1.0, 0.6) if won else DANGER)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for k in [["Score", str(summary.score)], ["Kills", str(summary.kills)], ["Headshots", str(summary.headshots)],
			["Accuracy", "%d%%" % int(summary.accuracy * 100)], ["Waves cleared", "%d / %d" % [summary.waves_cleared, summary.waves]],
			["Time", "%d:%02d" % [summary.duration_s / 60, summary.duration_s % 60]]]:
		var r := HBoxContainer.new()
		col.add_child(r)
		var a := _label(r, k[0], 18, Color(0.7, 0.75, 0.85))
		a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		a.custom_minimum_size.x = 220
		_label(r, k[1], 18, TEXT)
	var again := Button.new()
	again.text = "Play again"
	again.custom_minimum_size = Vector2(0, 46)
	again.add_theme_stylebox_override("normal", _box(Color(0.16, 0.3, 0.55), 12))
	again.add_theme_stylebox_override("hover", _box(Color(0.2, 0.36, 0.65), 12))
	again.pressed.connect(func():
		dim.queue_free()
		_modal = null
		action.emit("restart"))
	col.add_child(again)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func clear_modal() -> void:
	if _modal:
		_modal.queue_free()
		_modal = null


# ---------------------------------------------------------------------------
# Drawing: crosshair, hit marker, damage edge, radar, touch stick
# ---------------------------------------------------------------------------

func _draw_overlay() -> void:
	if player == null:
		return
	var size := _canvas.size
	var c := size / 2.0
	var w = player.weapon
	var gap: float = 6.0 + w.spread * 900.0 * (0.6 if player.aiming else 1.0)
	var col := Color(1, 1, 1, 0.9)
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		_canvas.draw_line(c + d * gap, c + d * (gap + 9.0), Color(0, 0, 0, 0.6), 4.0)
		_canvas.draw_line(c + d * gap, c + d * (gap + 9.0), col, 2.0)
	_canvas.draw_circle(c, 1.6, col)
	if w.reloading:
		_canvas.draw_arc(c, 18, -PI / 2, -PI / 2 + TAU * w.reload_progress(), 32, ACCENT, 3.0)
	if _hitmarker > 0.0:
		var hc := Color(1, 0.25, 0.2, minf(1.0, _hitmarker)) if _hitmarker > 1.2 else Color(1, 1, 1, minf(1.0, _hitmarker))
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			_canvas.draw_line(c + d * 7, c + d * 15, hc, 2.5)
	if _hurt > 0.0:
		var a := _hurt_dir - PI / 2
		_canvas.draw_arc(c, min(size.x, size.y) * 0.32, a - 0.45, a + 0.45, 24, Color(1, 0.15, 0.1, _hurt * 0.85), 10.0)
		if player.health < 35:
			_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.6, 0, 0, 0.12 * _hurt), false, 40.0)
	_draw_radar(Vector2(size.x - 96, 108), 80.0)
	if _touch and _stick_index >= 0:
		_canvas.draw_circle(_stick_center, 70, Color(1, 1, 1, 0.12))
		_canvas.draw_circle(_stick_center + _stick_vec * 60, 30, Color(1, 1, 1, 0.35))


func _draw_radar(center: Vector2, radius: float) -> void:
	_canvas.draw_circle(center, radius, Color(0.04, 0.06, 0.09, 0.7))
	_canvas.draw_arc(center, radius, 0, TAU, 48, Color(1, 1, 1, 0.18), 2.0)
	_canvas.draw_arc(center, radius * 0.5, 0, TAU, 32, Color(1, 1, 1, 0.08), 1.0)
	var range_m := 60.0
	var fwd: Vector3 = -player.camera.global_transform.basis.z
	var yaw := atan2(fwd.x, fwd.z)
	_canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(0, -8), center + Vector2(6, 6), center + Vector2(-6, 6)]), ACCENT)
	for b in get_tree().get_nodes_in_group("bots"):
		if not b.alive:
			continue
		var rel: Vector3 = b.global_position - player.global_position
		if rel.length() > range_m:
			continue
		# Only those that are fighting (they make noise) or close show.
		if b.state == b.State.PATROL and rel.length() > 20.0:
			continue
		var v := Vector2(rel.x, rel.z).rotated(-yaw) / range_m * radius
		_canvas.draw_circle(center + Vector2(-v.x, -v.y), 4.0, DANGER)


# ---------------------------------------------------------------------------
# Touch controls
# ---------------------------------------------------------------------------

func _build_touch() -> void:
	for spec in [["FIRE", "fire", Vector2(-150, -230), 64], ["AIM", "aim", Vector2(-260, -170), 44], ["R", "reload", Vector2(-120, -330), 36], ["JUMP", "jump", Vector2(-250, -300), 36]]:
		var b := Button.new()
		b.text = spec[0]
		b.anchor_left = 1.0
		b.anchor_right = 1.0
		b.anchor_top = 1.0
		b.anchor_bottom = 1.0
		var r: int = spec[3]
		b.offset_left = spec[2].x - r
		b.offset_top = spec[2].y - r
		b.offset_right = spec[2].x + r
		b.offset_bottom = spec[2].y + r
		b.add_theme_stylebox_override("normal", _box(Color(1, 1, 1, 0.14), r))
		b.add_theme_stylebox_override("pressed", _box(Color(0.42, 0.66, 1.0, 0.45), r))
		b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.18), r))
		var what: String = spec[1]
		b.button_down.connect(func(): _touch_button(what, true))
		b.button_up.connect(func(): _touch_button(what, false))
		add_child(b)
		_buttons[what] = b


func _touch_button(what: String, down: bool) -> void:
	match what:
		"fire":
			player.touch_fire = down
		"aim":
			if down:
				player.touch_aim = not player.touch_aim
		"reload":
			if down:
				player.weapon.reload()
		"jump":
			if down and player.is_on_floor():
				player.velocity.y = player.JUMP


func _input(event: InputEvent) -> void:
	if not _touch or player == null:
		return
	var size := _canvas.size
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x < size.x * 0.4 and _stick_index < 0:
				_stick_index = event.index
				_stick_center = event.position
				_stick_vec = Vector2.ZERO
			elif event.position.x >= size.x * 0.4 and _look_index < 0:
				_look_index = event.index
		else:
			if event.index == _stick_index:
				_stick_index = -1
				_stick_vec = Vector2.ZERO
			elif event.index == _look_index:
				_look_index = -1
	elif event is InputEventScreenDrag:
		if event.index == _stick_index:
			_stick_vec = ((event.position - _stick_center) / 60.0).limit_length(1.0)
		elif event.index == _look_index:
			player.look(event.relative * 1.4)


# ---------------------------------------------------------------------------

func _panel(offset: Vector2, size: Vector2, right: bool, bottom: bool) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(PANEL, 16))
	p.anchor_left = 1.0 if right else 0.0
	p.anchor_right = p.anchor_left
	p.anchor_top = 1.0 if bottom else 0.0
	p.anchor_bottom = p.anchor_top
	p.offset_left = offset.x
	p.offset_top = offset.y
	p.offset_right = offset.x + size.x
	p.offset_bottom = offset.y + size.y
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(p)
	return p


func _bar(parent: Node, color: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.custom_minimum_size = Vector2(260, 12)
	b.add_theme_stylebox_override("background", _box(Color(1, 1, 1, 0.1), 6, 0))
	b.add_theme_stylebox_override("fill", _box(color, 6, 0))
	parent.add_child(b)
	return b


func _label(parent: Node, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _box(color: Color, radius: int, pad: int = 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = pad * 0.7
	s.content_margin_bottom = pad * 0.7
	return s
