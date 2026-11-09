## Production mobile HUD — thumb-first, single card rail, always-visible actions.
extends CanvasLayer

signal action(kind: String, data: Dictionary)

const Fonts = preload("res://arena/persian_rails/fonts.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")
const Assets = preload("res://arena/persian_rails/assets.gd")

var fa: Dictionary = {}
var _d: Dictionary = {}
var _root: Control
var _dim: ColorRect
var _prompt: Label
var _scores: HBoxContainer
var _cards_scroll: ScrollContainer
var _cards: HBoxContainer
var _face_scroll: ScrollContainer
var _face: HBoxContainer
var _hand_scroll: ScrollContainer
var _hand: HBoxContainer
var _face_wrap: VBoxContainer
var _hand_wrap: VBoxContainer
var _btn_row: HBoxContainer
var _toast_panel: PanelContainer
var _toast: Label
var _modal: PanelContainer
var _modal_body: VBoxContainer
var _bottom: Control
var _bottom_bg: Panel
var _top: Control
var _top_bg: Panel
var _claim_banner: PanelContainer
var _claim_hint: Label
var _turn_banner: PanelContainer
var _turn_label: Label
var _buttons: Array = []
var _last_rules = null
var _last_human := false
var _train_tex: Texture2D
var _single_row := true
var _pulse_kind := ""
var _pulse_tween: Tween
var _card_style: StyleBoxTexture
var _bottom_col: VBoxContainer
var _top_row: HBoxContainer
var _top_inner: MarginContainer
var _bottom_inner: MarginContainer


func _ready() -> void:
	layer = 20
	_train_tex = Assets.tex("train_icon.png")
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.layout_direction = Control.LAYOUT_DIRECTION_RTL
	add_child(_root)
	get_viewport().size_changed.connect(_on_resize)
	_build()
	call_deferred("_on_resize")


func set_strings(p_fa: Dictionary) -> void:
	fa = p_fa
	_refresh_labels()


func chrome_insets() -> Vector2:
	return Vector2(float(_d.get("top_h", 36.0)) + 4.0, float(_d.get("bottom_h", 110.0)) + 4.0)


func _t(key: String, fallback: String = "") -> String:
	return str(fa.get(key, fallback if fallback else key)).replace("🙂", "").replace("🚂", "").strip_edges()


func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.05, 0.02, 0.01, 0.58)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.visible = false
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_dim)

	# Control shell (not PanelContainer) so style/content min-size cannot grow over the map.
	_top = Control.new()
	_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top.mouse_filter = Control.MOUSE_FILTER_STOP
	_top.clip_contents = true
	_root.add_child(_top)
	_top_bg = Panel.new()
	_top_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_top_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.add_child(_top_bg)
	_top_inner = MarginContainer.new()
	_top_inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	_top_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.add_child(_top_inner)
	var top_col := VBoxContainer.new()
	top_col.add_theme_constant_override("separation", 2)
	top_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_top_inner.add_child(top_col)

	# One compact row: prompt + score chips (no empty strip / floating web shortcut).
	_top_row = HBoxContainer.new()
	_top_row.add_theme_constant_override("separation", 8)
	_top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_col.add_child(_top_row)

	_prompt = Label.new()
	_prompt.autowrap_mode = TextServer.AUTOWRAP_OFF
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_prompt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt.max_lines_visible = 1
	_prompt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt.clip_text = true
	_prompt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_prompt.add_theme_color_override("font_color", ThemeX.CREAM)
	_top_row.add_child(_prompt)

	var score_scroll := ScrollContainer.new()
	score_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	score_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	score_scroll.size_flags_horizontal = Control.SIZE_SHRINK_END
	score_scroll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_top_row.add_child(score_scroll)
	_scores = HBoxContainer.new()
	_scores.add_theme_constant_override("separation", 5)
	score_scroll.add_child(_scores)

	_claim_banner = PanelContainer.new()
	_claim_banner.visible = false
	top_col.add_child(_claim_banner)
	_claim_hint = Label.new()
	_claim_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_claim_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_claim_hint.add_theme_color_override("font_color", ThemeX.INK)
	_claim_banner.add_child(_claim_hint)

	_bottom = Control.new()
	_bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom.mouse_filter = Control.MOUSE_FILTER_STOP
	_bottom.clip_contents = true
	_root.add_child(_bottom)
	_bottom_bg = Panel.new()
	_bottom_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bottom_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bottom.add_child(_bottom_bg)
	_bottom_inner = MarginContainer.new()
	_bottom_inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bottom_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bottom.add_child(_bottom_inner)
	_bottom_col = VBoxContainer.new()
	_bottom_col.add_theme_constant_override("separation", 3)
	_bottom_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bottom_col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_bottom_col.alignment = BoxContainer.ALIGNMENT_BEGIN
	_bottom_inner.add_child(_bottom_col)

	# Dual-row (tablet) containers
	_face_scroll = _make_hscroll()
	_face = _make_card_row()
	_face_scroll.add_child(_face)
	_face_wrap = _section("روی میز", _face_scroll)
	_bottom_col.add_child(_face_wrap)

	_hand_scroll = _make_hscroll()
	_hand = _make_card_row()
	_hand_scroll.add_child(_hand)
	_hand_wrap = _section("دست تو", _hand_scroll)
	_bottom_col.add_child(_hand_wrap)

	# Single merged row (phones)
	_cards_scroll = _make_hscroll()
	_cards = _make_card_row()
	_cards_scroll.add_child(_cards)
	_bottom_col.add_child(_cards_scroll)

	_btn_row = HBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", 6)
	_btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_bottom_col.add_child(_btn_row)
	_buttons = [
		_make_action("برداشت", "draw_trains", "primary"),
		_make_action("ساخت مسیر", "claim_mode", "accent"),
		_make_action("قرارداد", "draw_tickets", "secondary"),
	]
	for b in _buttons:
		_btn_row.add_child(b)

	_toast_panel = PanelContainer.new()
	_toast_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.modulate.a = 0.0
	_root.add_child(_toast_panel)
	_toast = Label.new()
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.add_theme_color_override("font_color", ThemeX.INK)
	_toast_panel.add_child(_toast)

	_turn_banner = PanelContainer.new()
	_turn_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_turn_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_turn_banner.modulate.a = 0.0
	_root.add_child(_turn_banner)
	_turn_label = Label.new()
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.add_theme_color_override("font_color", ThemeX.CREAM)
	_turn_banner.add_child(_turn_label)

	_modal = PanelContainer.new()
	_modal.visible = false
	_modal.set_anchors_preset(Control.PRESET_CENTER)
	_root.add_child(_modal)
	_modal_body = VBoxContainer.new()
	_modal_body.add_theme_constant_override("separation", 10)
	_modal.add_child(_modal_body)


func _section(title: String, body: Control) -> VBoxContainer:
	var wrap := VBoxContainer.new()
	# No section titles — rail labels inside the merged row already name face/hand.
	wrap.add_theme_constant_override("separation", 0)
	body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	wrap.add_child(body)
	wrap.set_meta("section_title_text", title)
	return wrap


func _make_card_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	# Must NOT expand-to-fill the viewport — otherwise cards compress and never overflow/scroll.
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	return row


func _make_hscroll() -> ScrollContainer:
	var sc := ScrollContainer.new()
	# Visible bar when overflowing so swipe/scroll is obvious on phones.
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Never expand vertically with card minsize — clip instead of covering the map.
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sc.clip_contents = true
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	sc.mouse_filter = Control.MOUSE_FILTER_STOP
	sc.scroll_deadzone = 12
	sc.follow_focus = true
	# Drag anywhere on empty track still scrolls (Godot 4 touch/mouse drag).
	sc.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_WHEEL_LEFT:
			sc.scroll_horizontal = maxi(0, sc.scroll_horizontal - 48)
			sc.accept_event()
		elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
			sc.scroll_horizontal = sc.scroll_horizontal + 48
			sc.accept_event()
		elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			# Vertical wheel → horizontal rail (common phone/desktop habit).
			sc.scroll_horizontal = maxi(0, sc.scroll_horizontal - 56)
			sc.accept_event()
		elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			sc.scroll_horizontal = sc.scroll_horizontal + 56
			sc.accept_event()
	)
	return sc


func _snap_card_scrolls() -> void:
	# After rebuild, land on the start of the rail (RTL: high scroll = right/start).
	for sc in [_cards_scroll, _face_scroll, _hand_scroll]:
		if sc == null or not sc.visible:
			continue
		await get_tree().process_frame
		var bar: ScrollBar = sc.get_h_scroll_bar()
		if bar:
			bar.custom_minimum_size.y = 10.0
			bar.visible = bar.max_value > bar.min_value + 1.0
		# RTL layout: keep the right edge (first labels/cards) in view.
		if _root.layout_direction == Control.LAYOUT_DIRECTION_RTL:
			sc.scroll_horizontal = int(sc.get_h_scroll_bar().max_value) if sc.get_h_scroll_bar() else 0
		else:
			sc.scroll_horizontal = 0


func _make_action(text: String, kind: String, style_kind: String) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.pressed.connect(func(): action.emit(kind, {}))
	b.set_meta("style_kind", style_kind)
	b.set_meta("kind", kind)
	return b


func _on_resize() -> void:
	var vp := get_viewport().get_visible_rect().size
	_d = ThemeX.density(vp)
	_single_row = bool(_d.get("single_card_row", true))
	var pad: float = float(_d.pad)
	var top_h: float = float(_d.top_h)
	var bottom_h: float = float(_d.bottom_h)
	var s: float = float(_d.scale)
	var gap: float = float(_d.get("gap", 6.0))
	_card_style = null

	var chip_h: float = float(_d.get("chip_h", 26.0))
	var top_pad := maxf(4.0, pad * 0.55)
	_top.offset_left = 4
	_top.offset_right = -4
	_top.offset_top = 4
	_top.offset_bottom = top_h
	_top.custom_minimum_size = Vector2.ZERO
	_top.clip_contents = true
	if _top_bg:
		_top_bg.add_theme_stylebox_override("panel", Assets.style_tex("panel_top.png", 0.0, 32.0 * minf(s, 1.6)))
	if _top_inner:
		_top_inner.add_theme_constant_override("margin_left", int(top_pad))
		_top_inner.add_theme_constant_override("margin_right", int(top_pad))
		_top_inner.add_theme_constant_override("margin_top", int(top_pad * 0.7))
		_top_inner.add_theme_constant_override("margin_bottom", int(top_pad * 0.7))
	Fonts.apply(_prompt, int(_d.font_title), true)
	_prompt.add_theme_color_override("font_color", ThemeX.CREAM)
	_prompt.add_theme_color_override("font_outline_color", ThemeX.WOOD_DARK)
	_prompt.add_theme_constant_override("outline_size", int(2 * minf(s, 1.6)))
	_prompt.custom_minimum_size = Vector2(0, chip_h)

	_claim_banner.add_theme_stylebox_override("panel", Assets.btn_tex("accent", 6.0 * minf(s, 1.6), "normal"))
	Fonts.apply(_claim_hint, int(_d.font_body), true)
	_claim_hint.add_theme_color_override("font_color", ThemeX.CREAM)
	_claim_hint.add_theme_color_override("font_outline_color", ThemeX.WOOD_DARK)
	_claim_hint.add_theme_constant_override("outline_size", int(2 * minf(s, 1.6)))

	var card_h: float = float(_d.card_h)
	var btn_h: float = float(_d.btn_h)
	var bot_pad := maxf(4.0, pad * 0.45)
	# Bottom height tracks content only — Control shell cannot inflate over the map.
	bottom_h = bot_pad * 2.0 + card_h * (1.0 if _single_row else 2.0) + btn_h + gap * (1.0 if _single_row else 2.0)
	_d["bottom_h"] = bottom_h
	_bottom.offset_left = 4
	_bottom.offset_right = -4
	_bottom.offset_top = -bottom_h - 4.0
	_bottom.offset_bottom = -4
	_bottom.custom_minimum_size = Vector2.ZERO
	_bottom.clip_contents = true
	if _bottom_bg:
		_bottom_bg.add_theme_stylebox_override("panel", Assets.style_tex("panel_fantasy.png", 0.0, 40.0 * minf(s, 1.6)))
	if _bottom_inner:
		_bottom_inner.add_theme_constant_override("margin_left", int(bot_pad))
		_bottom_inner.add_theme_constant_override("margin_right", int(bot_pad))
		_bottom_inner.add_theme_constant_override("margin_top", int(bot_pad))
		_bottom_inner.add_theme_constant_override("margin_bottom", int(bot_pad))
	if _bottom_col:
		_bottom_col.add_theme_constant_override("separation", int(maxi(2, int(round(gap)))))

	_face_wrap.visible = not _single_row
	_hand_wrap.visible = not _single_row
	_cards_scroll.visible = _single_row
	# Collapsed rows must not keep a minimum height (Godot can still reserve it).
	_face_scroll.custom_minimum_size = Vector2(0, card_h if not _single_row else 0.0)
	_hand_scroll.custom_minimum_size = Vector2(0, card_h if not _single_row else 0.0)
	_cards_scroll.custom_minimum_size = Vector2(0, card_h if _single_row else 0.0)
	_face_wrap.custom_minimum_size = Vector2(0, 0)
	_hand_wrap.custom_minimum_size = Vector2(0, 0)
	_btn_row.custom_minimum_size = Vector2(0, btn_h)
	for b in _buttons:
		var btn := b as Button
		btn.custom_minimum_size = Vector2(0, btn_h)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.clip_text = true
		btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var btn_font := mini(int(_d.font_btn), int(floor(btn_h * 0.42)))
		Fonts.apply(btn, maxi(12, btn_font), true)
		_style_btn(btn, str(btn.get_meta("style_kind")), s)

	var tw := minf(vp.x - 24.0, 400.0)
	var toast_h := clampf(float(_d.font_body) * 2.0 + 10.0 * minf(s, 1.6), 36.0, 52.0 * minf(s, 1.6))
	_toast_panel.offset_left = -tw / 2.0
	_toast_panel.offset_right = tw / 2.0
	_toast_panel.offset_top = -bottom_h - 8.0 - toast_h
	_toast_panel.offset_bottom = -bottom_h - 8.0
	_toast_panel.add_theme_stylebox_override("panel", Assets.style_tex("card_frame.png", 6.0 * minf(s, 1.6), 26.0 * minf(s, 1.6)))
	Fonts.apply(_toast, int(_d.font_body), true)

	var bw := minf(vp.x - 32.0, 320.0)
	var turn_h := clampf(float(_d.font_title) * 1.8 + 10.0 * minf(s, 1.6), 36.0, 52.0 * minf(s, 1.6))
	_turn_banner.offset_left = -bw / 2.0
	_turn_banner.offset_right = bw / 2.0
	_turn_banner.offset_top = top_h + 6.0
	_turn_banner.offset_bottom = top_h + 6.0 + turn_h
	_turn_banner.add_theme_stylebox_override("panel", Assets.btn_tex("accent", 6.0 * minf(s, 1.6)))
	Fonts.apply(_turn_label, int(_d.font_title), true)

	var modal_w := minf(vp.x - 20.0, 380.0)
	var modal_h := minf(vp.y * 0.42, 280.0)
	_modal.offset_left = -modal_w / 2.0
	_modal.offset_right = modal_w / 2.0
	_modal.offset_top = -modal_h / 2.0
	_modal.offset_bottom = modal_h / 2.0
	_modal.add_theme_stylebox_override("panel", Assets.style_tex("card_frame.png", 10.0 * minf(s, 1.6), 26.0 * minf(s, 1.6)))

	call_deferred("_fit_chrome_heights")
	if _last_rules != null:
		show_state(_last_rules, _last_human)


func _fit_chrome_heights() -> void:
	if _bottom == null or _top == null or _d.is_empty():
		return
	# Anchor-only lock: Control shells ignore child min-size, so parchment cannot cover Iran.
	var top_h: float = float(_d.get("top_h", 36.0))
	if _claim_banner != null and _claim_banner.visible:
		top_h += maxf(28.0, float(_d.get("chip_h", 26.0)) + 8.0)
	_d["top_h"] = top_h
	_top.custom_minimum_size = Vector2.ZERO
	_top.offset_left = 4
	_top.offset_right = -4
	_top.offset_top = 4
	_top.offset_bottom = top_h
	_top.clip_contents = true

	var pad: float = maxf(4.0, float(_d.get("pad", 4.0)) * 0.45)
	var gap: float = float(_d.get("gap", 3.0))
	var card_h: float = float(_d.card_h)
	var btn_h: float = float(_d.btn_h)
	var rows := 1.0 if _single_row else 2.0
	var bottom_h: float = pad * 2.0 + card_h * rows + btn_h + gap * rows
	# Hard cap so a long hand never eats the board.
	var vp_h := get_viewport().get_visible_rect().size.y
	bottom_h = minf(bottom_h, vp_h * 0.34)
	_d["bottom_h"] = bottom_h
	_bottom.custom_minimum_size = Vector2.ZERO
	_bottom.offset_left = 4
	_bottom.offset_right = -4
	_bottom.offset_top = -bottom_h - 4.0
	_bottom.offset_bottom = -4
	_bottom.clip_contents = true
	if _single_row and _cards_scroll:
		_cards_scroll.custom_minimum_size = Vector2(0, card_h)
	elif not _single_row:
		if _face_scroll:
			_face_scroll.custom_minimum_size = Vector2(0, card_h)
		if _hand_scroll:
			_hand_scroll.custom_minimum_size = Vector2(0, card_h)


func _style_btn(btn: Button, kind: String, s: float) -> void:
	var btn_h := maxf(btn.custom_minimum_size.y, float(_d.get("btn_h", 44.0)))
	# Keep stylebox margins inside the locked button height so text can stay large.
	var pad := clampf(6.0 * minf(s, 1.4), 5.0, maxf(5.0, btn_h * 0.12))
	btn.add_theme_stylebox_override("normal", Assets.btn_tex(kind, pad, "normal"))
	btn.add_theme_stylebox_override("hover", Assets.btn_tex(kind, pad, "hover"))
	btn.add_theme_stylebox_override("pressed", Assets.btn_tex(kind, pad, "pressed"))
	btn.add_theme_stylebox_override("disabled", Assets.btn_tex(kind, pad, "disabled"))
	btn.add_theme_color_override("font_color", ThemeX.CREAM)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.85))
	btn.add_theme_color_override("font_pressed_color", ThemeX.GOLD_SOFT)
	btn.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.35))
	btn.add_theme_color_override("font_outline_color", Color(0.14, 0.06, 0.02, 0.9))
	btn.add_theme_constant_override("outline_size", int(maxi(2, int(round(2.2 * minf(s, 1.8))))))


func _refresh_labels() -> void:
	if _buttons.size() >= 3:
		(_buttons[0] as Button).text = _short(_t("draw_cards", "برداشت کارت"), "برداشت")
		(_buttons[1] as Button).text = _short(_t("claim_route", "ساخت مسیر"), "ساخت مسیر")
		(_buttons[2] as Button).text = _short(_t("draw_tickets", "قرارداد مقصد"), "قرارداد")


func _short(full: String, fallback: String) -> String:
	if bool(_d.get("compact", true)) and full.length() > 12:
		return fallback
	return full


func set_claim_mode(on: bool) -> void:
	_claim_banner.visible = on
	_claim_hint.text = _t("claim_hint", "یک مسیر آزاد لمس کن")


func action_rect(kind: String) -> Rect2:
	for b in _buttons:
		var btn := b as Button
		if btn and str(btn.get_meta("kind", "")) == kind:
			return btn.get_global_rect()
	return Rect2()


func cards_rect() -> Rect2:
	if _single_row and _cards_scroll:
		return _cards_scroll.get_global_rect()
	if _hand_scroll and _hand_scroll.visible:
		return _hand_scroll.get_global_rect()
	if _cards_scroll:
		return _cards_scroll.get_global_rect()
	return Rect2()


func pulse_action(kind: String, on: bool) -> void:
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null
	for b in _buttons:
		var btn := b as Button
		if btn == null:
			continue
		btn.pivot_offset = btn.size * 0.5
		btn.scale = Vector2.ONE
		btn.modulate = Color.WHITE
	_pulse_kind = kind if on else ""
	if not on or kind.is_empty():
		return
	var target: Button = null
	for b in _buttons:
		var btn := b as Button
		if btn and str(btn.get_meta("kind", "")) == kind:
			target = btn
			break
	if target == null:
		return
	target.pivot_offset = target.size * 0.5
	_pulse_tween = create_tween().set_loops()
	_pulse_tween.tween_property(target, "scale", Vector2(1.06, 1.06), 0.45).set_trans(Tween.TRANS_SINE)
	_pulse_tween.parallel().tween_property(target, "modulate", Color(1.15, 1.08, 0.9), 0.45)
	_pulse_tween.tween_property(target, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_SINE)
	_pulse_tween.parallel().tween_property(target, "modulate", Color.WHITE, 0.45)


func flash_turn(text: String) -> void:
	_turn_label.text = text
	_turn_banner.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.0)
	tw.tween_property(_turn_banner, "modulate:a", 0.0, 0.4)


func show_state(rules, human_turn: bool) -> void:
	var turn_changed := _last_human != human_turn
	_last_rules = rules
	_last_human = human_turn
	if _d.is_empty():
		_d = ThemeX.density(get_viewport().get_visible_rect().size)
		_single_row = bool(_d.get("single_card_row", true))
	var prompt := _t("your_turn") if human_turn and not rules.over else (_t("game_over") if rules.over else _t("ai_turn"))
	# Shorter prompt on narrow phones.
	if bool(_d.get("compact", true)) and human_turn and not rules.over:
		prompt = "نوبت تو — کارت بردار یا مسیر بساز"
	elif bool(_d.get("compact", true)) and not human_turn and not rules.over:
		prompt = "نوبت حریف…"
	_prompt.text = prompt
	if turn_changed and not rules.over:
		flash_turn(prompt)
	for c in _scores.get_children():
		c.queue_free()
	for i in range(rules.players.size()):
		_scores.add_child(_player_chip(rules.players[i], i == rules.current and not rules.over))
	if _single_row:
		_paint_merged(rules.face_up, rules.players[0].hand)
	else:
		_paint_cards(_face, rules.face_up, false)
		_paint_cards(_hand, rules.players[0].hand, false)
	for b in _buttons:
		(b as Button).disabled = (not human_turn) or rules.over
	call_deferred("_fit_chrome_heights")


func _player_chip(p: Dictionary, active: bool) -> PanelContainer:
	var chip := PanelContainer.new()
	var col := Color(str(p.color))
	var st := StyleBoxFlat.new()
	st.bg_color = Color(col.r, col.g, col.b, 0.95).darkened(0.08)
	st.set_corner_radius_all(999)
	st.content_margin_left = 7
	st.content_margin_right = 8
	st.content_margin_top = 3
	st.content_margin_bottom = 3
	st.border_color = ThemeX.GOLD_SOFT if active else Color(1, 1, 1, 0.2)
	st.set_border_width_all(2 if active else 1)
	chip.add_theme_stylebox_override("panel", st)
	chip.custom_minimum_size = Vector2(0, float(_d.get("chip_h", 26)))
	var lab := Label.new()
	lab.text = "%s %d｜%d" % [str(p.name), int(p.score), int(p.wagons)]
	Fonts.apply(lab, int(_d.get("font_chip", 12)), true)
	lab.add_theme_color_override("font_color", Color.WHITE)
	chip.add_child(lab)
	return chip


func _paint_merged(face: Array, hand: Array) -> void:
	for c in _cards.get_children():
		c.queue_free()
	_cards.add_child(_rail_label("میز"))
	_paint_cards(_cards, face, true)
	_cards.add_child(_rail_label("دست"))
	_paint_cards(_cards, hand, true)
	call_deferred("_snap_card_scrolls")


func _rail_label(text: String) -> Control:
	var h: float = float(_d.get("card_h", 70))
	var shell := Control.new()
	shell.custom_minimum_size = Vector2(maxf(36.0, float(_d.get("font_chip", 12)) * 2.4), h)
	shell.size = shell.custom_minimum_size
	shell.clip_contents = true
	shell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	shell.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel", ThemeX.panel(Color(1, 1, 1, 0.08), 14.0, 4.0, Color(1, 1, 1, 0.12), false))
	shell.add_child(bg)
	var lab := Label.new()
	lab.set_anchors_preset(Control.PRESET_FULL_RECT)
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Fonts.apply(lab, int(_d.get("font_chip", 12)), true)
	lab.add_theme_color_override("font_color", ThemeX.GOLD_SOFT)
	shell.add_child(lab)
	return shell


func _paint_cards(box: HBoxContainer, cards: Array, append: bool) -> void:
	if not append:
		for c in box.get_children():
			c.queue_free()
	var counts := {}
	for c in cards:
		counts[c] = int(counts.get(c, 0)) + 1
	var order := ["locomotive", "red", "blue", "green", "yellow", "orange", "purple", "black", "white"]
	var keys: Array = []
	for k in order:
		if counts.has(k):
			keys.append(k)
	for k in counts.keys():
		if not keys.has(k):
			keys.append(k)
	for k in keys:
		box.add_child(_train_card(str(k), int(counts[k])))
	if not append:
		call_deferred("_snap_card_scrolls")


func _shared_card_style() -> StyleBoxTexture:
	if _card_style != null:
		return _card_style
	var s: float = float(_d.get("scale", 1.0))
	_card_style = Assets.style_tex("card_frame.png", 0.0, 26.0 * minf(s, 1.4))
	return _card_style


func _train_card(color_key: String, n: int) -> Control:
	var w: float = float(_d.get("card_w", 56))
	var h: float = float(_d.get("card_h", 70))
	var col: Color = ThemeX.ROUTE.get(color_key, Color("7f8c8d"))
	var dark := color_key == "white" or color_key == "yellow"
	# Fixed-size Control shell — labels cannot inflate chrome over the map.
	var chip := Control.new()
	chip.custom_minimum_size = Vector2(w, h)
	chip.size = Vector2(w, h)
	chip.clip_contents = true
	chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_PASS
	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel", _shared_card_style())
	chip.add_child(bg)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 3
	v.offset_right = -3
	v.offset_top = 3
	v.offset_bottom = -3
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(v)
	var band_h := maxf(10.0, h * 0.28)
	var band := ColorRect.new()
	band.color = col
	band.custom_minimum_size = Vector2(0, band_h)
	band.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(band)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 0)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(inner)
	var body_budget := maxf(16.0, h - band_h - 10.0)
	var font_card := mini(int(_d.get("font_card", 12)), int(floor(body_budget * 0.38)))
	font_card = maxi(10, font_card)
	var name_l := Label.new()
	name_l.text = _card_name(color_key)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.clip_text = true
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Fonts.apply(name_l, font_card, true)
	name_l.add_theme_color_override("font_color", ThemeX.INK)
	inner.add_child(name_l)
	var count_l := Label.new()
	count_l.text = "×%d" % n
	count_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	count_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Fonts.apply(count_l, font_card, true)
	count_l.add_theme_color_override("font_color", ThemeX.TEAL_DEEP if not dark else ThemeX.INK)
	inner.add_child(count_l)
	return chip


func _card_name(c: String) -> String:
	match c:
		"red": return "قرمز"
		"blue": return "آبی"
		"green": return "سبز"
		"yellow": return "زرد"
		"black": return "مشکی"
		"white": return "سفید"
		"orange": return "نارنجی"
		"purple": return "بنفش"
		"locomotive": return "لوکو"
		_: return c


func toast(msg: String) -> void:
	_toast.text = msg.replace("🚂", "").replace("🙂", "").strip_edges()
	_toast_panel.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.4)
	tw.tween_property(_toast_panel, "modulate:a", 0.0, 0.5)


func show_result(res: Dictionary) -> void:
	_dim.visible = true
	_modal.visible = true
	for c in _modal_body.get_children():
		c.queue_free()
	var title := Label.new()
	var outcome := str(res.get("outcome", "draw"))
	title.text = _t("you_won") if outcome == "win" else (_t("you_lost") if outcome == "loss" else _t("draw"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var font_title := int(_d.get("font_title", 18))
	var font_body := int(_d.get("font_body", 15))
	var font_btn := int(_d.get("font_btn", 16))
	var btn_h := float(_d.get("btn_h", 52.0))
	Fonts.apply(title, maxi(18, font_title + 2), true)
	title.add_theme_color_override("font_color", ThemeX.TEAL_DEEP)
	_modal_body.add_child(title)
	var sc := Label.new()
	sc.text = "تو %d  —  حریف %d" % [int(res.get("score", 0)), int(res.get("ai_score", 0))]
	sc.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Fonts.apply(sc, maxi(15, font_body), true)
	sc.add_theme_color_override("font_color", ThemeX.INK)
	_modal_body.add_child(sc)
	var again := Button.new()
	again.text = "یه دست دیگه"
	again.custom_minimum_size = Vector2(0, maxf(52.0, btn_h))
	Fonts.apply(again, maxi(16, font_btn), true)
	_style_btn(again, "primary", float(_d.get("scale", 1.0)))
	again.pressed.connect(func(): action.emit("restart", {}))
	_modal_body.add_child(again)


func hide_modal() -> void:
	_modal.visible = false
	_dim.visible = false
