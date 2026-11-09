## Clean Iran board — seas/lakes, tuned 3D scales, quieter styling.
extends Node3D

signal city_tapped(city_id: String)
signal route_tapped(route_id: String)

const Fonts = preload("res://arena/persian_rails/fonts.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")
const Assets = preload("res://arena/persian_rails/assets.gd")

# Clean board scales — even corridors, gems that don't eat into rails.
const CITY_GEM := 0.10
const CITY_RING := 0.17
const CITY_BASE := 0.14
const RAIL_W := 0.135
const RAIL_H := 0.038
const TIE_W := 0.24
const BAR_W := 0.022
const LABEL_Y := 0.38
const ROUTE_INSET := 0.42
const PARALLEL_OFFSET := 0.20
const SEG_GAP := 0.11
const MIN_SEG := 0.28

var rules
var models
var city_nodes: Dictionary = {}
var route_nodes: Dictionary = {}
var wagon_nodes: Dictionary = {}
var route_mats: Dictionary = {}
var _board: Node3D
var _claim_glow := false
var _pulse_t := 0.0
var _compact_labels := false
var _label_nodes: Array = []
var _geo: Dictionary = {}
var _claims_fp := ""
var _widened_routes: Dictionary = {}


func setup(p_rules, p_models) -> void:
	rules = p_rules
	models = p_models
	_geo = _load_geo()
	_claims_fp = ""
	_widened_routes.clear()
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(390, 700)
	var dens: Dictionary = ThemeX.density(vp)
	_compact_labels = bool(dens.get("phone", true)) or bool(dens.get("compact", true))
	_build_board()
	set_label_lod(16.0 if _compact_labels else 12.0)


func _load_geo() -> Dictionary:
	# Prefer full geography (real Iran outline + waters); fall back to waters.json.
	for path in ["res://arena/persian_rails/data/geography.json", "res://arena/persian_rails/data/waters.json"]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var data = JSON.parse_string(f.get_as_text())
		if typeof(data) == TYPE_DICTIONARY:
			return data
	return {"seas": [], "lakes": [], "iran_outline": []}


func _pts(raw: Array, max_pts: int = 96) -> Array:
	var out: Array = []
	for p in raw:
		if typeof(p) == TYPE_ARRAY and p.size() >= 2:
			out.append(Vector2(float(p[0]), float(p[1])))
		elif typeof(p) == TYPE_VECTOR2:
			out.append(p)
	return _decimate(out, max_pts)


func _decimate(pts: Array, max_pts: int) -> Array:
	if pts.size() <= max_pts or max_pts < 6:
		return pts
	var out: Array = []
	var step := float(pts.size()) / float(max_pts)
	var i := 0.0
	while int(i) < pts.size() and out.size() < max_pts:
		out.append(pts[int(i)])
		i += step
	return out


func _iran_outline() -> Array:
	var pts := _pts(_geo.get("iran_outline", []), 160)
	if pts.size() >= 8:
		return pts
	# Fallback schematic outline from theme.
	var fallback: Array = []
	for p in ThemeX.IRAN_OUTLINE:
		fallback.append(p)
	return fallback


func _process(delta: float) -> void:
	if not _claim_glow:
		return
	_pulse_t += delta
	var pulse := 0.4 + 0.5 * sin(_pulse_t * 3.2)
	for rid in route_mats.keys():
		if rules and rules.claimed.has(rid):
			continue
		var m: StandardMaterial3D = route_mats[rid]
		if m:
			m.emission_energy_multiplier = pulse * 0.55


func set_claim_glow(on: bool) -> void:
	_claim_glow = on
	_pulse_t = 0.0
	set_process(on)
	for rid in route_mats.keys():
		var m: StandardMaterial3D = route_mats[rid]
		if m == null:
			continue
		if on and rules and not rules.claimed.has(rid):
			m.emission_enabled = true
			m.emission = m.albedo_color.lightened(0.25)
			m.emission_energy_multiplier = 0.4
		else:
			m.emission_enabled = rules != null and rules.claimed.has(rid)
			if not m.emission_enabled:
				m.emission_energy_multiplier = 0.0


func set_label_lod(dist: float) -> void:
	var show := (not _compact_labels) or dist < 13.5
	for n in _label_nodes:
		if is_instance_valid(n):
			n.visible = show


func _build_board() -> void:
	for c in get_children():
		c.queue_free()
	city_nodes.clear()
	route_nodes.clear()
	wagon_nodes.clear()
	route_mats.clear()
	_label_nodes.clear()
	_board = Node3D.new()
	_board.name = "Board"
	add_child(_board)
	_add_table()
	# Seas under land (clean coasts); lakes on top of land (inland water).
	_add_parchment()
	_add_seas()
	_add_iran_land()
	_add_lakes()
	_add_region_washes()
	_add_ornament()
	for route in rules.routes:
		_add_route(route)
	for city in rules.cities:
		_add_city(city)


func _add_table() -> void:
	var felt := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(26, 28)
	felt.mesh = fp
	felt.material_override = Assets.mat_tex("felt.png", Color(0.92, 0.95, 0.93), 1.0, 3.5)
	felt.position = Vector3(0, -0.1, 0)
	_board.add_child(felt)
	_wood_beam(Vector3(0, -0.02, -10.2), Vector3(19.6, 0.32, 0.78))
	_wood_beam(Vector3(0, -0.02, 10.2), Vector3(19.6, 0.32, 0.78))
	_wood_beam(Vector3(-9.4, -0.02, 0), Vector3(0.78, 0.32, 21.0))
	_wood_beam(Vector3(9.4, -0.02, 0), Vector3(0.78, 0.32, 21.0))
	for xz in [Vector2(-9.4, -10.2), Vector2(9.4, -10.2), Vector2(-9.4, 10.2), Vector2(9.4, 10.2)]:
		var boss := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.42
		cyl.bottom_radius = 0.42
		cyl.height = 0.36
		boss.mesh = cyl
		boss.material_override = Assets.mat_tex("wood.png", Color(0.9, 0.82, 0.72), 0.7, 1.4)
		boss.position = Vector3(xz.x, 0.06, xz.y)
		_board.add_child(boss)


func _wood_beam(pos: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = Assets.mat_tex("wood.png", Color(1, 1, 1), 0.75, 2.0)
	mi.position = pos
	_board.add_child(mi)


func _add_parchment() -> void:
	var base := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(18.0, 20.0)
	base.mesh = plane
	base.material_override = Assets.mat_tex("parchment.png", Color(1.0, 0.98, 0.94), 0.96, 1.05)
	base.position = Vector3(0, 0.0, 0)
	_board.add_child(base)


func _add_iran_land() -> void:
	# Real Iran land silhouette (OSM Nominatim border) drawn above seas.
	var iran := _iran_outline()
	var sil := MeshInstance3D.new()
	sil.mesh = _outline_mesh(iran, 0.025)
	# Keep land mostly opaque — alpha meshes often vanish on Godot web/compat.
	sil.material_override = ThemeX.mat(Color(0.93, 0.84, 0.64), 1.0, 0.0, 1.0)
	_board.add_child(sil)
	_add_outline_ribbon(iran, ThemeX.WOOD_DARK.darkened(0.05), 0.065)


func _add_seas() -> void:
	for sea in _geo.get("seas", []):
		var pts := _pts(sea.get("outline", []), 96)
		if pts.size() < 3:
			continue
		_add_water_poly(pts, Color(str(sea.get("color", "#1f6a92"))), 0.012, str(sea.get("name_fa", "")), false)


func _add_lakes() -> void:
	for lake in _geo.get("lakes", []):
		var pts2 := _pts(lake.get("outline", []), 56)
		if pts2.size() >= 3:
			_add_water_poly(pts2, Color(str(lake.get("color", "#2f7a98"))), 0.045, str(lake.get("name_fa", "")), true)
			continue
		var c: Array = lake.get("center", [0, 0])
		if c.size() < 2:
			continue
		_add_water_ellipse(
			Vector3(float(c[0]), 0.045, float(c[1])),
			float(lake.get("radius_x", 0.5)),
			float(lake.get("radius_z", 0.4)),
			Color(str(lake.get("color", "#2f7a98"))),
			str(lake.get("name_fa", ""))
		)


func _water_mat(color: Color, _alpha: float = 1.0) -> StandardMaterial3D:
	var m := ThemeX.mat(color, 0.32, 0.12, 1.0)
	m.emission_enabled = true
	m.emission = color.lightened(0.22)
	m.emission_energy_multiplier = 0.32
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _add_water_poly(pts: Array, color: Color, y: float, name_fa: String, is_lake: bool = false) -> void:
	# Seas sit under land (y slightly below Iran silhouette).
	if not is_lake:
		y = minf(y, 0.012)
	var mesh := _outline_mesh(pts, y)
	if mesh == null or mesh.get_surface_count() == 0:
		mesh = _outline_mesh(_convex_hull(pts), y)
	if mesh == null or mesh.get_surface_count() == 0:
		# Last-resort ellipse only if triangulation totally fails.
		var min_x := INF
		var max_x := -INF
		var min_z := INF
		var max_z := -INF
		for p in pts:
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
			min_z = minf(min_z, p.y)
			max_z = maxf(max_z, p.y)
		_add_water_ellipse(
			Vector3((min_x + max_x) * 0.5, y, (min_z + max_z) * 0.5),
			maxf(0.25, (max_x - min_x) * 0.5),
			maxf(0.2, (max_z - min_z) * 0.5),
			color,
			name_fa
		)
		return
	# Slight underfill so lakes stay readable over parchment.
	if is_lake:
		var under := MeshInstance3D.new()
		under.mesh = _outline_mesh(pts, y - 0.012)
		under.material_override = _water_mat(color.darkened(0.12))
		_board.add_child(under)
	var fill := MeshInstance3D.new()
	fill.mesh = mesh
	fill.material_override = _water_mat(color.lightened(0.04 if is_lake else 0.0))
	_board.add_child(fill)
	_add_outline_ribbon(pts, color.darkened(0.42), 0.075 if is_lake else 0.05)
	if name_fa != "" and (is_lake or pts.size() >= 12):
		# Lakes: quieter label so it doesn't fight city names.
		_water_label(pts, name_fa, y + (0.08 if is_lake else 0.12), is_lake)


func _convex_hull(pts: Array) -> Array:
	if pts.size() <= 3:
		return pts
	var sorted: Array = pts.duplicate()
	sorted.sort_custom(func(a, b):
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x
	)
	var lower: Array = []
	for p in sorted:
		while lower.size() >= 2 and _cross(lower[lower.size() - 2], lower[lower.size() - 1], p) <= 0.0:
			lower.pop_back()
		lower.append(p)
	var upper: Array = []
	var i: int = sorted.size() - 1
	while i >= 0:
		var p2: Vector2 = sorted[i]
		while upper.size() >= 2 and _cross(upper[upper.size() - 2], upper[upper.size() - 1], p2) <= 0.0:
			upper.pop_back()
		upper.append(p2)
		i -= 1
	lower.pop_back()
	upper.pop_back()
	return lower + upper


func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


func _inset_poly(pts: Array, amount: float) -> Array:
	var cx := 0.0
	var cz := 0.0
	for p in pts:
		cx += p.x
		cz += p.y
	cx /= float(pts.size())
	cz /= float(pts.size())
	var out: Array = []
	for p in pts:
		var v: Vector2 = p - Vector2(cx, cz)
		var L := v.length()
		if L < 0.001:
			continue
		out.append(Vector2(cx, cz) + v * maxf(0.15, (L - amount) / L))
	return out


func _add_water_ellipse(pos: Vector3, rx: float, rz: float, color: Color, name_fa: String) -> void:
	var under := MeshInstance3D.new()
	var ucyl := CylinderMesh.new()
	ucyl.top_radius = 1.0
	ucyl.bottom_radius = 1.0
	ucyl.height = 0.025
	under.mesh = ucyl
	under.material_override = ThemeX.mat(color.darkened(0.12), 1.0, 0.0, 0.96)
	under.position = pos + Vector3(0, -0.01, 0)
	under.scale = Vector3(rx, 1.0, rz)
	_board.add_child(under)
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 0.02
	mi.mesh = cyl
	mi.material_override = _water_mat(color, 0.9)
	mi.position = pos
	mi.scale = Vector3(rx, 1.0, rz)
	_board.add_child(mi)
	var rim := MeshInstance3D.new()
	var rc := CylinderMesh.new()
	rc.top_radius = 1.08
	rc.bottom_radius = 1.08
	rc.height = 0.012
	rim.mesh = rc
	rim.material_override = ThemeX.mat(Color(0.12, 0.32, 0.42, 0.55), 1.0, 0.0, 0.55)
	rim.position = pos + Vector3(0, -0.006, 0)
	rim.scale = Vector3(rx, 1.0, rz)
	_board.add_child(rim)
	if name_fa != "":
		var lab := Label3D.new()
		lab.text = name_fa
		Fonts.apply_label3d(lab, 18 if _compact_labels else 22)
		lab.pixel_size = 0.0085
		lab.position = pos + Vector3(0, 0.12, 0)
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.modulate = Color(0.12, 0.28, 0.4)
		lab.outline_modulate = Color(0.9, 0.96, 1.0, 0.9)
		lab.outline_size = 6
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.text_direction = TextServer.DIRECTION_RTL
		_board.add_child(lab)


func _water_label(pts: Array, name_fa: String, y: float, soft: bool = false) -> void:
	var cx := 0.0
	var cz := 0.0
	for p in pts:
		cx += p.x
		cz += p.y
	cx /= float(pts.size())
	cz /= float(pts.size())
	var min_z := INF
	var max_z := -INF
	for p2 in pts:
		min_z = minf(min_z, p2.y)
		max_z = maxf(max_z, p2.y)
	if absf(min_z) > absf(max_z) or min_z < -3.0:
		cz = lerpf(cz, min_z, 0.45)
	else:
		cz = lerpf(cz, max_z, 0.35)
	var lab := Label3D.new()
	lab.text = name_fa
	Fonts.apply_label3d(lab, 16 if soft else (20 if _compact_labels else 26))
	lab.pixel_size = 0.0075 if soft else 0.009
	lab.position = Vector3(cx, y + 0.02, cz)
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.modulate = Color(0.2, 0.4, 0.55, 0.75) if soft else Color(0.95, 0.98, 1.0, 0.9)
	lab.outline_modulate = Color(0.92, 0.97, 1.0, 0.55) if soft else Color(0.1, 0.25, 0.4, 0.75)
	lab.outline_size = 5 if soft else 7
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.text_direction = TextServer.DIRECTION_RTL
	_board.add_child(lab)


func _outline_mesh(pts: Array, y: float) -> ArrayMesh:
	# Ear-clip fill — fan-from-centroid breaks concave seas/lakes.
	var poly: Array = []
	for p in pts:
		poly.append(p)
	if poly.size() >= 3:
		var a: Vector2 = poly[0]
		var b: Vector2 = poly[poly.size() - 1]
		if a.distance_to(b) < 0.001:
			poly.pop_back()
	if poly.size() < 3:
		return ArrayMesh.new()
	if _poly_area(poly) < 0.0:
		poly.reverse()
	var tris: Array = _ear_clip(poly)
	# If ear-clip stalls on a weird ring, fall back to centroid fan (OK for near-convex lakes).
	if tris.is_empty():
		var cx := 0.0
		var cz := 0.0
		for p2 in poly:
			cx += p2.x
			cz += p2.y
		cx /= float(poly.size())
		cz /= float(poly.size())
		for i in range(poly.size()):
			tris.append([Vector2(cx, cz), poly[i], poly[(i + 1) % poly.size()]])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nrm := Vector3.UP
	for t in tris:
		var tri: Array = t
		for v in tri:
			st.set_normal(nrm)
			st.add_vertex(Vector3(v.x, y, v.y))
	var mesh := st.commit()
	return mesh if mesh != null else ArrayMesh.new()


func _poly_area(pts: Array) -> float:
	var a := 0.0
	var n: int = pts.size()
	for i in range(n):
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


func _point_in_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var v0 := c - a
	var v1 := b - a
	var v2 := p - a
	var dot00 := v0.dot(v0)
	var dot01 := v0.dot(v1)
	var dot02 := v0.dot(v2)
	var dot11 := v1.dot(v1)
	var dot12 := v1.dot(v2)
	var inv := 1.0 / (dot00 * dot11 - dot01 * dot01)
	var u := (dot11 * dot02 - dot01 * dot12) * inv
	var v := (dot00 * dot12 - dot01 * dot02) * inv
	return u >= 0.0 and v >= 0.0 and (u + v) <= 1.0


func _ear_clip(pts: Array) -> Array:
	var verts: Array = pts.duplicate()
	var tris: Array = []
	var guard := 0
	while verts.size() > 3 and guard < 4096:
		guard += 1
		var n: int = verts.size()
		var clipped := false
		for i in range(n):
			var prev: Vector2 = verts[(i - 1 + n) % n]
			var curr: Vector2 = verts[i]
			var next: Vector2 = verts[(i + 1) % n]
			# Convex ear in CCW polygon: cross >= 0
			var cross: float = (curr.x - prev.x) * (next.y - prev.y) - (curr.y - prev.y) * (next.x - prev.x)
			if cross <= 0.00001:
				continue
			var empty := true
			for j in range(n):
				if j == i or j == (i - 1 + n) % n or j == (i + 1) % n:
					continue
				if _point_in_tri(verts[j], prev, curr, next):
					empty = false
					break
			if not empty:
				continue
			tris.append([prev, curr, next])
			verts.remove_at(i)
			clipped = true
			break
		if not clipped:
			break
	if verts.size() == 3:
		tris.append([verts[0], verts[1], verts[2]])
	return tris


func _add_outline_ribbon(pts: Array, color: Color, thickness: float) -> void:
	# Single ArrayMesh border — hundreds of BoxMesh nodes break Godot web/WebGL.
	if pts.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nrm := Vector3.UP
	var y := 0.035
	var half := thickness * 0.5
	var n: int = pts.size()
	for i in range(n):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var ab: Vector2 = b - a
		if ab.length_squared() < 0.0004:
			continue
		var perp := Vector2(-ab.y, ab.x).normalized() * half
		var a0 := Vector3(a.x - perp.x, y, a.y - perp.y)
		var a1 := Vector3(a.x + perp.x, y, a.y + perp.y)
		var b0 := Vector3(b.x - perp.x, y, b.y - perp.y)
		var b1 := Vector3(b.x + perp.x, y, b.y + perp.y)
		st.set_normal(nrm); st.add_vertex(a0)
		st.set_normal(nrm); st.add_vertex(b0)
		st.set_normal(nrm); st.add_vertex(b1)
		st.set_normal(nrm); st.add_vertex(a0)
		st.set_normal(nrm); st.add_vertex(b1)
		st.set_normal(nrm); st.add_vertex(a1)
	var mesh := st.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = ThemeX.mat(color, 0.75, 0.05, 1.0)
	_board.add_child(mi)


func _add_region_washes() -> void:
	# Translucent region discs muddy / vanish on the web compat renderer.
	pass


func _add_ornament() -> void:
	# Sit on the south wood rail — keep clear of Persian Gulf waters.
	var plaque := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.4, 0.06, 0.42)
	plaque.mesh = box
	plaque.material_override = Assets.mat_tex("wood.png", Color(0.95, 0.85, 0.72), 0.65, 1.2)
	plaque.position = Vector3(0, 0.08, 10.05)
	_board.add_child(plaque)
	var title := Label3D.new()
	title.text = "امپراتوری راه‌آهن پارس"
	Fonts.apply_label3d(title, 34)
	title.pixel_size = 0.011
	title.position = Vector3(0, 0.22, 10.05)
	title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	title.modulate = ThemeX.CREAM
	title.outline_modulate = ThemeX.WOOD_DARK
	title.outline_size = 7
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text_direction = TextServer.DIRECTION_RTL
	_board.add_child(title)


func _add_city(city: Dictionary) -> void:
	var root := Node3D.new()
	root.name = str(city.id)
	root.position = Vector3(float(city.x), 0.04, float(city.z))
	# Soft contact shadow
	var shadow := MeshInstance3D.new()
	var scyl := CylinderMesh.new()
	scyl.top_radius = CITY_RING * 1.15
	scyl.bottom_radius = CITY_RING * 1.15
	scyl.height = 0.01
	shadow.mesh = scyl
	shadow.material_override = ThemeX.mat(Color(0, 0, 0, 0.22), 1.0, 0.0, 0.22)
	shadow.position.y = 0.002
	root.add_child(shadow)
	# Gold ring
	var ring := MeshInstance3D.new()
	var rcyl := CylinderMesh.new()
	rcyl.top_radius = CITY_RING
	rcyl.bottom_radius = CITY_RING
	rcyl.height = 0.035
	ring.mesh = rcyl
	ring.material_override = ThemeX.mat(ThemeX.GOLD, 0.4, 0.65)
	ring.position.y = 0.04
	root.add_child(ring)
	# Stone disc
	var base := MeshInstance3D.new()
	var bcyl := CylinderMesh.new()
	bcyl.top_radius = CITY_BASE
	bcyl.bottom_radius = CITY_BASE * 1.05
	bcyl.height = 0.06
	base.mesh = bcyl
	base.material_override = ThemeX.mat(ThemeX.WOOD_DARK.lightened(0.15), 0.8, 0.05)
	base.position.y = 0.07
	root.add_child(base)
	# Region gem
	var dome := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = CITY_GEM
	sphere.height = CITY_GEM * 1.6
	dome.mesh = sphere
	var region_c: Color = ThemeX.REGION.get(str(city.region), ThemeX.TEAL)
	var dm := ThemeX.mat(region_c, 0.35, 0.4)
	dm.emission_enabled = true
	dm.emission = region_c.lightened(0.2)
	dm.emission_energy_multiplier = 0.18
	dome.material_override = dm
	dome.position.y = 0.16
	root.add_child(dome)
	# Label
	var label_root := Node3D.new()
	label_root.position = Vector3(0, LABEL_Y, 0)
	root.add_child(label_root)
	_label_nodes.append(label_root)
	var label := Label3D.new()
	label.text = str(city.name_fa)
	Fonts.apply_label3d(label, 28 if _compact_labels else 34)
	label.pixel_size = 0.0095
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = ThemeX.INK
	label.outline_modulate = Color(1, 0.97, 0.9, 0.95)
	label.outline_size = 10
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.text_direction = TextServer.DIRECTION_RTL
	label.render_priority = 2
	label_root.add_child(label)
	if _compact_labels:
		label_root.visible = false
	var area := Area3D.new()
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.55
	col.shape = shape
	area.add_child(col)
	var cid := str(city.id)
	area.input_event.connect(func(_cam, event, _pos, _normal, _shape):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			city_tapped.emit(cid)
		elif event is InputEventScreenTouch and event.pressed:
			city_tapped.emit(cid)
	)
	root.add_child(area)
	_board.add_child(root)
	city_nodes[cid] = root


func _parallel_sign(route: Dictionary) -> float:
	# Offset twin routes that share the same city pair so they don't stack.
	var a := str(route.from)
	var b := str(route.to)
	var twins: Array = []
	for r in rules.routes:
		var fa := str(r.from)
		var tb := str(r.to)
		if (fa == a and tb == b) or (fa == b and tb == a):
			twins.append(str(r.id))
	twins.sort()
	if twins.size() < 2:
		return 0.0
	var idx := twins.find(str(route.id))
	if idx < 0:
		return 0.0
	return -0.5 + float(idx)


func _add_route(route: Dictionary) -> void:
	var a = rules.city_by_id(str(route.from))
	var b = rules.city_by_id(str(route.to))
	if a.is_empty() or b.is_empty():
		return
	var pa := Vector3(float(a.x), 0.07, float(a.z))
	var pb := Vector3(float(b.x), 0.07, float(b.z))
	var full := maxf((pb - pa).length(), 0.01)
	var dir := (pb - pa).normalized()
	# Inset scales with corridor length so short links stay tidy.
	var inset := minf(ROUTE_INSET, full * 0.28)
	inset = maxf(inset, 0.28)
	pa += dir * inset
	pb -= dir * inset
	var lateral := Vector3(-dir.z, 0.0, dir.x) * (PARALLEL_OFFSET * _parallel_sign(route))
	pa += lateral
	pb += lateral
	var mid := (pa + pb) * 0.5
	var length := maxf((pb - pa).length(), 0.01)
	var root := Node3D.new()
	root.name = str(route.id)
	root.position = mid
	# Yaw-only orientation — keeps every rail car flat and aligned.
	root.rotation = Vector3(0.0, atan2(dir.x, dir.z), 0.0)
	var colname := str(route.get("color", "gray"))
	var base_col: Color = ThemeX.ROUTE.get(colname, ThemeX.ROUTE["gray"])
	if str(route.get("gameType", "")) == "scenario_proposed":
		base_col = base_col.lerp(ThemeX.PARCHMENT, 0.28)
	var mat := ThemeX.mat(base_col, 0.42, 0.12)
	route_mats[str(route.id)] = mat
	var L := maxi(int(route.length), 1)
	# Even cars with a fixed visual gap — never let segments look crushed.
	var gap := SEG_GAP
	var seg_len := length / float(L)
	var usable := maxf(seg_len - gap, MIN_SEG * 0.85)
	if usable * float(L) + gap * float(L - 1) > length + 0.01:
		usable = maxf((length - gap * float(L - 1)) / float(L), 0.16)
	for i in range(L):
		var t := (float(i) + 0.5) / float(L) - 0.5
		var z := t * length
		var tie := MeshInstance3D.new()
		var tmesh := BoxMesh.new()
		tmesh.size = Vector3(TIE_W, 0.028, usable * 0.92)
		tie.mesh = tmesh
		tie.material_override = ThemeX.mat(ThemeX.WOOD.darkened(0.08), 0.9)
		tie.position = Vector3(0, 0.014, z)
		root.add_child(tie)
		var rail := MeshInstance3D.new()
		var rmesh := BoxMesh.new()
		rmesh.size = Vector3(RAIL_W, RAIL_H, usable * 0.78)
		rail.mesh = rmesh
		rail.material_override = mat
		rail.position = Vector3(0, 0.048, z)
		root.add_child(rail)
		for rail_side in [-0.05, 0.05]:
			var bar := MeshInstance3D.new()
			var bmesh := BoxMesh.new()
			bmesh.size = Vector3(BAR_W, 0.022, usable * 0.82)
			bar.mesh = bmesh
			bar.material_override = ThemeX.mat(Color("9aa4ad"), 0.35, 0.6)
			bar.position = Vector3(rail_side, 0.075, z)
			root.add_child(bar)
	var area := Area3D.new()
	var cshape := CollisionShape3D.new()
	var boxshape := BoxShape3D.new()
	boxshape.size = Vector3(0.65, 0.35, length)
	cshape.shape = boxshape
	area.add_child(cshape)
	var rid := str(route.id)
	area.input_event.connect(func(_cam, event, _pos, _normal, _shape):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			route_tapped.emit(rid)
		elif event is InputEventScreenTouch and event.pressed:
			route_tapped.emit(rid)
	)
	root.add_child(area)
	_board.add_child(root)
	route_nodes[rid] = root


func _claims_fingerprint() -> String:
	if rules == null:
		return ""
	var keys: Array = rules.claimed.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for k in keys:
		parts.append("%s:%s" % [str(k), str(rules.claimed[k])])
	return ",".join(parts)


func refresh_claims() -> void:
	if rules == null or _board == null or not is_instance_valid(_board):
		return
	# Drawing cards (and other non-claim turns) used to rebuild every wagon mesh
	# every time — that thrash can blank the WebGL board after a few picks.
	var fp := _claims_fingerprint()
	if fp == _claims_fp:
		return
	var prev_keys := {}
	for rid in wagon_nodes.keys():
		prev_keys[rid] = true
	_claims_fp = fp
	for rid in wagon_nodes.keys():
		var node = wagon_nodes[rid]
		if is_instance_valid(node):
			node.queue_free()
	wagon_nodes.clear()
	for rid in rules.claimed.keys():
		var pi: int = int(rules.claimed[rid])
		var p: Dictionary = rules.players[pi]
		var route = rules.route_by_id(rid)
		var a = rules.city_by_id(str(route.from))
		var b = rules.city_by_id(str(route.to))
		var pa := Vector3(float(a.x), 0.11, float(a.z))
		var pb := Vector3(float(b.x), 0.11, float(b.z))
		var dir := (pb - pa)
		if dir.length() < 0.001:
			dir = Vector3(0, 0, 1)
		else:
			dir = dir.normalized()
		# Keep tokens between city gems.
		pa += dir * 0.30
		pb -= dir * 0.30
		var color := Color(str(p.color))
		var holder := Node3D.new()
		var n := int(route.length)
		# Yaw only — never pitch/roll, so tokens stay flat on the board.
		var yaw := atan2(dir.x, dir.z)
		var animate := not prev_keys.has(rid)
		for i in range(n):
			var t := (float(i) + 0.5) / float(n)
			var wagon: Node3D = models.wagon_for_player(pi, color)
			wagon.position = pa.lerp(pb, t)
			wagon.rotation = Vector3(0.0, yaw, 0.0)
			if animate:
				var target_scale := wagon.scale
				wagon.scale = Vector3.ZERO
				holder.add_child(wagon)
				var tw := create_tween()
				tw.tween_property(wagon, "scale", target_scale, 0.22).set_delay(i * 0.035).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			else:
				holder.add_child(wagon)
		_board.add_child(holder)
		wagon_nodes[rid] = holder
		if route_mats.has(rid):
			var m: StandardMaterial3D = route_mats[rid].duplicate()
			m.albedo_color = color.lerp(ThemeX.GOLD_SOFT, 0.08)
			m.emission_enabled = true
			m.emission = color.lightened(0.2)
			m.emission_energy_multiplier = 0.45
			route_mats[rid] = m
			_reapply_route_mat(rid, m)
			# Widen claimed rail meshes once so ownership reads at distance.
			if route_nodes.has(rid) and not _widened_routes.has(rid):
				_widened_routes[rid] = true
				var rn: Node3D = route_nodes[rid]
				for ch in rn.get_children():
					if ch is MeshInstance3D and ch.mesh is BoxMesh:
						var bm := (ch.mesh as BoxMesh).duplicate() as BoxMesh
						if bm.size.x >= RAIL_W * 0.9 and bm.size.x <= RAIL_W * 1.8:
							bm.size = Vector3(RAIL_W * 1.85, RAIL_H * 1.6, bm.size.z)
							(ch as MeshInstance3D).mesh = bm
							(ch as MeshInstance3D).position.y = 0.07


func _reapply_route_mat(rid: String, m: StandardMaterial3D) -> void:
	if not route_nodes.has(rid):
		return
	var rn: Node3D = route_nodes[rid]
	for ch in rn.get_children():
		if ch is MeshInstance3D:
			var mi := ch as MeshInstance3D
			var mesh = mi.mesh
			if mesh is BoxMesh:
				var sx := (mesh as BoxMesh).size.x
				# Recolor both rail bars and wooden ties so claims read clearly.
				if sx >= BAR_W * 0.8 and sx <= TIE_W * 1.2:
					mi.material_override = m


func highlight_city(city_id: String, on: bool) -> void:
	if not city_nodes.has(city_id):
		return
	var n: Node3D = city_nodes[city_id]
	var tw := create_tween()
	tw.tween_property(n, "scale", Vector3.ONE * (1.22 if on else 1.0), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func highlight_route(route_id: String, on: bool) -> void:
	if not route_nodes.has(route_id):
		return
	var n: Node3D = route_nodes[route_id]
	n.scale = Vector3(1.12 if on else 1.0, 1.0, 1.0)
