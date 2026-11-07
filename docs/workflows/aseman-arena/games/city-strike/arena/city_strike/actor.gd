## What the person's character and the AI fighters share: a body that
## walks and falls, health and armour, a hitscan weapon, the animated model
## (Quaternius' robot, CC0, with Kenney's blaster in its hand) and dying.
extends CharacterBody3D

signal died(actor, killer, headshot: bool)
signal damaged(actor, amount: float, from: Vector3)

const Models = preload("res://arena/city_strike/models.gd")
const Weapon = preload("res://arena/city_strike/weapon.gd")

const GRAVITY := 22.0
const HEIGHT := 1.8
const HEAD_Y := 1.5           # above the feet: a hit higher than this is a headshot
const ROBOT_UNITS := 4.4      # the robot model's height in its own units
const GUN_LENGTH := 0.62

var team := 0
var display_name := "Fighter"
var max_health := 100.0
var health := 100.0
var armor := 0.0
var alive := true
var weapon
var model: Node3D
var anim: AnimationPlayer
var _anim_now := ""
var tint := Color(1, 1, 1)
var _gun: Node3D
var _gun_len := 1.0


func setup_body(color: Color) -> void:
	tint = color
	add_to_group("actors")
	collision_layer = 2
	collision_mask = 1 | 2
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = HEIGHT
	shape.shape = cap
	shape.position.y = HEIGHT / 2
	add_child(shape)
	_build_model(color)
	weapon = Weapon.new()
	weapon.owner_actor = self
	add_child(weapon)


func _build_model(color: Color) -> void:
	var robot := Models.instance("quaternius/robot.glb")
	if robot:
		# Its rigid parts ride on bones, so mesh bounds do not tell its size:
		# by its skeleton it stands ROBOT_UNITS tall (head bone at 2.97).
		robot.scale = Vector3.ONE * (HEIGHT / ROBOT_UNITS)
		model = Node3D.new()
		model.add_child(robot)
		_tint(robot, color)
		anim = robot.find_child("AnimationPlayer", true, false)
		var skel: Skeleton3D = robot.find_child("Skeleton3D", true, false)
		if skel and skel.find_bone("Hand.R") >= 0:
			var hand := BoneAttachment3D.new()
			hand.bone_name = "Hand.R"
			skel.add_child(hand)
			var gun := Models.instance("kenney-fps/blaster-repeater.glb")
			if gun:
				_gun = Node3D.new()
				hand.add_child(_gun)
				_gun.add_child(gun)
				_gun_len = maxf(Models.bounds(gun).size.z, 0.01)
	else:
		model = Models.fallback_character(color)
	add_child(model)
	play("Idle")
	if _gun:
		_fit_gun.call_deferred()


## The blaster hangs from the hand bone, under the skeleton's own scale:
## size it in world space once it is in the tree.
func _fit_gun() -> void:
	if not is_inside_tree() or _gun == null:
		return
	var world_scale := _gun.global_transform.basis.get_scale().x
	if world_scale > 0.0:
		_gun.scale *= (GUN_LENGTH / _gun_len) / world_scale
	_gun.rotation_degrees = Vector3(0, 180, 0)


## Shades the robot's body in the team colour, keeping its own look.
func _tint(node: Node, color: Color) -> void:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var base = m.get_active_material(s)
			if base is StandardMaterial3D:
				var copy: StandardMaterial3D = base.duplicate()
				if copy.albedo_color.s > 0.25 or copy.albedo_color.v > 0.6:
					copy.albedo_color = copy.albedo_color.lerp(color, 0.7)
				m.set_surface_override_material(s, copy)


func play(name: String, speed: float = 1.0) -> void:
	if anim == null or _anim_now == name:
		return
	if anim.has_animation(name):
		anim.play(name, 0.18, speed)
		_anim_now = name
	else:
		# Imported clip names can carry their library prefix.
		for n in anim.get_animation_list():
			if n.ends_with(name):
				anim.play(n, 0.18, speed)
				_anim_now = name
				return


func head_position() -> Vector3:
	return global_position + Vector3(0, HEAD_Y + 0.12, 0)


func chest_position() -> Vector3:
	return global_position + Vector3(0, 1.15, 0)


func take_damage(amount: float, from: Vector3, attacker = null, headshot: bool = false) -> void:
	if not alive:
		return
	var absorbed: float = min(armor, amount * 0.6)
	armor -= absorbed
	health -= amount - absorbed
	damaged.emit(self, amount, from)
	if health <= 0.0:
		health = 0.0
		die(attacker, headshot)


func heal(amount: float) -> void:
	health = min(max_health, health + amount)


func die(killer = null, headshot: bool = false) -> void:
	if not alive:
		return
	alive = false
	collision_layer = 0
	play("Death")
	if anim == null and model:
		var tw := create_tween()
		tw.tween_property(model, "rotation_degrees:x", -90.0, 0.4)
	died.emit(self, killer, headshot)


func apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0:
		velocity.y = 0.0


## Turns the model to face a horizontal direction.
func face(dir: Vector3, delta: float, rate: float = 12.0) -> void:
	if dir.length_squared() < 0.0001 or model == null:
		return
	var want := atan2(dir.x, dir.z)
	model.rotation.y = lerp_angle(model.rotation.y, want, min(1.0, delta * rate))
