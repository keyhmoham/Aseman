## The chess game's interface: the two players with their clocks and
## material, the status line, the move list, the actions (take back, offer or
## claim a draw, resign, flip the board, a new game at a chosen level), the
## promotion picker and the result card. Built in code with one dark glass
## theme so it is identical in every host.
extends CanvasLayer

signal action(what: String, data: Dictionary)

const Rules = preload("res://arena/chess/chess_rules.gd")

const ACCENT := Color(0.42, 0.66, 1.0)
const PANEL := Color(0.06, 0.08, 0.12, 0.78)
const TEXT := Color(0.93, 0.95, 1.0)
const MUTED := Color(0.62, 0.68, 0.8)

var _you: Label
var _them: Label
var _you_clock: Label
var _them_clock: Label
var _status: Label
var _moves: RichTextLabel
var _thinking: Label
var _toast: Label
var _modal: Control
var _player_side := 0
var _params := {}


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Top: the opponent. Bottom: the person.
	var top := _bar(root, true)
	_them = _label(top, "Aseman AI", 20, TEXT)
	_them.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thinking = _label(top, "", 16, ACCENT)
	_them_clock = _label(top, "", 22, TEXT)
	var bottom := _bar(root, false)
	_you = _label(bottom, "You", 20, TEXT)
	_you.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_you_clock = _label(bottom, "", 22, TEXT)

	# Right: status, moves and actions.
	var side := PanelContainer.new()
	side.add_theme_stylebox_override("panel", _box(PANEL, 18))
	side.anchor_left = 1.0
	side.anchor_right = 1.0
	side.anchor_top = 0.0
	side.anchor_bottom = 1.0
	side.offset_left = -260
	side.offset_right = -16
	side.offset_top = 88
	side.offset_bottom = -88
	root.add_child(side)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	side.add_child(col)
	_status = _label(col, "", 18, TEXT)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label(col, "MOVES", 12, MUTED)
	_moves = RichTextLabel.new()
	_moves.bbcode_enabled = true
	_moves.scroll_following = true
	_moves.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_moves.add_theme_color_override("default_color", TEXT)
	_moves.add_theme_font_size_override("normal_font_size", 16)
	col.add_child(_moves)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)
	for a in [["Take back", "undo"], ["Draw", "draw"], ["Flip", "flip"], ["Resign", "resign"]]:
		var b := _button(grid, a[0], a[1] == "resign")
		var what: String = a[1]
		b.pressed.connect(func(): action.emit(what, {}))
	_label(col, "NEW GAME · LEVEL", 12, MUTED)
	var lv := HBoxContainer.new()
	lv.add_theme_constant_override("separation", 6)
	col.add_child(lv)
	for i in range(1, 6):
		var b := _button(lv, str(i), false)
		b.custom_minimum_size = Vector2(30, 30)
		b.add_theme_stylebox_override("normal", _box(Color(0.16, 0.22, 0.34, 0.9), 10, 6))
		b.tooltip_text = "Level %d" % i
		var lvl := i
		b.pressed.connect(func(): action.emit("level", {"level": lvl}))

	_toast = _label(root, "", 18, TEXT)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.anchor_top = 1.0
	_toast.anchor_bottom = 1.0
	_toast.offset_top = -150
	_toast.offset_left = -240
	_toast.offset_right = 240
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0


func setup(params: Dictionary, player_side: int) -> void:
	_params = params
	_player_side = player_side
	var lvl := int(params.get("level", 3))
	_them.text = "%s  ·  level %d  ·  %s" % [params.get("opponent_name", "Aseman AI"), lvl, "black" if player_side == Rules.WHITE_SIDE else "white"]
	_you.text = "%s  ·  %s" % [params.get("player_name", "You"), "white" if player_side == Rules.WHITE_SIDE else "black"]
	if _modal:
		_modal.queue_free()
		_modal = null


func set_status(text: String, st: Dictionary) -> void:
	_status.text = text


func set_moves(list: PackedStringArray) -> void:
	var out := ""
	for i in list.size():
		if i % 2 == 0:
			out += "[color=#8ea0c0]%d.[/color] " % (i / 2 + 1)
		out += list[i] + ("   " if i % 2 == 0 else "\n")
	_moves.text = out


func set_clocks(clocks: Array) -> void:
	if clocks[0] <= 0.0 and clocks[1] <= 0.0:
		_you_clock.text = ""
		_them_clock.text = ""
		return
	_you_clock.text = _fmt(clocks[_player_side])
	_them_clock.text = _fmt(clocks[1 - _player_side])


func set_material(balance: int) -> void:
	var base := _you.text.split("   +")[0]
	_you.text = base + ("   +%d" % balance if balance > 0 else "")


func set_thinking(on: bool) -> void:
	_thinking.text = "thinking…  " if on else ""


func toast(text: String) -> void:
	_toast.text = text
	var tw := create_tween()
	tw.tween_property(_toast, "modulate:a", 1.0, 0.2)
	tw.tween_interval(2.0)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.4)


func modal_open() -> bool:
	return _modal != null


func ask_promotion(side: int, done: Callable) -> void:
	var card := _card("Promote to")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.get_child(0).add_child(row)
	for k in [[Rules.QUEEN, "Queen", "♛"], [Rules.ROOK, "Rook", "♜"], [Rules.BISHOP, "Bishop", "♝"], [Rules.KNIGHT, "Knight", "♞"]]:
		var b := _button(row, "%s\n%s" % [k[2], k[1]], false)
		b.custom_minimum_size = Vector2(84, 84)
		var kind: int = k[0]
		b.pressed.connect(func():
			_close_modal()
			done.call(kind))


func show_result(outcome: String, result: String, reason: String) -> void:
	var title: String = {"win": "You win!", "loss": "You lost", "draw": "Draw"}[outcome]
	var card := _card(title)
	var box: VBoxContainer = card.get_child(0)
	_label(box, "%s  ·  by %s" % [result, reason], 18, MUTED)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var again := _button(row, "Play again", false)
	again.pressed.connect(func():
		_close_modal()
		action.emit("new", {}))
	var look := _button(row, "Review board", false)
	look.pressed.connect(_close_modal)


# ---------------------------------------------------------------------------

func _close_modal() -> void:
	if _modal:
		_modal.queue_free()
		_modal = null


func _card(title: String) -> PanelContainer:
	_close_modal()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_modal = dim
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(Color(0.08, 0.1, 0.15, 0.96), 24))
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	dim.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(box)
	var t := _label(box, title, 30, TEXT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return card


func _bar(root: Control, top: bool) -> HBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(PANEL, 16))
	panel.anchor_left = 0.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0 if top else 1.0
	panel.anchor_bottom = 0.0 if top else 1.0
	panel.offset_left = 16
	panel.offset_right = -16
	panel.offset_top = 16 if top else -72
	panel.offset_bottom = 72 if top else -16
	root.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	return row


func _label(parent: Node, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, danger: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(110, 40)
	b.add_theme_font_size_override("font_size", 15)
	var base := Color(0.55, 0.16, 0.18, 0.9) if danger else Color(0.16, 0.22, 0.34, 0.9)
	b.add_theme_stylebox_override("normal", _box(base, 12))
	b.add_theme_stylebox_override("hover", _box(base.lightened(0.15), 12))
	b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.3), 12))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), 12))
	b.add_theme_color_override("font_color", TEXT)
	parent.add_child(b)
	return b


func _box(color: Color, radius: int, pad: int = 14) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	s.border_color = Color(1, 1, 1, 0.08)
	s.set_border_width_all(1)
	return s


func _fmt(seconds: float) -> String:
	var s := int(ceil(seconds))
	return "%d:%02d" % [s / 60, s % 60]
