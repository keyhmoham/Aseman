## A board and Staunton-style pieces made here, turned on a lathe from
## profiles — used when the build has no downloaded model (an offline build,
## the tests), so the game always has a complete, good-looking set.
extends RefCounted

const Rules = preload("res://arena/chess/chess_rules.gd")

# Profiles: [radius, height] pairs from the base up, in units of a square.
const PROFILES := {
	Rules.PAWN: [[0.0, 0.0], [0.32, 0.0], [0.32, 0.05], [0.26, 0.09], [0.2, 0.12], [0.12, 0.36], [0.2, 0.4], [0.2, 0.43], [0.11, 0.46], [0.16, 0.54], [0.17, 0.62], [0.13, 0.7], [0.0, 0.73]],
	Rules.ROOK: [[0.0, 0.0], [0.36, 0.0], [0.36, 0.06], [0.3, 0.1], [0.24, 0.14], [0.2, 0.6], [0.28, 0.64], [0.28, 0.84], [0.2, 0.84], [0.2, 0.78], [0.0, 0.78]],
	Rules.BISHOP: [[0.0, 0.0], [0.34, 0.0], [0.34, 0.06], [0.27, 0.1], [0.2, 0.14], [0.12, 0.6], [0.22, 0.64], [0.22, 0.68], [0.12, 0.71], [0.18, 0.82], [0.17, 0.92], [0.09, 1.02], [0.06, 1.05], [0.07, 1.09], [0.0, 1.12]],
	Rules.QUEEN: [[0.0, 0.0], [0.38, 0.0], [0.38, 0.07], [0.3, 0.12], [0.22, 0.16], [0.13, 0.78], [0.25, 0.82], [0.25, 0.86], [0.15, 0.9], [0.2, 1.06], [0.25, 1.14], [0.15, 1.16], [0.08, 1.22], [0.08, 1.26], [0.0, 1.3]],
	Rules.KING: [[0.0, 0.0], [0.38, 0.0], [0.38, 0.07], [0.3, 0.12], [0.22, 0.16], [0.14, 0.84], [0.26, 0.88], [0.26, 0.92], [0.16, 0.96], [0.21, 1.14], [0.23, 1.2], [0.0, 1.22]],
	Rules.KNIGHT: [[0.0, 0.0], [0.34, 0.0], [0.34, 0.06], [0.27, 0.1], [0.2, 0.14], [0.17, 0.3], [0.22, 0.34], [0.0, 0.36]],
}


static func _material(white: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if white:
		m.albedo_color = Color(0.93, 0.9, 0.84)
		m.roughness = 0.28
		m.clearcoat_enabled = true
		m.clearcoat = 0.6
	else:
		m.albedo_color = Color(0.08, 0.075, 0.07)
		m.roughness = 0.22
		m.metallic = 0.1
		m.clearcoat_enabled = true
		m.clearcoat = 0.8
	return m


static func lathe(profile: Array, scale: float, segments: int = 40) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in profile.size() - 1:
		var a: Array = profile[i]
		var b: Array = profile[i + 1]
		for j in segments:
			var t0 := TAU * j / segments
			var t1 := TAU * (j + 1) / segments
			var p00 := Vector3(cos(t0) * a[0], a[1], sin(t0) * a[0]) * scale
			var p01 := Vector3(cos(t1) * a[0], a[1], sin(t1) * a[0]) * scale
			var p10 := Vector3(cos(t0) * b[0], b[1], sin(t0) * b[0]) * scale
			var p11 := Vector3(cos(t1) * b[0], b[1], sin(t1) * b[0]) * scale
			st.add_vertex(p00)
			st.add_vertex(p10)
			st.add_vertex(p11)
			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p01)
	st.generate_normals()
	return st.commit()


static func _part(mesh: Mesh, mat: Material, pos: Vector3 = Vector3.ZERO, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot
	return mi


## One template per piece code.
static func build_templates(square: float) -> Dictionary:
	var out := {}
	for white in [true, false]:
		var mat := _material(white)
		for t in PROFILES:
			var holder := Node3D.new()
			holder.add_child(_part(lathe(PROFILES[t], square), mat))
			match t:
				Rules.KNIGHT:
					# The horse's head: a sculpted neck and muzzle on the base.
					var neck := BoxMesh.new()
					neck.size = Vector3(0.22, 0.5, 0.34) * square
					holder.add_child(_part(neck, mat, Vector3(0, 0.56, -0.02) * square, Vector3(-14, 0, 0)))
					var head := BoxMesh.new()
					head.size = Vector3(0.2, 0.2, 0.44) * square
					holder.add_child(_part(head, mat, Vector3(0, 0.78, 0.1) * square, Vector3(24, 0, 0)))
					var mane := BoxMesh.new()
					mane.size = Vector3(0.08, 0.46, 0.08) * square
					holder.add_child(_part(mane, mat, Vector3(0, 0.62, -0.18) * square, Vector3(-12, 0, 0)))
					for side in [-1, 1]:
						var ear := PrismMesh.new()
						ear.size = Vector3(0.06, 0.12, 0.06) * square
						holder.add_child(_part(ear, mat, Vector3(side * 0.06, 0.92, -0.04) * square))
					if not white:
						holder.rotation_degrees.y = 180
				Rules.KING:
					var bar := BoxMesh.new()
					bar.size = Vector3(0.07, 0.26, 0.07) * square
					holder.add_child(_part(bar, mat, Vector3(0, 1.33, 0) * square))
					var cross := BoxMesh.new()
					cross.size = Vector3(0.2, 0.07, 0.07) * square
					holder.add_child(_part(cross, mat, Vector3(0, 1.36, 0) * square))
				Rules.QUEEN:
					for k in 8:
						var bead := SphereMesh.new()
						bead.radius = 0.035 * square
						bead.height = 0.07 * square
						var a := TAU * k / 8.0
						holder.add_child(_part(bead, mat, Vector3(cos(a) * 0.22, 1.17, sin(a) * 0.22) * square))
				Rules.ROOK:
					# Crenellations: four merlons.
					for k in 4:
						var merlon := BoxMesh.new()
						merlon.size = Vector3(0.14, 0.1, 0.1) * square
						var a := TAU * k / 4.0 + PI / 4
						holder.add_child(_part(merlon, mat, Vector3(cos(a) * 0.22, 0.88, sin(a) * 0.22) * square, Vector3(0, -rad_to_deg(a), 0)))
			out[t | (0 if white else Rules.BLACK)] = holder
	return out


## A marble board with a walnut frame and coordinates.
static func build_board(root: Node3D, square: float, origin: float, top: float) -> void:
	var light := StandardMaterial3D.new()
	light.albedo_color = Color(0.86, 0.83, 0.76)
	light.roughness = 0.2
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.29, 0.22, 0.18)
	dark.roughness = 0.25
	var frame := StandardMaterial3D.new()
	frame.albedo_color = Color(0.17, 0.1, 0.06)
	frame.roughness = 0.4
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(square * 9.4, top * 0.9, square * 9.4)
	base.mesh = bm
	base.material_override = frame
	base.position = Vector3(0, top * 0.45 - 0.01, 0)
	root.add_child(base)
	for f in 8:
		for r in 8:
			var tile := MeshInstance3D.new()
			var tm := BoxMesh.new()
			tm.size = Vector3(square, 0.02, square)
			tile.mesh = tm
			tile.material_override = dark if (f + r) % 2 == 0 else light
			tile.position = Vector3(-(origin + f * square), top - 0.01, origin + r * square)
			root.add_child(tile)
	for i in 8:
		for side in [-1, 1]:
			var file_label := Label3D.new()
			file_label.text = "abcdefgh"[i]
			file_label.font_size = 48
			file_label.pixel_size = 0.004
			file_label.rotation_degrees = Vector3(-90, 0 if side < 0 else 180, 0)
			file_label.modulate = Color(0.9, 0.8, 0.6)
			file_label.position = Vector3(-(origin + i * square), top + 0.002, side * square * 4.35)
			root.add_child(file_label)
			var rank_label := Label3D.new()
			rank_label.text = str(i + 1)
			rank_label.font_size = 48
			rank_label.pixel_size = 0.004
			rank_label.rotation_degrees = Vector3(-90, 0 if side < 0 else 180, 0)
			rank_label.modulate = Color(0.9, 0.8, 0.6)
			rank_label.position = Vector3(-side * square * 4.35, top + 0.002, origin + i * square)
			root.add_child(rank_label)
