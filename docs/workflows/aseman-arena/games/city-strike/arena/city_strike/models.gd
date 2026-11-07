## Model loading for City Strike: the downloaded models (assets.json) when
## the build has them, measured and fitted to real-world sizes, and
## good-looking stand-ins made here when it does not (offline builds, tests).
extends RefCounted

const ROOT := "res://arena/city_strike/models/"

static var _cache := {}


## The model at [rel] (under models/) as a fresh instance, or null.
static func instance(rel: String) -> Node3D:
	var path := ROOT + rel
	if not _cache.has(path):
		_cache[path] = load(path) if ResourceLoader.exists(path) else null
	var packed = _cache[path]
	if packed == null:
		return null
	return packed.instantiate()


static func has(rel: String) -> bool:
	return ResourceLoader.exists(ROOT + rel)


## The bounds of every mesh under [node], in [node]'s own space.
static func bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack := [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is VisualInstance3D and n != node:
			var b: AABB = xf * (n as VisualInstance3D).get_aabb()
			out = b if first else out.merge(b)
			first = false
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
	return out


## Scales [node] uniformly so its height is [height], and sets it on the ground.
static func fit_height(node: Node3D, height: float) -> void:
	var b := bounds(node)
	if b.size.y <= 0.0001:
		return
	var k := height / b.size.y
	node.scale *= k
	node.position.y -= b.position.y * k


## Scales [node] uniformly so its larger horizontal side is [size].
static func fit_footprint(node: Node3D, size: float) -> void:
	var b := bounds(node)
	var side: float = max(b.size.x, b.size.z)
	if side <= 0.0001:
		return
	var k := size / side
	node.scale *= k
	node.position.y -= b.position.y * k


static func mat(color: Color, rough: float = 0.6, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m


static func box(size: Vector3, color: Color, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat(color)
	mi.position = pos
	return mi


## A stand-in car: body, cabin, wheels.
static func fallback_car(color: Color) -> Node3D:
	var n := Node3D.new()
	n.add_child(box(Vector3(1.9, 0.7, 4.3), color, Vector3(0, 0.65, 0)))
	n.add_child(box(Vector3(1.7, 0.6, 2.2), color.darkened(0.2), Vector3(0, 1.25, -0.2)))
	for x in [-0.9, 0.9]:
		for z in [-1.4, 1.4]:
			var w := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.36
			cm.bottom_radius = 0.36
			cm.height = 0.28
			w.mesh = cm
			w.material_override = mat(Color(0.05, 0.05, 0.05), 0.9)
			w.rotation_degrees.z = 90
			w.position = Vector3(x, 0.36, z)
			n.add_child(w)
	return n


## A stand-in character: a visor-helmeted body in team colours.
static func fallback_character(color: Color) -> Node3D:
	var n := Node3D.new()
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.32
	cap.height = 1.25
	body.mesh = cap
	body.material_override = mat(color, 0.5)
	body.position.y = 0.95
	n.add_child(body)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	head.mesh = sm
	head.material_override = mat(color.lightened(0.2), 0.4)
	head.position.y = 1.68
	n.add_child(head)
	var visor := box(Vector3(0.3, 0.1, 0.12), Color(0.1, 0.8, 1.0), Vector3(0, 1.7, 0.16))
	var vm: StandardMaterial3D = visor.material_override
	vm.emission_enabled = true
	vm.emission = Color(0.1, 0.8, 1.0)
	n.add_child(visor)
	return n


## A facade texture for a tower: rows of windows, some lit.
static func facade_texture(seed: int, glass: Color, frame: Color) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var w := 64
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(frame)
	for row in range(0, h, 8):
		for col in range(0, w, 8):
			var lit := rng.randf() < 0.22
			var c := glass.lerp(Color(1.0, 0.85, 0.55), 0.85) if lit else glass.darkened(rng.randf_range(0.0, 0.35))
			for y in range(row + 2, row + 7):
				for x in range(col + 1, col + 7):
					img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
