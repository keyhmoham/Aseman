## Shared Vazirmatn UI font (Farsi digits) for HUD and Label3D.
extends RefCounted

const REGULAR := "res://arena/persian_rails/fonts/Vazirmatn-UI-FD-Regular.ttf"
const BOLD := "res://arena/persian_rails/fonts/Vazirmatn-UI-FD-Bold.ttf"

static var _regular: FontFile
static var _bold: FontFile


static func regular() -> Font:
	if _regular == null:
		_regular = _load(REGULAR)
	return _regular


static func bold() -> Font:
	if _bold == null:
		_bold = _load(BOLD)
	if _bold == null:
		return regular()
	return _bold


static func _load(path: String) -> FontFile:
	# Prefer the imported resource; fall back to dynamic load (web/pack).
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is FontFile:
			return res as FontFile
		if res is Font:
			var wrap := FontFile.new()
			# Imported DynamicFontVariation / FontFile already usable via Font API.
			return res as FontFile
	var f := FontFile.new()
	var err := f.load_dynamic_font(path)
	if err != OK:
		push_warning("Persian font missing (%s): %s" % [str(err), path])
		return null
	return f


static func apply(control: Control, size: int = 16, use_bold: bool = false) -> void:
	var font := bold() if use_bold else regular()
	if font:
		control.add_theme_font_override("font", font)
	control.add_theme_font_size_override("font_size", size)
	control.layout_direction = Control.LAYOUT_DIRECTION_RTL


static func apply_label3d(label: Label3D, size: int = 48) -> void:
	var font := regular()
	if font:
		label.font = font
	label.font_size = size
	label.text_direction = TextServer.DIRECTION_RTL
