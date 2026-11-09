## Shared HUD chrome helpers — same textures / palette as in-match hud.gd.
extends RefCounted

const Fonts = preload("res://arena/persian_rails/fonts.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")
const Assets = preload("res://arena/persian_rails/assets.gd")


static func density_for(vp: Vector2) -> Dictionary:
	return ThemeX.density(vp)


static func style_btn(btn: Button, kind: String, s: float = 1.0, btn_h: float = 52.0) -> void:
	var pad := clampf(8.0 * minf(s, 1.5), 6.0, maxf(6.0, btn_h * 0.14))
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


static func make_btn(text: String, kind: String, s: float, btn_h: float, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, btn_h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Fonts.apply(b, font_size, true)
	style_btn(b, kind, s, btn_h)
	return b


static func cream_label(text: String, font_size: int) -> Label:
	var lab := Label.new()
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Fonts.apply(lab, font_size, true)
	lab.add_theme_color_override("font_color", ThemeX.CREAM)
	lab.add_theme_color_override("font_outline_color", ThemeX.WOOD_DARK)
	lab.add_theme_constant_override("outline_size", 3)
	return lab


static func gold_label(text: String, font_size: int) -> Label:
	var lab := Label.new()
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Fonts.apply(lab, font_size, true)
	lab.add_theme_color_override("font_color", ThemeX.GOLD_SOFT)
	return lab


static func body_label(text: String, font_size: int, color: Color = ThemeX.INK, center: bool = false) -> Label:
	var lab := Label.new()
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if center else HORIZONTAL_ALIGNMENT_RIGHT
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Fonts.apply(lab, font_size, false)
	lab.add_theme_color_override("font_color", color)
	return lab


static func framed(kind: String, pad: float, s: float) -> PanelContainer:
	var p := PanelContainer.new()
	var tex := "panel_fantasy.png"
	var expand := 40.0 * minf(s, 2.0)
	match kind:
		"top":
			tex = "panel_top.png"
			expand = 32.0 * minf(s, 2.0)
		"card":
			tex = "card_frame.png"
			expand = 26.0 * minf(s, 2.0)
		_:
			tex = "panel_fantasy.png"
	p.add_theme_stylebox_override("panel", Assets.style_tex(tex, pad, expand))
	return p


static func chip(text: String, tone: String, font_size: int) -> PanelContainer:
	var wrap := PanelContainer.new()
	var st := StyleBoxFlat.new()
	match tone:
		"teal":
			st.bg_color = ThemeX.TEAL
		"clay":
			st.bg_color = ThemeX.CLAY
		_:
			st.bg_color = ThemeX.GOLD_SOFT
	st.set_corner_radius_all(999)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 6
	st.content_margin_bottom = 6
	st.border_color = ThemeX.WOOD_DARK
	st.set_border_width_all(2)
	st.shadow_color = Color(0.9, 0.78, 0.42, 0.35)
	st.shadow_size = 8
	wrap.add_theme_stylebox_override("panel", st)
	var lab := Label.new()
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Fonts.apply(lab, font_size, true)
	if tone == "teal" or tone == "clay":
		lab.add_theme_color_override("font_color", ThemeX.CREAM)
	else:
		lab.add_theme_color_override("font_color", ThemeX.WOOD_DARK)
	wrap.add_child(lab)
	return wrap


static func callout(title: String, body: String, accent: Color, font_title: int, font_body: int) -> PanelContainer:
	var wrap := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(accent.r, accent.g, accent.b, 0.10)
	st.border_color = Color(accent.r, accent.g, accent.b, 0.28)
	st.set_border_width_all(1)
	st.set_corner_radius_all(18)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	wrap.add_theme_stylebox_override("panel", st)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	wrap.add_child(col)
	var t := body_label(title, font_title, accent, false)
	Fonts.apply(t, font_title, true)
	col.add_child(t)
	col.add_child(body_label(body, font_body, ThemeX.INK, false))
	return wrap


static func wood_backdrop(parent: Control) -> void:
	var wood := TextureRect.new()
	wood.texture = Assets.tex("wood.png")
	wood.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wood.stretch_mode = TextureRect.STRETCH_TILE
	wood.set_anchors_preset(Control.PRESET_FULL_RECT)
	wood.modulate = Color(1, 1, 1, 0.92)
	wood.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(wood)
	var vig := TextureRect.new()
	vig.texture = Assets.tex("vignette.png")
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.modulate = Color(1, 1, 1, 0.45)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(vig)
