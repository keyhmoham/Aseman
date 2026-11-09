## Art direction — warm Persian palette + DPI-correct responsive density.
extends RefCounted

const INK := Color("24160f")
const SAND := Color("f6ecd8")
const PARCHMENT := Color("ead7b5")
const TEAL := Color("156a87")
const TEAL_DEEP := Color("0a3f56")
const TEAL_BRIGHT := Color("2a8fb0")
const CLAY := Color("c4531f")
const GOLD := Color("c9a227")
const GOLD_SOFT := Color("e6c86a")
const MIST := Color("8ec0d4")
const SKY_TOP := Color("6aa7c2")
const SKY_BOT := Color("d2e8f0")
const WOOD := Color("6a422c")
const WOOD_DARK := Color("3b2418")
const FELT := Color("1f4336")
const CREAM := Color("fff8ee")
const WHITE := Color(1, 1, 1, 1)

const REGION := {
	"northwest": Color("2a7a96"),
	"north": Color("3f8a55"),
	"center": Color("c9a874"),
	"west": Color("7a5640"),
	"east": Color("b8895a"),
	"south": Color("9a2a48"),
}

const ROUTE := {
	"red": Color("c0392b"), "blue": Color("2980b9"), "green": Color("27ae60"),
	"yellow": Color("f1c40f"), "black": Color("2c3e50"), "white": Color("eceff1"),
	"orange": Color("e67e22"), "purple": Color("8e44ad"), "gray": Color("8e9aa3"),
	"locomotive": Color("d4af37"),
}

# Coarse fallback only — live board prefers geography.json (OSM Iran).
const IRAN_OUTLINE := [
	Vector2(-8.2, -6.4), Vector2(-7.6, -7.5), Vector2(-5.0, -8.0), Vector2(-2.2, -7.7),
	Vector2(0.4, -7.1), Vector2(2.6, -6.5), Vector2(4.8, -5.4), Vector2(6.6, -3.6),
	Vector2(7.4, -1.0), Vector2(7.0, 1.8), Vector2(6.0, 4.0), Vector2(4.2, 5.8),
	Vector2(2.0, 7.2), Vector2(-0.6, 7.6), Vector2(-3.0, 6.8), Vector2(-5.0, 5.2),
	Vector2(-6.6, 3.0), Vector2(-7.6, 0.4), Vector2(-8.0, -2.4), Vector2(-8.3, -4.6),
]


static func device_pixel_ratio() -> float:
	if OS.has_feature("web"):
		var d = JavaScriptBridge.eval("window.devicePixelRatio || 1", true)
		if typeof(d) == TYPE_FLOAT or typeof(d) == TYPE_INT:
			return clampf(float(d), 1.0, 4.0)
	return clampf(DisplayServer.screen_get_scale(), 1.0, 4.0)


static func density(vp: Vector2) -> Dictionary:
	var w := maxf(vp.x, 1.0)
	var h := maxf(vp.y, 1.0)
	var short := minf(w, h)
	var landscape := w > h * 1.15
	# Godot web viewport is often *device* pixels. Size UI from CSS pixels so
	# Farsi type stays readable on phones (DPR 2–3 was shrinking shell text).
	var dpr := device_pixel_ratio()
	var css_w := w / dpr
	var css_h := h / dpr
	var css_short := minf(css_w, css_h)
	var s := clampf(css_short / 390.0, 0.9, 1.45)
	var phone := css_w < 720.0
	var compact := css_w < 500.0 or css_h < 780.0
	# Prefer one card rail so the Iran map keeps most of the viewport.
	var single_row := phone or compact or landscape or css_h < 960.0
	# Convert a CSS-pixel length into viewport (device) pixels.
	var px := dpr * s

	# Fit chrome to content — no spare strip under buttons / above the prompt.
	var pad := 4.0 * minf(px, 1.8)
	var gap := 3.0 * minf(px, 1.6)
	var rows := 1 if single_row else 2
	var btn_h := clampf(40.0 * px, 36.0 * dpr, 46.0 * px)
	var card_h := clampf(50.0 * px * (0.90 if landscape else 1.0), 38.0 * dpr, 54.0 * px)
	var card_w := clampf(card_h * 0.78, 38.0 * dpr, 48.0 * px)
	# Bottom height = content only (pads + card rail(s) + gap + buttons).
	var bottom := pad * 2.0 + card_h * float(rows) + btn_h + gap * float(rows)
	# Top is a single-row bar (prompt + chips).
	var top := (34.0 if compact else 38.0) * px
	if landscape:
		top = 30.0 * px
		bottom = minf(bottom, h * 0.32)
	var max_chrome := h * 0.34
	if top + bottom > max_chrome:
		var k := max_chrome / maxf(top + bottom, 1.0)
		top *= k
		bottom *= k
		# Re-fit cards into the scaled bottom budget.
		var budget := maxf(72.0 * dpr, bottom - pad * 2.0)
		btn_h = minf(btn_h, budget * 0.34)
		card_h = maxf(36.0 * dpr, (budget - btn_h - gap * float(rows)) / float(rows))
		card_w = clampf(card_h * 0.78, 36.0 * dpr, 48.0 * px)
	var btn_margin := 6.0 * minf(px, 1.5) * 1.2
	var font_btn := int(clampf(round(btn_h * 0.36), 14.0 * dpr, maxf(14.0 * dpr, btn_h - btn_margin - 2.0)))
	var font_card := int(clampf(round(card_h * 0.24), 12.0 * dpr, maxf(12.0 * dpr, card_h * 0.28)))
	var font_title := int(round(16.0 * px))
	var font_body := int(round(14.0 * px))
	var font_chip := int(round(12.5 * px))
	# Shell menus: mid size — bigger than the old tiny UI, smaller than 1.6.3.
	var shell_title := int(round(22.0 * px))
	var shell_body := int(round(16.0 * px))
	var shell_nav := int(round(12.5 * px))
	var shell_btn := int(round(16.0 * px))
	var shell_btn_h := 52.0 * px
	var shell_nav_h := 76.0 * px

	return {
		"phone": phone,
		"compact": compact,
		"landscape": landscape,
		"scale": s,
		"dpr": dpr,
		"pad": pad,
		"gap": gap,
		"top_h": top,
		"bottom_h": bottom,
		"btn_h": btn_h,
		"chip_h": clampf(26.0 * px, 24.0 * dpr, maxf(24.0 * dpr, top * 0.72)),
		"card_w": card_w,
		"card_h": card_h,
		"font_title": font_title,
		"font_body": font_body,
		"font_chip": font_chip,
		"font_btn": font_btn,
		"font_card": font_card,
		"shell_title": shell_title,
		"shell_body": shell_body,
		"shell_nav": shell_nav,
		"shell_btn": shell_btn,
		"shell_btn_h": shell_btn_h,
		"shell_nav_h": shell_nav_h,
		"radius": 22.0 * minf(px, 1.8),
		"single_card_row": single_row,
	}


static func panel(bg: Color, radius: float = 22.0, pad: float = 10.0, border: Color = Color(0, 0, 0, 0), shadow: bool = true) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	st.set_corner_radius_all(int(maxi(16, int(round(radius)))))
	st.content_margin_left = pad
	st.content_margin_right = pad
	st.content_margin_top = pad * 0.65
	st.content_margin_bottom = pad * 0.65
	if border.a > 0.01:
		st.border_color = border
		st.set_border_width_all(maxi(1, int(round(pad * 0.08))))
	if shadow:
		st.shadow_color = Color(0, 0, 0, 0.25)
		st.shadow_size = int(10.0 * clampf(pad / 10.0, 0.8, 2.0))
		st.shadow_offset = Vector2(0, 3)
	return st


static func btn_style(kind: String, scale: float = 1.0) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	match kind:
		"primary":
			st.bg_color = TEAL
		"accent":
			st.bg_color = CLAY
		"secondary":
			st.bg_color = Color(1, 1, 1, 0.16)
		_:
			st.bg_color = Color(1, 1, 1, 0.08)
	st.set_corner_radius_all(int(22.0 * minf(scale, 1.8)))
	st.content_margin_left = 8 * minf(scale, 1.8)
	st.content_margin_right = 8 * minf(scale, 1.8)
	st.content_margin_top = 8 * minf(scale, 1.8)
	st.content_margin_bottom = 8 * minf(scale, 1.8)
	st.border_color = Color(1, 1, 1, 0.22)
	st.set_border_width_all(maxi(1, int(round(scale))))
	return st


static func mat(color: Color, rough: float = 0.85, metal: float = 0.0, alpha: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var c := color
	c.a = alpha
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if alpha < 0.999:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m
