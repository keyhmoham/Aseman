## Loads shipped textures (parchment, wood, felt, UI) once.
extends RefCounted

const DIR := "res://arena/persian_rails/textures/"

static var _cache: Dictionary = {}
static var _style_cache: Dictionary = {}


static func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var path := DIR + name
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is Texture2D:
			t = res
		elif res is Image:
			t = ImageTexture.create_from_image(res)
	_cache[name] = t
	return t


static func mat_tex(name: String, color: Color = Color.WHITE, rough: float = 0.9, uv_scale: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	var t := tex(name)
	if t:
		m.albedo_texture = t
		m.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	return m


static func style_tex(name: String, pad: float = 12.0, expand: float = 18.0) -> StyleBoxTexture:
	# Cache StyleBoxes — recreating them every HUD paint exhausts WebGL on long hands.
	var slice := maxf(expand, _min_slice_for(name))
	var key := "%s|%.2f|%.2f" % [name, pad, slice]
	if _style_cache.has(key):
		return _style_cache[key]
	var st := StyleBoxTexture.new()
	var t := tex(name)
	if t:
		st.texture = t
	st.texture_margin_left = slice
	st.texture_margin_right = slice
	st.texture_margin_top = slice
	st.texture_margin_bottom = slice
	st.content_margin_left = pad
	st.content_margin_right = pad
	st.content_margin_top = pad * 0.7
	st.content_margin_bottom = pad * 0.7
	_style_cache[key] = st
	return st


static func _min_slice_for(name: String) -> float:
	if name.begins_with("btn_"):
		return 26.0
	if name.begins_with("panel_fantasy"):
		return 40.0
	if name.begins_with("panel_top"):
		return 32.0
	if name.begins_with("card_frame"):
		return 26.0
	return 18.0


static func btn_tex(kind: String, pad: float = 10.0, state: String = "normal") -> StyleBoxTexture:
	var base := "btn_primary"
	match kind:
		"accent":
			base = "btn_accent"
		"secondary", "ghost":
			base = "btn_secondary"
		_:
			base = "btn_primary"
	var name := base + ".png"
	if state == "hover" and tex(base + "_hover.png") != null:
		name = base + "_hover.png"
	elif state == "pressed" and tex(base + "_pressed.png") != null:
		name = base + "_pressed.png"
	elif state == "disabled":
		name = "btn_secondary.png"
	return style_tex(name, pad, 26.0)
