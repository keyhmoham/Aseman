## Interactive first-run coach — learn-by-doing on the live board.
## Soft spotlight rings + a coach card; no wall of rules text.
extends CanvasLayer

signal finished(skipped: bool)
signal practice_claim(on: bool)

const Fonts = preload("res://arena/persian_rails/fonts.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")
const Assets = preload("res://arena/persian_rails/assets.gd")
const CFG_PATH := "user://persian_rails.cfg"
const CFG_KEY := "tutorial_v1_done"

var fa: Dictionary = {}
var active := false
var step_i := 0
var _hud = null
var _root: Control
var _veil = null
var _ring: Control
var _pulse: Control
var _shell: Control
var _card: PanelContainer
var _col: VBoxContainer
var _rail: HBoxContainer
var _btn_row: BoxContainer
var _eyebrow: Label
var _title: Label
var _body: Label
var _hint: Label
var _cta: Button
var _skip: Button
var _dots: Array = []
var _ring_tween: Tween
var _pulse_tween: Tween
var _awaiting := ""
var _pan_accum := 0.0
var _d: Dictionary = {}
var _phone := true


static func was_completed() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return false
	return bool(cfg.get_value("coach", CFG_KEY, false))


static func mark_completed() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("coach", CFG_KEY, true)
	cfg.save(CFG_PATH)


static func clear_completed() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("coach", CFG_KEY, false)
	cfg.save(CFG_PATH)


func _ready() -> void:
	layer = 40
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.layout_direction = Control.LAYOUT_DIRECTION_RTL
	add_child(_root)
	get_viewport().size_changed.connect(_layout)

	# Veil intentionally omitted — a dim overlay made the Iran map look covered.
	_veil = null

	_ring = Control.new()
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.visible = false
	_root.add_child(_ring)
	_ring.draw.connect(_draw_ring)

	_pulse = Control.new()
	_pulse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pulse.visible = false
	_root.add_child(_pulse)
	_pulse.draw.connect(_draw_pulse)

	# Fixed outer shell so big mobile fonts/buttons cannot push the card off-screen.
	_shell = Control.new()
	_shell.mouse_filter = Control.MOUSE_FILTER_STOP
	_shell.clip_contents = true
	_shell.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.add_child(_shell)
	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.clip_contents = true
	_card.set_anchors_preset(Control.PRESET_FULL_RECT)
	_card.offset_left = 0
	_card.offset_top = 0
	_card.offset_right = 0
	_card.offset_bottom = 0
	_shell.add_child(_card)
	_col = VBoxContainer.new()
	_col.add_theme_constant_override("separation", 10)
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_card.add_child(_col)

	_rail = HBoxContainer.new()
	_rail.alignment = BoxContainer.ALIGNMENT_CENTER
	_rail.add_theme_constant_override("separation", 6)
	_col.add_child(_rail)

	_eyebrow = Label.new()
	_eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_eyebrow.add_theme_color_override("font_color", ThemeX.GOLD_SOFT)
	_col.add_child(_eyebrow)

	_title = Label.new()
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_title.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_title.add_theme_color_override("font_color", ThemeX.INK)
	_col.add_child(_title)

	_body = Label.new()
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_color_override("font_color", ThemeX.TEAL_DEEP)
	_col.add_child(_body)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.add_theme_color_override("font_color", ThemeX.CLAY)
	_col.add_child(_hint)

	_btn_row = VBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", 10)
	_btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_col.add_child(_btn_row)

	_cta = Button.new()
	_cta.focus_mode = Control.FOCUS_NONE
	_cta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cta.pressed.connect(_on_cta)
	_btn_row.add_child(_cta)

	_skip = Button.new()
	_skip.focus_mode = Control.FOCUS_NONE
	_skip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skip.pressed.connect(_on_skip)
	_btn_row.add_child(_skip)


func set_strings(p_fa: Dictionary) -> void:
	fa = p_fa


func bind_hud(hud) -> void:
	_hud = hud


func _t(key: String, fallback: String = "") -> String:
	return str(fa.get(key, fallback if fallback else key)).replace("🙂", "").replace("🚂", "").strip_edges()


func steps() -> Array:
	return [
		{
			"id": "welcome",
			"kind": "info",
			"eyebrow": _t("tut_eyebrow_welcome", "ایستگاه اول"),
			"title": _t("tut_welcome_title", "سلام! شبکه ریلی‌ات اینجاست"),
			"body": _t("tut_welcome_body", "تو سه کار داری: کارت بردار، مسیر بساز، یا قرارداد مقصد بگیر. با هم یه دور کوتاه تمرین می‌کنیم."),
			"hint": _t("tut_welcome_hint", "کمتر از یک دقیقه — بعدش خودتی"),
			"cta": _t("tut_start", "بزن بریم"),
			"spotlight": "",
		},
		{
			"id": "map",
			"kind": "pan",
			"eyebrow": _t("tut_eyebrow_map", "نقشه ایران"),
			"title": _t("tut_map_title", "نقشه رو بکش و بچرخون"),
			"body": _t("tut_map_body", "با انگشت یا ماوس نقشه رو جابه‌جا کن تا شهرها و مسیرها رو ببینی. چرخ ماوس هم زوم می‌کنه."),
			"hint": _t("tut_map_hint", "یک بار نقشه رو بکش تا بریم مرحله بعد"),
			"cta": "",
			"spotlight": "map",
		},
		{
			"id": "hand",
			"kind": "info",
			"eyebrow": _t("tut_eyebrow_hand", "کارت‌های رنگی"),
			"title": _t("tut_hand_title", "این دست کارت‌های توئه"),
			"body": _t("tut_hand_body", "هر رنگ برای ساخت مسیر هم‌رنگه. لوکوموتیو مثل کارت همه‌کاره عمل می‌کنه."),
			"hint": _t("tut_hand_hint", "بالای دکمه‌ها، ردیف کارت‌ها رو ببین"),
			"cta": _t("tut_next", "فهمیدم"),
			"spotlight": "hand",
		},
		{
			"id": "draw",
			"kind": "tap_action",
			"action": "draw_trains",
			"eyebrow": _t("tut_eyebrow_draw", "اقدام ۱"),
			"title": _t("tut_draw_title", "برداشت کارت رو لمس کن"),
			"body": _t("tut_draw_body", "وقتی کارت کم داری، از این دکمه کارت جدید برمی‌داری. همین الان لمسش کن."),
			"hint": _t("tut_draw_hint", "دکمهٔ فیروزه‌ای «برداشت» رو بزن"),
			"cta": "",
			"spotlight": "draw_trains",
		},
		{
			"id": "claim",
			"kind": "tap_action",
			"action": "claim_mode",
			"eyebrow": _t("tut_eyebrow_claim", "اقدام ۲"),
			"title": _t("tut_claim_title", "حالا ساخت مسیر"),
			"body": _t("tut_claim_body", "با کارت‌های هم‌رنگ می‌تونی یه مسیر آزاد بسازی و امتیاز بگیری. دکمهٔ ساخت مسیر رو بزن."),
			"hint": _t("tut_claim_hint", "دکمهٔ نارنجی «ساخت مسیر» رو بزن"),
			"cta": "",
			"spotlight": "claim_mode",
		},
		{
			"id": "route",
			"kind": "tap_route",
			"eyebrow": _t("tut_eyebrow_route", "لمس مسیر"),
			"title": _t("tut_route_title", "یه مسیر آزاد روی نقشه لمس کن"),
			"body": _t("tut_route_body", "مسیرهای درخشان آماده‌ان. یکی رو انتخاب کن — فقط تمرین می‌کنیم، هنوز واگنی کسر نمی‌شه."),
			"hint": _t("tut_route_hint", "هر مسیر آزادی رو روی نقشه لمس کن"),
			"cta": "",
			"spotlight": "map",
		},
		{
			"id": "tickets",
			"kind": "info",
			"eyebrow": _t("tut_eyebrow_tickets", "اقدام ۳"),
			"title": _t("tut_tickets_title", "قرارداد مقصد"),
			"body": _t("tut_tickets_body", "قرارداد دو شهر رو به هم وصل می‌کنه. اگر وصلشون کنی امتیاز مثبت می‌گیری؛ اگر تموم بشه و وصل نکرده باشی منفی می‌شه."),
			"hint": _t("tut_tickets_hint", "بعداً با دکمهٔ «قرارداد» می‌تونی بیشتر بگیری"),
			"cta": _t("tut_next", "فهمیدم"),
			"spotlight": "draw_tickets",
		},
		{
			"id": "ready",
			"kind": "info",
			"eyebrow": _t("tut_eyebrow_ready", "آماده"),
			"title": _t("tut_ready_title", "حالا نوبت واقعیه"),
			"body": _t("tut_ready_body", "هر نوبت فقط یکی از سه کار رو انجام بده. شهرهای ایران رو به هم وصل کن و از حریف جلو بزن!"),
			"hint": _t("tut_ready_hint", "موفق باشی — شبکه ریلی‌ات منتظرته"),
			"cta": _t("play", "بزن بریم"),
			"spotlight": "",
		},
	]


func begin() -> void:
	active = true
	step_i = 0
	_pan_accum = 0.0
	visible = true
	if _shell:
		_shell.modulate.a = 1.0
		_shell.scale = Vector2.ONE
	_build_dots()
	_show_step()
	_layout()
	# Defer one frame so viewport size / HUD chrome are settled (avoids 0×0 card).
	call_deferred("_layout")
	call_deferred("_play_enter")


func _play_enter() -> void:
	if not active or _shell == null:
		return
	_layout()
	_shell.modulate.a = 0.0
	_shell.scale = Vector2(0.96, 0.96)
	_shell.pivot_offset = _shell.size * 0.5
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_shell, "modulate:a", 1.0, 0.28).set_ease(Tween.EASE_OUT)
	tw.tween_property(_shell, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func is_blocking() -> bool:
	return active


func current_kind() -> String:
	return str(_cur().get("kind", ""))


func wants_action(kind: String) -> bool:
	if not active:
		return false
	var s: Dictionary = _cur()
	return str(s.get("kind", "")) == "tap_action" and str(s.get("action", "")) == kind


func notify_action(kind: String) -> bool:
	if not active:
		return false
	var s: Dictionary = _cur()
	if str(s.get("kind", "")) != "tap_action":
		return false
	if str(s.get("action", "")) != kind:
		return false
	if kind == "claim_mode":
		practice_claim.emit(true)
	_advance()
	return true


func notify_route(_route_id: String) -> bool:
	if not active:
		return false
	if str(_cur().get("kind", "")) != "tap_route":
		return false
	practice_claim.emit(false)
	_advance()
	return true


func notify_pan(amount: float) -> void:
	if not active:
		return
	if str(_cur().get("kind", "")) != "pan":
		return
	_pan_accum += absf(amount)
	if _pan_accum >= 28.0:
		_advance()


func notify_zoom() -> void:
	if not active:
		return
	if str(_cur().get("kind", "")) == "pan" and _pan_accum < 28.0:
		_pan_accum = 28.0
		_advance()


func _cur() -> Dictionary:
	var list := steps()
	if step_i < 0 or step_i >= list.size():
		return {}
	return list[step_i]


func _build_dots() -> void:
	for c in _rail.get_children():
		c.queue_free()
	_dots.clear()
	var n := steps().size()
	var s: float = clampf(float(_d.get("scale", 1.0)) if not _d.is_empty() else 1.0, 0.9, 2.4)
	var seg_w := 22.0 * s if _phone else 18.0 * s
	var seg_h := 7.0 * s if _phone else 5.0 * s
	_rail.add_theme_constant_override("separation", int(maxi(4, int(round(6.0 * s)))))
	for i in range(n):
		var seg := ColorRect.new()
		seg.custom_minimum_size = Vector2(seg_w, seg_h)
		seg.color = ThemeX.GOLD_SOFT if i == 0 else Color(ThemeX.INK.r, ThemeX.INK.g, ThemeX.INK.b, 0.18)
		_rail.add_child(seg)
		_dots.append(seg)


func _show_step() -> void:
	var s: Dictionary = _cur()
	if s.is_empty():
		_finish(false)
		return
	_awaiting = str(s.get("kind", "info"))
	_eyebrow.text = str(s.get("eyebrow", ""))
	_title.text = str(s.get("title", ""))
	_body.text = str(s.get("body", ""))
	_hint.text = str(s.get("hint", ""))
	var cta := str(s.get("cta", ""))
	_cta.visible = not cta.is_empty()
	_cta.text = cta if not cta.is_empty() else ""
	_skip.text = _t("tut_skip", "رد کردن آموزش")
	_skip.visible = step_i < steps().size() - 1
	for i in range(_dots.size()):
		(_dots[i] as ColorRect).color = ThemeX.TEAL if i < step_i else (ThemeX.GOLD_SOFT if i == step_i else Color(ThemeX.INK.r, ThemeX.INK.g, ThemeX.INK.b, 0.16))
	_update_spotlight(str(s.get("spotlight", "")))
	if _shell:
		_shell.modulate.a = 0.82
		var tw := create_tween()
		tw.tween_property(_shell, "modulate:a", 1.0, 0.18)


func _update_spotlight(kind: String) -> void:
	_stop_spot_tweens()
	_ring.visible = false
	_pulse.visible = false
	if kind.is_empty() or _hud == null:
		return
	var rect := _target_rect(kind)
	if rect.size.x < 4.0 or rect.size.y < 4.0:
		return
	var pad := 14.0
	var r := Rect2(rect.position - Vector2(pad, pad), rect.size + Vector2(pad * 2.0, pad * 2.0))
	_ring.visible = true
	_ring.position = r.position
	_ring.size = r.size
	_ring.queue_redraw()
	_pulse.visible = true
	_pulse.position = r.position
	_pulse.size = r.size
	_pulse.modulate.a = 1.0
	_pulse.queue_redraw()
	_ring_tween = create_tween().set_loops()
	_ring_tween.tween_property(_ring, "modulate:a", 0.45, 0.7).set_ease(Tween.EASE_IN_OUT)
	_ring_tween.tween_property(_ring, "modulate:a", 1.0, 0.7).set_ease(Tween.EASE_IN_OUT)
	_pulse_tween = create_tween().set_loops()
	_pulse.scale = Vector2.ONE
	_pulse.pivot_offset = _pulse.size * 0.5
	_pulse_tween.tween_property(_pulse, "scale", Vector2(1.08, 1.08), 0.85).set_trans(Tween.TRANS_SINE)
	_pulse_tween.parallel().tween_property(_pulse, "modulate:a", 0.15, 0.85)
	_pulse_tween.tween_property(_pulse, "scale", Vector2.ONE, 0.01)
	_pulse_tween.parallel().tween_property(_pulse, "modulate:a", 0.9, 0.01)
	if _hud.has_method("pulse_action") and (kind == "draw_trains" or kind == "claim_mode" or kind == "draw_tickets"):
		_hud.pulse_action(kind, true)


func _target_rect(kind: String) -> Rect2:
	if _hud == null:
		return Rect2()
	match kind:
		"hand":
			if _hud.has_method("cards_rect"):
				return _hud.cards_rect()
		"map":
			var vp := get_viewport().get_visible_rect()
			var insets: Vector2 = _hud.chrome_insets() if _hud.has_method("chrome_insets") else Vector2(80, 160)
			return Rect2(vp.position.x + 24.0, vp.position.y + insets.x, vp.size.x - 48.0, maxf(120.0, vp.size.y - insets.x - insets.y - 20.0))
		_:
			if _hud.has_method("action_rect"):
				return _hud.action_rect(kind)
	return Rect2()


func _draw_ring() -> void:
	var r := Rect2(Vector2.ZERO, _ring.size)
	_ring.draw_rect(r, Color(ThemeX.GOLD_SOFT.r, ThemeX.GOLD_SOFT.g, ThemeX.GOLD_SOFT.b, 0.0), false, 0.0)
	# Soft gold frame
	var c := ThemeX.GOLD_SOFT
	_ring.draw_rect(r.grow(-1.0), Color(c.r, c.g, c.b, 0.9), false, 3.0)
	_ring.draw_rect(r.grow(4.0), Color(c.r, c.g, c.b, 0.35), false, 2.0)


func _draw_pulse() -> void:
	var r := Rect2(Vector2.ZERO, _pulse.size).grow(8.0)
	_pulse.draw_rect(r, Color(ThemeX.TEAL_BRIGHT.r, ThemeX.TEAL_BRIGHT.g, ThemeX.TEAL_BRIGHT.b, 0.22), false, 2.5)


func _stop_spot_tweens() -> void:
	if _ring_tween:
		_ring_tween.kill()
		_ring_tween = null
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null
	if _hud and _hud.has_method("pulse_action"):
		_hud.pulse_action("", false)


func _map_focus_step() -> bool:
	## Steps where the Iran board must stay mostly visible (pan / tap route).
	if not active:
		return false
	var s: Dictionary = _cur()
	var kind := str(s.get("kind", ""))
	return kind == "pan" or kind == "tap_route" or str(s.get("spotlight", "")) == "map"


func _enforce_shell_size(card_w: float, card_h: float, x: float, y: float) -> void:
	if _shell == null or not active:
		return
	if not _map_focus_step():
		return
	_shell.position = Vector2(x, y)
	_shell.size = Vector2(card_w, card_h)
	_shell.custom_minimum_size = Vector2(card_w, card_h)
	_shell.offset_left = x
	_shell.offset_top = y
	_shell.offset_right = x + card_w
	_shell.offset_bottom = y + card_h


func _layout() -> void:
	if _shell == null or _card == null:
		return
	var vp := get_viewport().get_visible_rect().size
	if vp.x < 32.0 or vp.y < 32.0:
		return
	_d = ThemeX.density(vp)
	# Match HUD density so the coach is as big as the rest of the mobile UI.
	var s: float = float(_d.get("scale", 1.0))
	_phone = bool(_d.get("phone", true)) or bool(_d.get("compact", true))
	var map_focus := _map_focus_step()
	var margin := (8.0 if _phone else 24.0) * minf(s, 1.8)
	# Phones: nearly full-bleed. Tablets/desktop: capped readable width.
	var card_w: float
	if _phone:
		card_w = vp.x - margin * 2.0
	else:
		card_w = minf(vp.x - margin * 2.0, 560.0 * minf(s, 1.6))
	var top_h := float(_d.get("top_h", 80.0))
	var bot_h := float(_d.get("bottom_h", 160.0))
	var free_top := top_h + 6.0 * s
	var free_bot := vp.y - bot_h - 6.0 * s
	if free_bot <= free_top + 140.0 * s:
		free_top = vp.y * 0.10
		free_bot = vp.y * 0.80
	var free_h := maxf(160.0, free_bot - free_top)
	# Map-focus steps: slim dock so the board stays readable/tappable.
	# Other steps: large coach card, but never eat the whole free band.
	var card_h: float
	if map_focus:
		# Slim tip dock — tall CTA/skip buttons were expanding over the Iran board
		# after a frame (looked like the map "disappeared").
		card_h = clampf(128.0 * minf(s, 1.6), 108.0, minf(free_h * 0.28, vp.y * 0.22))
		_body.visible = false
		_rail.visible = false
		_eyebrow.visible = false
		_btn_row.visible = true
	elif _phone:
		card_h = clampf(free_h * 0.72, minf(220.0 * s, free_h), free_h)
		card_h = minf(card_h, vp.y * 0.48)
		_body.visible = true
		_rail.visible = true
		_eyebrow.visible = true
		_btn_row.visible = true
	else:
		card_h = clampf(free_h * 0.64, minf(220.0 * s, free_h), minf(360.0 * minf(s, 1.6), free_h))
		_body.visible = true
		_rail.visible = true
		_eyebrow.visible = true
		_btn_row.visible = true
	card_h = minf(card_h, free_h)
	var x := (vp.x - card_w) * 0.5
	# Dock map-focus coach under the top chrome; otherwise float in the free band.
	var y: float
	if map_focus:
		y = free_top + 4.0 * s
	else:
		y = free_top + maxf(0.0, (free_h - card_h) * 0.22)
	y = clampf(y, 4.0, maxf(4.0, vp.y - card_h - 4.0))

	var pad := ((10.0 if map_focus else 20.0) if _phone else 16.0) * minf(s, 2.0)
	var radius := (24.0 if _phone else 22.0) * minf(s, 1.8)
	var flat := ThemeX.panel(ThemeX.PARCHMENT, radius, pad, ThemeX.GOLD, true)
	flat.bg_color = Color(ThemeX.PARCHMENT.r, ThemeX.PARCHMENT.g, ThemeX.PARCHMENT.b, 0.94 if map_focus else 1.0)
	flat.border_color = ThemeX.GOLD
	flat.set_border_width_all(maxi(2, int(round(2.5 * minf(s, 1.8)))))
	flat.content_margin_left = pad
	flat.content_margin_right = pad
	flat.content_margin_top = pad * (0.65 if map_focus else 1.0)
	flat.content_margin_bottom = pad * (0.65 if map_focus else 1.0)
	_card.add_theme_stylebox_override("panel", flat)

	# One step larger than HUD chrome so the coach reads as the focus.
	var font_chip := int(maxi(13, int(_d.get("font_chip", 12)) + (2 if _phone else 1)))
	var font_body := int(maxi(15, int(_d.get("font_body", 13)) + (4 if _phone else 2)))
	var font_title := int(maxi(17, int(_d.get("font_title", 15)) + ((2 if map_focus else 8) if _phone else 4)))
	var font_btn := int(maxi(15, int(_d.get("font_btn", 13)) + (3 if _phone else 1)))
	Fonts.apply(_eyebrow, font_chip, true)
	Fonts.apply(_title, font_title, true)
	Fonts.apply(_body, font_body, false)
	Fonts.apply(_hint, font_chip, true)
	Fonts.apply(_cta, font_btn, true)
	Fonts.apply(_skip, font_btn, true)
	_eyebrow.add_theme_color_override("font_color", ThemeX.GOLD)
	_title.add_theme_color_override("font_color", ThemeX.INK)
	_body.add_theme_color_override("font_color", ThemeX.TEAL_DEEP)
	_hint.add_theme_color_override("font_color", ThemeX.CLAY)
	_title.max_lines_visible = 2 if map_focus else -1
	_hint.max_lines_visible = 2 if map_focus else -1
	_title.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_hint.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL if not map_focus else Control.SIZE_SHRINK_BEGIN

	_col.add_theme_constant_override("separation", int(maxi(4, int(round((6.0 if map_focus else (14.0 if _phone else 10.0)) * minf(s, 1.8))))))
	_btn_row.add_theme_constant_override("separation", int(maxi(8, int(round(12.0 * minf(s, 1.8))))))
	# Keep CTA out of the way on map-focus — actions happen on the board.
	# A compact text skip stays so players are never trapped on the pan/route step.
	if map_focus:
		_cta.visible = false
		_skip.visible = step_i < steps().size() - 1
		_skip.custom_minimum_size = Vector2(0, 34.0 * minf(s, 1.5))
		Fonts.apply(_skip, int(maxi(12, font_chip - 1)), true)
		_skip.add_theme_stylebox_override("normal", ThemeX.panel(Color(1, 1, 1, 0.08), 18.0, 6.0, Color(1, 1, 1, 0.1), false))
		_skip.add_theme_stylebox_override("hover", ThemeX.panel(Color(1, 1, 1, 0.14), 18.0, 6.0, Color(1, 1, 1, 0.14), false))
		_skip.add_theme_stylebox_override("pressed", ThemeX.panel(Color(1, 1, 1, 0.18), 18.0, 6.0, Color(1, 1, 1, 0.16), false))
		_skip.add_theme_color_override("font_color", ThemeX.TEAL_DEEP)
	else:
		_style_btn(_cta, "primary", s)
		_style_btn(_skip, "secondary", s)
		_cta.visible = not str(_cur().get("cta", "")).is_empty()
		_skip.visible = step_i < steps().size() - 1

	_shell.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_shell.offset_left = x
	_shell.offset_top = y
	_shell.offset_right = x + card_w
	_shell.offset_bottom = y + card_h
	_shell.position = Vector2(x, y)
	_shell.size = Vector2(card_w, card_h)
	# Floor AND ceiling: custom min size alone can still grow from content.
	_shell.custom_minimum_size = Vector2(card_w, card_h)
	_shell.clip_contents = true
	_card.clip_contents = true
	_shell.pivot_offset = Vector2(card_w * 0.5, card_h * 0.5)
	var text_w := maxf(120.0, card_w - pad * 2.0)
	for lab in [_eyebrow, _title, _body, _hint]:
		(lab as Label).custom_minimum_size = Vector2(text_w, 0)
		(lab as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if active and _dots.is_empty():
		_build_dots()
	elif active:
		var seg_w := (26.0 if _phone else 18.0) * minf(s, 2.0)
		var seg_h := (9.0 if _phone else 5.0) * minf(s, 2.0)
		for seg in _dots:
			(seg as ColorRect).custom_minimum_size = Vector2(seg_w, seg_h)
	if active:
		_update_spotlight(str(_cur().get("spotlight", "")))
	# Re-assert after spotlight/min-size settlement so the dock cannot cover the map.
	_shell.size = Vector2(card_w, card_h)
	_shell.offset_right = x + card_w
	_shell.offset_bottom = y + card_h
	call_deferred("_enforce_shell_size", card_w, card_h, x, y)


func _style_btn(btn: Button, kind: String, s: float) -> void:
	var pad := (14.0 if _phone else 10.0) * minf(s, 2.0)
	var h := float(_d.get("btn_h", 50.0 * s))
	if _phone:
		h = maxf(h, 56.0 * minf(s, 2.2))
	btn.custom_minimum_size = Vector2(0, h)
	btn.add_theme_stylebox_override("normal", Assets.btn_tex(kind, pad, "normal"))
	btn.add_theme_stylebox_override("hover", Assets.btn_tex(kind, pad, "hover"))
	btn.add_theme_stylebox_override("pressed", Assets.btn_tex(kind, pad, "pressed"))
	btn.add_theme_color_override("font_color", ThemeX.CREAM if kind != "secondary" else ThemeX.INK)
	btn.add_theme_color_override("font_hover_color", ThemeX.GOLD_SOFT)
	btn.add_theme_color_override("font_outline_color", ThemeX.WOOD_DARK)
	btn.add_theme_constant_override("outline_size", maxi(2, int(round(2.0 * minf(s, 1.8)))))


func _on_cta() -> void:
	if not active:
		return
	var kind := str(_cur().get("kind", ""))
	if kind == "info" or kind == "ready" or _cur().get("id", "") == "ready":
		_advance()


func _on_skip() -> void:
	_finish(true)


func _advance() -> void:
	_stop_spot_tweens()
	step_i += 1
	if step_i >= steps().size():
		_finish(false)
		return
	_pan_accum = 0.0
	_show_step()
	_layout()


func _finish(skipped: bool) -> void:
	_stop_spot_tweens()
	practice_claim.emit(false)
	active = false
	mark_completed()
	# Headless / tests: finish immediately so callers are not stuck on tweens.
	if DisplayServer.get_name() == "headless" or not is_inside_tree():
		visible = false
		if _shell:
			_shell.modulate.a = 0.0
		finished.emit(skipped)
		return
	var tw := create_tween()
	tw.set_parallel(true)
	if _shell:
		tw.tween_property(_shell, "modulate:a", 0.0, 0.22)
	tw.chain().tween_callback(func():
		visible = false
		finished.emit(skipped)
	)
