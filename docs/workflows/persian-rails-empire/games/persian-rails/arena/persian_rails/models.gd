## Kenney CC0 trains when available; otherwise polished procedural wagons.
extends RefCounted

const MODEL_DIR := "res://arena/persian_rails/models/kenney-train/"
const ThemeX = preload("res://arena/persian_rails/theme.gd")

var cache: Dictionary = {}


const WAGON_SCALE := 1.0


func wagon_for_player(_pi: int, color: Color) -> Node3D:
	return _token_wagon(color, false)


func locomotive(color: Color) -> Node3D:
	return _token_wagon(color, true)


func _instance(file: String) -> Node3D:
	var path := MODEL_DIR + file
	if not ResourceLoader.exists(path):
		path = "res://arena/persian_rails/models/" + file
		if not ResourceLoader.exists(path):
			return null
	if not cache.has(path):
		cache[path] = load(path)
	var packed2 = cache[path]
	if packed2 == null:
		return null
	var node = packed2.instantiate() if packed2 is PackedScene else null
	return node as Node3D


func _tint(n: Node3D, color: Color) -> void:
	for child in n.get_children():
		_tint(child, color)
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mat := ThemeX.mat(color, 0.55, 0.15)
		mat.emission_enabled = true
		mat.emission = color.lightened(0.15)
		mat.emission_energy_multiplier = 0.12
		mi.material_override = mat


func _token_wagon(color: Color, loco: bool = false) -> Node3D:
	## Flat Ticket-to-Ride style train token — always lies on the board (Y-up).
	## Length along local Z; rotate only around Y to face the route.
	var root := Node3D.new()
	root.scale = Vector3.ONE * WAGON_SCALE
	var body_mat := ThemeX.mat(color, 0.4, 0.2)
	body_mat.emission_enabled = true
	body_mat.emission = color.lightened(0.15)
	body_mat.emission_energy_multiplier = 0.2
	var trim := ThemeX.mat(ThemeX.GOLD.darkened(0.08), 0.45, 0.4)
	var dark := ThemeX.mat(ThemeX.WOOD_DARK.lightened(0.05), 0.8, 0.05)
	# Bold claimed bars — fill most of a rail slot so ownership reads clearly.
	var shadow := MeshInstance3D.new()
	var sbox := BoxMesh.new()
	sbox.size = Vector3(0.46, 0.02, 0.66)
	shadow.mesh = sbox
	shadow.material_override = ThemeX.mat(Color(0, 0, 0, 0.3), 1.0, 0.0, 0.3)
	shadow.position.y = 0.01
	root.add_child(shadow)
	var chassis := MeshInstance3D.new()
	var cbox := BoxMesh.new()
	cbox.size = Vector3(0.40, 0.06, 0.60 if loco else 0.54)
	chassis.mesh = cbox
	chassis.material_override = dark
	chassis.position.y = 0.05
	root.add_child(chassis)
	var body := MeshInstance3D.new()
	var bbox := BoxMesh.new()
	bbox.size = Vector3(0.36, 0.15, 0.54 if loco else 0.48)
	body.mesh = bbox
	body.material_override = body_mat
	body.position.y = 0.145
	root.add_child(body)
	var roof := MeshInstance3D.new()
	var rbox := BoxMesh.new()
	rbox.size = Vector3(0.30, 0.035, 0.46 if loco else 0.40)
	roof.mesh = rbox
	roof.material_override = trim
	roof.position.y = 0.23
	root.add_child(roof)
	for xz in [Vector2(-0.14, -0.16), Vector2(0.14, -0.16), Vector2(-0.14, 0.16), Vector2(0.14, 0.16)]:
		var wh := MeshInstance3D.new()
		var wc := CylinderMesh.new()
		wc.top_radius = 0.05
		wc.bottom_radius = 0.05
		wc.height = 0.045
		wh.mesh = wc
		wh.rotation_degrees = Vector3(0, 0, 90)
		wh.material_override = ThemeX.mat(Color("1a1a1a"), 0.55, 0.45)
		wh.position = Vector3(xz.x, 0.05, xz.y)
		root.add_child(wh)
	if loco:
		var nose := MeshInstance3D.new()
		var nbox := BoxMesh.new()
		nbox.size = Vector3(0.26, 0.11, 0.13)
		nose.mesh = nbox
		nose.material_override = body_mat
		nose.position = Vector3(0, 0.14, -0.32)
		root.add_child(nose)
		var funnel := MeshInstance3D.new()
		var fc := CylinderMesh.new()
		fc.top_radius = 0.038
		fc.bottom_radius = 0.042
		fc.height = 0.11
		funnel.mesh = fc
		funnel.material_override = ThemeX.mat(Color("1a1a1a"), 0.5, 0.35)
		funnel.position = Vector3(0, 0.28, -0.15)
		root.add_child(funnel)
	return root
