## A hitscan rifle: magazine and reserve, rate of fire, spread that grows
## with movement and sustained fire and shrinks when aiming, damage that
## falls off with range, headshots, tracers, a muzzle flash and impacts.
extends Node3D

signal fired(origin: Vector3, hit: Dictionary)

var owner_actor
var fx_parent: Node   # where tracers and impacts go (the game's root)
var magazine := 30
var mag_size := 30
var reserve := 120
var fire_interval := 0.105
var reload_time := 1.7
var damage := 22.0
var head_multiplier := 2.2
var base_spread := 0.012        # radians
var spread := 0.012
var range_m := 140.0
var shots := 0
var hits := 0
var headshots := 0
var reloading := false
var _cooldown := 0.0
var _reload_left := 0.0
var _flash: OmniLight3D


func _ready() -> void:
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.75, 0.4)
	_flash.omni_range = 5.0
	_flash.light_energy = 0.0
	add_child(_flash)


func _process(delta: float) -> void:
	_cooldown = max(0.0, _cooldown - delta)
	spread = lerp(spread, base_spread, min(1.0, delta * 5.0))
	if _flash.light_energy > 0.0:
		_flash.light_energy = max(0.0, _flash.light_energy - delta * 60.0)
	if reloading:
		_reload_left -= delta
		if _reload_left <= 0.0:
			var take: int = min(mag_size - magazine, reserve)
			magazine += take
			reserve -= take
			reloading = false


func can_fire() -> bool:
	return not reloading and _cooldown <= 0.0 and magazine > 0


func reload() -> bool:
	if reloading or magazine == mag_size or reserve <= 0:
		return false
	reloading = true
	_reload_left = reload_time
	return true


func reload_progress() -> float:
	return 1.0 - _reload_left / reload_time if reloading else 1.0


## Fires one round from [origin] towards [target] with [extra_spread] on top
## of the weapon's own (movement, the AI's aim error). Returns what it hit:
## {"collider", "position", "normal", "headshot", "damage"} or {}.
func fire(origin: Vector3, target: Vector3, extra_spread: float = 0.0) -> Dictionary:
	if not can_fire():
		if magazine <= 0 and not reloading:
			reload()
		return {}
	magazine -= 1
	shots += 1
	_cooldown = fire_interval
	var dir := (target - origin).normalized()
	var s := spread + extra_spread
	# A random direction inside the cone.
	var right := dir.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	var up := right.cross(dir).normalized()
	var r := sqrt(randf()) * s
	var a := randf() * TAU
	dir = (dir + right * cos(a) * r + up * sin(a) * r).normalized()
	spread = min(spread + 0.006, base_spread * 4.0)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * range_m)
	q.exclude = [owner_actor.get_rid()]
	q.collision_mask = 1 | 2
	var hit := space.intersect_ray(q)
	var end := origin + dir * range_m
	var out := {}
	if hit:
		end = hit.position
		out = {"collider": hit.collider, "position": hit.position, "normal": hit.normal, "headshot": false, "damage": 0.0}
		var c = hit.collider
		if c != null and c.has_method("take_damage") and c.alive:
			var dist: float = origin.distance_to(hit.position)
			var dmg: float = damage * clampf(1.15 - dist / 160.0, 0.55, 1.0)
			var head: bool = hit.position.y >= c.global_position.y + c.HEAD_Y
			if head:
				dmg *= head_multiplier
				headshots += 1
			hits += 1
			out.headshot = head
			out.damage = dmg
			c.take_damage(dmg, origin, owner_actor, head)
		else:
			_impact(hit.position, hit.normal)
	_flash.global_position = origin
	_flash.light_energy = 3.0
	_tracer(origin, end)
	fired.emit(origin, out)
	return out


func accuracy() -> float:
	return float(hits) / shots if shots > 0 else 0.0


func _tracer(from: Vector3, to: Vector3) -> void:
	if not is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var mi := MeshInstance3D.new()
	var len := from.distance_to(to)
	var cm := CylinderMesh.new()
	cm.top_radius = 0.012
	cm.bottom_radius = 0.012
	cm.height = len
	cm.radial_segments = 4
	cm.rings = 1
	mi.mesh = cm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.85, 0.5, 0.8)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx().add_child(mi)
	mi.global_position = (from + to) / 2
	var d := (to - from).normalized()
	if abs(d.dot(Vector3.UP)) < 0.999:
		mi.look_at(to, Vector3.UP)
		mi.rotate_object_local(Vector3.RIGHT, PI / 2)
	var tw := mi.create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, 0.08)
	tw.tween_callback(mi.queue_free)


func _impact(at: Vector3, normal: Vector3) -> void:
	if not is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 10
	p.lifetime = 0.35
	p.explosiveness = 1.0
	p.direction = normal
	p.spread = 35.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 5.0
	p.gravity = Vector3(0, -9.8, 0)
	p.scale_amount_min = 0.03
	p.scale_amount_max = 0.06
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 4
	sm.rings = 2
	p.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.8, 0.45)
	p.material_override = m
	_fx().add_child(p)
	p.global_position = at + normal * 0.05
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)


func _fx() -> Node:
	return fx_parent if fx_parent else owner_actor.get_parent()
