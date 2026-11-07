## The city: a 13 × 13 grid of 12 m cells. Every fourth row and column is a
## road (a ring road around the edge and two avenues each way); the 3 × 3
## blocks between them are glass towers, shops and parking lots, with a
## plaza and its fountain in the middle. Sidewalks carry street furniture,
## cars park along the kerbs and a little traffic circles the plaza.
##
## Everything solid gets a collision box, and the same boxes mark the
## navigation grid (AStarGrid2D, 2 m cells) the AI walks on.
extends Node3D

const Models = preload("res://arena/city_strike/models.gd")

const CELL := 12.0
const N := 13
const HALF := CELL * N / 2.0           # 78 m: the city spans ±HALF
const NAV := 2.0                        # navigation cell, metres
const NAV_N := int(CELL * N / NAV)      # 78 × 78 navigation cells

var seed_value := 7
var rng := RandomNumberGenerator.new()
var nav := AStarGrid2D.new()
var cover_cells: Array[Vector2i] = []   # walkable cells beside something solid
var road_points: Array[Vector3] = []    # walkable points on roads (patrols, spawns)
var spawn_player := Vector3.ZERO
var spawn_enemies: Array[Vector3] = []
var traffic: Array = []                 # [node, path points, index, speed]
var _solids: Array[AABB] = []

var _asphalt: StandardMaterial3D
var _sidewalk: StandardMaterial3D


func build(p_seed: int = 7) -> void:
	seed_value = p_seed
	rng.seed = p_seed
	_asphalt = Models.mat(Color(0.16, 0.165, 0.18), 0.9)
	_sidewalk = Models.mat(Color(0.55, 0.55, 0.53), 0.85)
	nav.region = Rect2i(0, 0, NAV_N, NAV_N)
	nav.cell_size = Vector2(NAV, NAV)
	nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	nav.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	nav.update()
	_ground()
	for i in N:
		for j in N:
			if is_road(i) or is_road(j):
				_road_cell(i, j)
	var kinds := ["towers", "shops", "towers", "parking", "plaza", "shops", "towers", "shops", "parking"]
	for b in 9:
		_block(b % 3, b / 3, kinds[b])
	_bounds()
	_parked_cars()
	_traffic()
	_mark_nav()
	_spawns()


static func is_road(i: int) -> bool:
	return i % 4 == 0


static func cell_center(i: int, j: int) -> Vector3:
	return Vector3((i + 0.5) * CELL - HALF, 0, (j + 0.5) * CELL - HALF)


# ---------------------------------------------------------------------------
# Ground and roads
# ---------------------------------------------------------------------------

func _ground() -> void:
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(HALF * 2 + 120, HALF * 2 + 120)
	g.mesh = pm
	g.material_override = Models.mat(Color(0.2, 0.24, 0.18), 1.0)
	g.position.y = -0.02
	add_child(g)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(HALF * 2 + 120, 1, HALF * 2 + 120)
	shape.shape = bs
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)


func _road_cell(i: int, j: int) -> void:
	var c := cell_center(i, j)
	var crossing := is_road(i) and is_road(j)
	var along_x := is_road(j) and not is_road(i)      # a road running east-west
	var rel := "kenney-city/road-intersection.glb" if crossing else (
		"kenney-city/road-straight-lightposts.glb" if (i + j) % 3 == 0 else "kenney-city/road-straight.glb")
	var tile := Models.instance(rel)
	if tile:
		# Flatter than the kit's own proportions: kerbs of a real street.
		tile.scale = Vector3(CELL, CELL * 0.35, CELL)
		tile.position = c
		if along_x:
			tile.rotation_degrees.y = 90
		add_child(tile)
	else:
		var slab := Models.box(Vector3(CELL, 0.06, CELL), Color(0.16, 0.165, 0.18), c + Vector3(0, 0.03, 0))
		slab.material_override = _asphalt
		add_child(slab)
		if not crossing:
			var line := Models.box(Vector3(0.25, 0.07, CELL * 0.6) if not along_x else Vector3(CELL * 0.6, 0.07, 0.25), Color(0.9, 0.85, 0.5), c + Vector3(0, 0.04, 0))
			add_child(line)
	road_points.append(c)


## Invisible walls at the edge of the city.
func _bounds() -> void:
	for side in 4:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		var horizontal := side < 2
		bs.size = Vector3(HALF * 2 + 4, 12, 2) if horizontal else Vector3(2, 12, HALF * 2 + 4)
		shape.shape = bs
		body.add_child(shape)
		var s := -1 if side % 2 == 0 else 1
		body.position = Vector3(0, 6, s * (HALF + 1)) if horizontal else Vector3(s * (HALF + 1), 6, 0)
		add_child(body)


# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------

func _block(bx: int, bz: int, kind: String) -> void:
	var i0 := bx * 4 + 1
	var j0 := bz * 4 + 1
	var center := cell_center(i0 + 1, j0 + 1)
	# The sidewalk slab under the whole block.
	var slab := Models.box(Vector3(CELL * 3, 0.16, CELL * 3), Color(0.55, 0.55, 0.53), center + Vector3(0, 0.08, 0))
	slab.material_override = _sidewalk
	add_child(slab)
	match kind:
		"towers":
			var lots := [[-1, -1], [1, -1], [-1, 1], [1, 1]]
			for k in lots.size():
				if rng.randf() < 0.25 and k > 0:
					_props_cluster(center + Vector3(lots[k][0] * 8.5, 0.16, lots[k][1] * 8.5), 3)
					continue
				var w := rng.randf_range(11.0, 13.5)
				var h := rng.randf_range(22.0, 58.0)
				_tower(center + Vector3(lots[k][0] * 9.0, 0.16, lots[k][1] * 9.0), Vector3(w, h, w))
		"shops":
			for di in 3:
				for dj in 3:
					if di == 1 and dj == 1:
						_props_cluster(cell_center(i0 + di, j0 + dj) + Vector3(0, 0.16, 0), 4)
						continue
					if (di + dj) % 2 == 1 and rng.randf() < 0.5:
						_props_cluster(cell_center(i0 + di, j0 + dj) + Vector3(0, 0.16, 0), 2)
						continue
					_shop(cell_center(i0 + di, j0 + dj) + Vector3(0, 0.16, 0), (di + dj * 3 + bx) % 4)
		"parking":
			_shop(cell_center(i0, j0) + Vector3(0, 0.16, 0), -1)
			for row in 3:
				for col in 4:
					if rng.randf() < 0.62:
						var p := center + Vector3(-9 + col * 6.0, 0.16, -6 + row * 8.0)
						_car(p, PI / 2 + (PI if row % 2 else 0.0), true)
			_props_cluster(center + Vector3(12, 0.16, 12), 3)
		"plaza":
			var fountain := Models.instance("kenney-city/pavement-fountain.glb")
			if fountain:
				fountain.scale = Vector3.ONE * CELL
				fountain.position = center + Vector3(0, 0.16, 0)
				add_child(fountain)
			else:
				add_child(Models.box(Vector3(6, 1.0, 6), Color(0.6, 0.62, 0.66), center + Vector3(0, 0.66, 0)))
			_solid(AABB(center + Vector3(-3.2, 0, -3.2), Vector3(6.4, 1.2, 6.4)))
			for k in 4:
				var a := TAU * k / 4.0 + PI / 4
				var tp := center + Vector3(cos(a) * 13.0, 0.16, sin(a) * 13.0)
				var tree := Models.instance("kenney-city/grass-trees-tall.glb")
				if tree:
					tree.scale = Vector3.ONE * 8.0
					tree.position = tp
					add_child(tree)
					_solid(AABB(tp + Vector3(-1.2, 0, -1.2), Vector3(2.4, 6, 2.4)))
				_props_cluster(center + Vector3(cos(a + PI / 4) * 9.0, 0.16, sin(a + PI / 4) * 9.0), 3)


## A glass tower with a lit facade, a podium and a roof crown.
func _tower(base: Vector3, size: Vector3) -> void:
	var glass_colors := [Color(0.25, 0.38, 0.5), Color(0.3, 0.32, 0.36), Color(0.22, 0.3, 0.32), Color(0.35, 0.3, 0.28)]
	var glass: Color = glass_colors[rng.randi_range(0, 3)]
	var frame := Color(0.12, 0.13, 0.15).lerp(Color(0.6, 0.58, 0.55), rng.randf_range(0.0, 0.6))
	var m := StandardMaterial3D.new()
	m.albedo_texture = Models.facade_texture(rng.randi(), glass, frame)
	m.uv1_scale = Vector3(size.x / 8.0, size.y / 16.0, 1)
	m.uv1_triplanar = false
	m.roughness = 0.25
	m.metallic = 0.4
	m.emission_enabled = true
	m.emission_texture = m.albedo_texture
	m.emission_energy_multiplier = 0.35
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	body.mesh = bm
	body.material_override = m
	body.position = base + Vector3(0, size.y / 2, 0)
	add_child(body)
	var podium := Models.box(Vector3(size.x + 1.2, 4.0, size.z + 1.2), frame.darkened(0.2), base + Vector3(0, 2.0, 0))
	add_child(podium)
	add_child(Models.box(Vector3(size.x * 0.6, 3.0, size.z * 0.6), frame.darkened(0.35), base + Vector3(0, size.y + 1.5, 0)))
	var beacon := OmniLight3D.new()
	beacon.light_color = Color(1.0, 0.2, 0.15)
	beacon.light_energy = 2.0
	beacon.omni_range = 6.0
	beacon.position = base + Vector3(0, size.y + 3.4, 0)
	add_child(beacon)
	_solid(AABB(base + Vector3(-(size.x + 1.2) / 2, 0, -(size.z + 1.2) / 2), Vector3(size.x + 1.2, size.y, size.z + 1.2)))


## A low building from Kenney's city kit (a stand-in box without it).
func _shop(at: Vector3, variant: int) -> void:
	var rels := ["kenney-city/building-small-a.glb", "kenney-city/building-small-b.glb", "kenney-city/building-small-c.glb", "kenney-city/building-small-d.glb"]
	var rel: String = "kenney-city/building-garage.glb" if variant < 0 else rels[variant]
	var b := Models.instance(rel)
	var height := 11.0
	if b:
		b.scale = Vector3.ONE * CELL * 0.92
		b.position = at
		b.rotation_degrees.y = 90.0 * rng.randi_range(0, 3)
		add_child(b)
		height = Models.bounds(b).size.y * b.scale.y
	else:
		var colors := [Color(0.7, 0.45, 0.35), Color(0.55, 0.6, 0.7), Color(0.8, 0.75, 0.6), Color(0.5, 0.55, 0.45)]
		height = rng.randf_range(6.0, 10.0)
		add_child(Models.box(Vector3(10, height, 10), colors[abs(variant) % 4], at + Vector3(0, height / 2, 0)))
	_solid(AABB(at + Vector3(-5.2, 0, -5.2), Vector3(10.4, max(height, 4.0), 10.4)))


## Street furniture that doubles as cover.
func _props_cluster(at: Vector3, count: int) -> void:
	var kinds := [
		["metal_trash_can/metal_trash_can.gltf", 1.0, Vector3(0.7, 1.0, 0.7)],
		["barrel/barrel.gltf", 1.0, Vector3(0.7, 1.0, 0.7)],
		["cardboard_box/cardboard_box.gltf", 0.7, Vector3(0.9, 0.7, 0.9)],
		["street_seating/street_seating.gltf", 0.9, Vector3(2.4, 0.9, 1.0)],
		["aircon_unit/aircon_unit.gltf", 1.2, Vector3(1.2, 1.2, 0.8)],
		["old_tyre/old_tyre.gltf", 0.5, Vector3(0.9, 0.5, 0.9)],
	]
	for k in count:
		var kind: Array = kinds[rng.randi_range(0, kinds.size() - 1)]
		var p := at + Vector3(rng.randf_range(-3.5, 3.5), 0, rng.randf_range(-3.5, 3.5))
		var node := Models.instance(kind[0])
		var size: Vector3 = kind[2]
		if node:
			Models.fit_height(node, kind[1])
			node.position += p
			node.rotation.y = rng.randf_range(0, TAU)
			add_child(node)
		else:
			add_child(Models.box(size, Color(0.35, 0.33, 0.3), p + Vector3(0, size.y / 2, 0)))
		_solid(AABB(p - Vector3(size.x / 2, 0, size.z / 2), size), true)
	# A low concrete barrier: the classic cover.
	var bar := Models.box(Vector3(3.0, 1.05, 0.6), Color(0.62, 0.62, 0.6), at + Vector3(0, 0.52, 4.2))
	bar.rotation.y = rng.randf_range(-0.4, 0.4)
	add_child(bar)
	_solid(AABB(at + Vector3(-1.6, 0, 3.8), Vector3(3.2, 1.05, 0.9)), true)


func _car(at: Vector3, yaw: float, solid: bool) -> Node3D:
	var rels := ["kenney-racing/vehicle-truck-red.glb", "kenney-racing/vehicle-truck-yellow.glb", "kenney-racing/vehicle-truck-green.glb", "kenney-racing/vehicle-truck-purple.glb", "covered_car/covered_car.gltf"]
	var rel: String = rels[rng.randi_range(0, rels.size() - 1)]
	var car := Models.instance(rel)
	if car:
		Models.fit_footprint(car, 4.4)
		var holder := Node3D.new()
		holder.add_child(car)
		car = holder
	else:
		car = Models.fallback_car(Color.from_hsv(rng.randf(), 0.6, 0.7))
	car.position = at
	car.rotation.y = yaw
	add_child(car)
	if solid:
		var sz := Vector3(2.0, 1.5, 4.4)
		var xf := Basis(Vector3.UP, yaw)
		var ext: Vector3 = (xf * sz).abs()
		_solid(AABB(at - Vector3(ext.x / 2, 0, ext.z / 2), Vector3(ext.x, 1.5, ext.z)), true)
	return car


## Cars parked along the avenues' kerbs.
func _parked_cars() -> void:
	for i in N:
		for j in N:
			var road_i := is_road(i)
			var road_j := is_road(j)
			if road_i == road_j or rng.randf() > 0.3:
				continue
			var c := cell_center(i, j)
			if road_i:
				_car(c + Vector3(4.3 * (1 if rng.randf() < 0.5 else -1), 0.02, rng.randf_range(-3, 3)), 0.0, true)
			else:
				_car(c + Vector3(rng.randf_range(-3, 3), 0.02, 4.3 * (1 if rng.randf() < 0.5 else -1)), PI / 2, true)


## Three cars circling the plaza on the inner avenues.
func _traffic() -> void:
	var a := 4.0 * CELL - HALF + CELL / 2.0
	var b := 8.0 * CELL - HALF + CELL / 2.0
	var lane := 2.4
	var loop: Array[Vector3] = [Vector3(a + lane, 0.02, a + lane), Vector3(b - lane, 0.02, a + lane), Vector3(b - lane, 0.02, b - lane), Vector3(a + lane, 0.02, b - lane)]
	for k in 3:
		var car := _car(loop[k], 0.0, false)
		var body := AnimatableBody3D.new()
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(2.0, 1.5, 4.4)
		shape.shape = bs
		shape.position.y = 0.75
		body.add_child(shape)
		car.add_child(body)
		traffic.append([car, loop, (k + 1) % 4, 9.0])


func _process(delta: float) -> void:
	for t in traffic:
		var car: Node3D = t[0]
		var loop: Array = t[1]
		var target: Vector3 = loop[t[2]]
		var to := target - car.position
		to.y = 0
		if to.length() < 0.5:
			t[2] = (t[2] + 1) % loop.size()
			continue
		var dir := to.normalized()
		var want := atan2(dir.x, dir.z)
		car.rotation.y = lerp_angle(car.rotation.y, want, min(1.0, delta * 4.0))
		var speed: float = t[3]
		# Stop for anyone in front.
		for actor in get_tree().get_nodes_in_group("actors"):
			var rel: Vector3 = actor.global_position - car.position
			if rel.length() < 7.0 and rel.normalized().dot(dir) > 0.6:
				speed = 0.0
		car.position += dir * min(speed * delta, to.length())


# ---------------------------------------------------------------------------
# Collision and navigation
# ---------------------------------------------------------------------------

func _solid(box: AABB, low: bool = false) -> void:
	_solids.append(box)
	var body := StaticBody3D.new()
	body.set_meta("cover", low)
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	body.add_child(shape)
	body.position = box.get_center()
	add_child(body)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(clampi(int((p.x + HALF) / NAV), 0, NAV_N - 1), clampi(int((p.z + HALF) / NAV), 0, NAV_N - 1))


func cell_to_world(c: Vector2i) -> Vector3:
	return Vector3(c.x * NAV - HALF + NAV / 2, 0.1, c.y * NAV - HALF + NAV / 2)


func _mark_nav() -> void:
	var margin := 0.5
	for b in _solids:
		var c0 := world_to_cell(b.position - Vector3(margin, 0, margin))
		var c1 := world_to_cell(b.end + Vector3(margin, 0, margin))
		for x in range(c0.x, c1.x + 1):
			for y in range(c0.y, c1.y + 1):
				nav.set_point_solid(Vector2i(x, y), true)
	for x in NAV_N:
		for y in NAV_N:
			var c := Vector2i(x, y)
			if nav.is_point_solid(c):
				continue
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				if nav.is_in_boundsv(n) and nav.is_point_solid(n):
					cover_cells.append(c)
					break


## A walkable path from [from] to [to], as world points.
func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var a := nearest_free(world_to_cell(from))
	var b := nearest_free(world_to_cell(to))
	var out := PackedVector3Array()
	for c in nav.get_id_path(a, b):
		out.append(cell_to_world(c))
	return out


func nearest_free(c: Vector2i) -> Vector2i:
	if not nav.is_point_solid(c):
		return c
	for r in range(1, 8):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n := c + Vector2i(dx, dy)
				if nav.is_in_boundsv(n) and not nav.is_point_solid(n):
					return n
	return c


func is_walkable(p: Vector3) -> bool:
	return not nav.is_point_solid(world_to_cell(p))


func _spawns() -> void:
	# The person starts on the south-west ring road; the enemies come from
	# the far side of the city and its avenues.
	spawn_player = cell_center(0, 12) + Vector3(2, 0.2, -2)
	for p in road_points:
		if p.distance_to(spawn_player) > 70.0:
			spawn_enemies.append(p + Vector3(0, 0.2, 0))
