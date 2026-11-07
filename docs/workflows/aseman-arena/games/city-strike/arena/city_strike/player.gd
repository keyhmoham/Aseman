## The person's fighter: an over-the-shoulder third-person camera on a
## spring arm (it never clips through walls), walking, sprinting and
## jumping, aiming down the sight, firing at what the crosshair covers and
## reloading. Keyboard and mouse, a gamepad, or the HUD's touch controls.
extends "res://arena/city_strike/actor.gd"

const WALK := 4.6
const RUN := 7.4
const AIM_WALK := 2.6
const JUMP := 7.2

var yaw_node: Node3D
var pitch_node: Node3D
var arm: SpringArm3D
var camera: Camera3D
var aiming := false
var sprinting := false
var sensitivity := 0.0032
var regen_delay := 0.0

# Set by the HUD's touch controls.
var touch_move := Vector2.ZERO
var touch_fire := false
var touch_aim := false

var _pitch := -0.12
var _recoil := 0.0


func setup(color: Color) -> void:
	display_name = "You"
	setup_body(color)
	yaw_node = Node3D.new()
	yaw_node.position.y = 1.55
	add_child(yaw_node)
	pitch_node = Node3D.new()
	yaw_node.add_child(pitch_node)
	arm = SpringArm3D.new()
	arm.spring_length = 3.4
	arm.margin = 0.25
	arm.collision_mask = 1
	arm.position = Vector3(0.62, 0.15, 0)
	var probe := SphereShape3D.new()
	probe.radius = 0.2
	arm.shape = probe
	arm.add_excluded_object(get_rid())
	pitch_node.add_child(arm)
	camera = Camera3D.new()
	camera.fov = 72
	camera.current = true
	camera.far = 600
	arm.add_child(camera)
	# Yaw 0 looks towards -z; the spring arm extends along +z behind it.
	weapon.base_spread = 0.014
	max_health = 100.0
	health = 100.0
	armor = 25.0


func look(delta_px: Vector2) -> void:
	var k := sensitivity * (0.55 if aiming else 1.0)
	yaw_node.rotation.y -= delta_px.x * k
	_pitch = clamp(_pitch - delta_px.y * k, -1.2, 0.9)


func _unhandled_input(event: InputEvent) -> void:
	if not alive:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		look(event.relative)


func aim_direction() -> Vector3:
	return -camera.global_transform.basis.z


## The point the crosshair covers.
func aim_point() -> Vector3:
	var from := camera.global_position
	var to := from + aim_direction() * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	q.collision_mask = 1 | 2
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if hit else to


func muzzle() -> Vector3:
	var b := yaw_node.global_transform.basis
	return global_position + Vector3(0, 1.38, 0) + b.x * 0.32 - b.z * 0.45


func _physics_process(delta: float) -> void:
	apply_gravity(delta)
	if not alive:
		velocity.x = move_toward(velocity.x, 0, delta * 20)
		velocity.z = move_toward(velocity.z, 0, delta * 20)
		move_and_slide()
		return
	var input := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward"))
	input += Vector2(touch_move.x, touch_move.y)
	if input.length() > 1.0:
		input = input.normalized()
	aiming = Input.is_action_pressed("aim") or touch_aim
	sprinting = Input.is_action_pressed("sprint") and not aiming and input.y < -0.3
	var basis := yaw_node.global_transform.basis
	var forward := -basis.z
	forward.y = 0
	forward = forward.normalized()
	var right := basis.x
	right.y = 0
	right = right.normalized()
	var dir := (right * input.x - forward * input.y)
	var speed := RUN if sprinting else (AIM_WALK if aiming else WALK)
	var target := dir * speed
	var accel := 14.0 if is_on_floor() else 4.0
	velocity.x = move_toward(velocity.x, target.x, accel * delta * speed)
	velocity.z = move_toward(velocity.z, target.z, accel * delta * speed)
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP
	move_and_slide()

	# Camera: aim tightens the arm and the field of view.
	arm.spring_length = lerp(arm.spring_length, 1.7 if aiming else 3.4, min(1.0, delta * 10))
	camera.fov = lerp(camera.fov, 52.0 if aiming else 72.0, min(1.0, delta * 10))
	_recoil = lerp(_recoil, 0.0, min(1.0, delta * 9))
	pitch_node.rotation.x = _pitch + _recoil

	# The body faces where the person aims when aiming or firing, else
	# where they walk.
	var firing := Input.is_action_pressed("fire") or touch_fire
	if aiming or firing:
		face(forward, delta, 18.0)
	elif dir.length() > 0.1:
		face(dir, delta, 10.0)
	var flat := Vector2(velocity.x, velocity.z).length()
	if not is_on_floor():
		play("Jump")
	elif flat > 5.5:
		play("Running")
	elif flat > 0.4:
		play("Walking")
	else:
		play("Idle")

	if Input.is_action_just_pressed("reload"):
		weapon.reload()
	if firing and weapon.can_fire():
		var moving_penalty: float = clamp(flat / RUN, 0.0, 1.0) * 0.03
		weapon.fire(muzzle(), aim_point(), moving_penalty * (0.4 if aiming else 1.0) + (0.0 if aiming else 0.012))
		_recoil += 0.012 if aiming else 0.02
	elif firing and weapon.magazine == 0 and not weapon.reloading:
		weapon.reload()

	# Health comes back slowly after five quiet seconds.
	regen_delay = max(0.0, regen_delay - delta)
	if regen_delay <= 0.0 and health < max_health * 0.6:
		heal(4.0 * delta)


func take_damage(amount: float, from: Vector3, attacker = null, headshot: bool = false) -> void:
	regen_delay = 5.0
	super.take_damage(amount, from, attacker, headshot)
