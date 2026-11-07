## An AI fighter. It sees (a field of view and line of sight), hears (shots
## nearby), and tells its squad; it patrols the streets, engages with
## human-like reaction time and aim error, strafes, takes cover behind
## street furniture and cars when hurt or reloading, peeks back out, and
## hunts down the last place it saw its target. Difficulty 1..5 scales its
## reaction, accuracy, health and boldness.
extends "res://arena/city_strike/actor.gd"

enum State { PATROL, ENGAGE, HUNT, COVER, DEAD }

var city
var target                     # the actor it fights (the person)
var difficulty := 3
var state := State.PATROL
var last_known := Vector3.ZERO
var path := PackedVector3Array()
var path_i := 0
var speed := 4.2

var _think := 0.0
var _repath := 0.0
var _sees := false
var _seen_for := 0.0
var _reaction := 0.5
var _aim_error := 0.06
var _burst := 0
var _burst_pause := 0.0
var _strafe := 1.0
var _strafe_t := 0.0
var _cover_until := 0.0
var _alert := false
var _clock := 0.0


func setup(p_city, p_target, p_difficulty: int, color: Color, name_: String) -> void:
	city = p_city
	target = p_target
	difficulty = clampi(p_difficulty, 1, 5)
	display_name = name_
	team = 1
	setup_body(color)
	# Difficulty: slower and sloppier at 1, quick and precise at 5.
	_reaction = lerp(0.85, 0.22, (difficulty - 1) / 4.0)
	_aim_error = lerp(0.11, 0.028, (difficulty - 1) / 4.0)
	max_health = lerp(70.0, 120.0, (difficulty - 1) / 4.0)
	health = max_health
	speed = lerp(3.6, 4.8, (difficulty - 1) / 4.0)
	weapon.damage = lerp(9.0, 15.0, (difficulty - 1) / 4.0)
	weapon.fire_interval = 0.14
	weapon.reserve = 9999
	_strafe = 1.0 if randf() < 0.5 else -1.0


## Something the bot heard or a squad mate called out.
func alert(at: Vector3) -> void:
	if not alive:
		return
	_alert = true
	last_known = at
	if state == State.PATROL:
		state = State.HUNT
		_repath = 0.0


func _physics_process(delta: float) -> void:
	_clock += delta
	apply_gravity(delta)
	if not alive:
		state = State.DEAD
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return
	_think -= delta
	if _think <= 0.0:
		_think = 0.15
		_perceive()
	match state:
		State.PATROL:
			_patrol(delta)
		State.HUNT:
			_hunt(delta)
		State.ENGAGE:
			_engage(delta)
		State.COVER:
			_cover(delta)
	move_and_slide()
	var flat := Vector2(velocity.x, velocity.z).length()
	if flat > 4.0:
		play("Running")
	elif flat > 0.4:
		play("Walking")
	else:
		play("Idle")


func _perceive() -> void:
	if target == null or not target.alive:
		_sees = false
		return
	var to: Vector3 = target.chest_position() - head_position()
	var dist := to.length()
	var facing := Vector3(sin(model.rotation.y), 0, cos(model.rotation.y))
	var in_fov := _alert or facing.dot(Vector3(to.x, 0, to.z).normalized()) > 0.2 or dist < 6.0
	var sees := false
	if dist < 75.0 and in_fov:
		var q := PhysicsRayQueryParameters3D.create(head_position(), target.chest_position())
		q.exclude = [get_rid()]
		q.collision_mask = 1 | 2
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		sees = hit.is_empty() or hit.collider == target
	if sees:
		if not _sees:
			_seen_for = 0.0
			# Tell the squad.
			for b in get_tree().get_nodes_in_group("bots"):
				if b != self and b.alive and b.global_position.distance_to(global_position) < 45.0:
					b.alert(target.global_position)
		last_known = target.global_position
		_alert = true
		if state != State.COVER:
			state = State.ENGAGE
	elif _sees and state == State.ENGAGE:
		state = State.HUNT
		_repath = 0.0
	_sees = sees


func _follow(delta: float, run: bool) -> bool:
	if path_i >= path.size():
		velocity.x = move_toward(velocity.x, 0, delta * 30)
		velocity.z = move_toward(velocity.z, 0, delta * 30)
		return true
	var p := path[path_i]
	var to := p - global_position
	to.y = 0
	if to.length() < 0.8:
		path_i += 1
		return path_i >= path.size()
	var dir := to.normalized()
	var v := dir * (speed * (1.0 if run else 0.55))
	# Keep a little distance from squad mates.
	for b in get_tree().get_nodes_in_group("bots"):
		if b != self and b.alive:
			var away: Vector3 = global_position - b.global_position
			away.y = 0
			if away.length() < 1.6 and away.length() > 0.01:
				v += away.normalized() * 1.5
	velocity.x = v.x
	velocity.z = v.z
	face(dir, delta, 8.0)
	return false


func _go(to: Vector3) -> void:
	path = city.path(global_position, to)
	path_i = 1 if path.size() > 1 else 0


func _patrol(delta: float) -> void:
	if _follow(delta, false):
		var pts: Array = city.road_points
		_go(pts[randi() % pts.size()])


func _hunt(delta: float) -> void:
	_repath -= delta
	if _repath <= 0.0:
		_repath = 1.2
		_go(last_known)
	if _follow(delta, true):
		# Nothing here: look around, then patrol again.
		_alert = false
		state = State.PATROL
		path = PackedVector3Array()


func _engage(delta: float) -> void:
	if not _sees:
		state = State.HUNT
		return
	_seen_for += delta
	var to: Vector3 = target.global_position - global_position
	to.y = 0
	var dist := to.length()
	face(to, delta, 10.0)
	# Hurt or out of rounds: break for cover.
	if (health < max_health * 0.4 and randf() < 0.02 * difficulty) or weapon.magazine == 0:
		if _take_cover():
			return
	# Strafe at mid range, close in from far, back off when too close.
	_strafe_t -= delta
	if _strafe_t <= 0.0:
		_strafe_t = randf_range(0.8, 2.0)
		_strafe = -_strafe if randf() < 0.6 else _strafe
	var side := to.normalized().cross(Vector3.UP) * _strafe
	var want := side * speed * 0.55
	if dist > 32.0:
		want += to.normalized() * speed * 0.6
	elif dist < 8.0:
		want -= to.normalized() * speed * 0.5
	if not city.is_walkable(global_position + want.normalized() * 1.2):
		want = Vector3.ZERO
		_strafe = -_strafe
	velocity.x = move_toward(velocity.x, want.x, delta * 20)
	velocity.z = move_toward(velocity.z, want.z, delta * 20)
	# Fire in bursts once the reaction time has passed.
	if _seen_for < _reaction:
		return
	if _burst_pause > 0.0:
		_burst_pause -= delta
		return
	if weapon.can_fire():
		var err: float = _aim_error * (1.0 + dist / 60.0) + (0.04 if Vector2(target.velocity.x, target.velocity.z).length() > 5 else 0.0)
		var aim: Vector3 = target.chest_position() + Vector3(randf_range(-0.2, 0.2), randf_range(-0.3, 0.35), randf_range(-0.2, 0.2))
		weapon.fire(head_position() - Vector3(0, 0.3, 0) + to.normalized() * 0.5, aim, err)
		_burst += 1
		if _burst >= randi_range(3, 6):
			_burst = 0
			_burst_pause = randf_range(0.35, 0.9) * (1.3 - difficulty * 0.12)


## Finds a walkable cell beside something solid, out of the target's sight.
func _take_cover() -> bool:
	var best := Vector3.ZERO
	var best_d := INF
	var space := get_world_3d().direct_space_state
	var tries := 0
	for c in city.cover_cells:
		var p: Vector3 = city.cell_to_world(c)
		var d := p.distance_to(global_position)
		if d > 18.0 or d < 2.0 or d >= best_d:
			continue
		tries += 1
		if tries > 60:
			break
		var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1.0, 0), target.chest_position())
		q.exclude = [get_rid()]
		q.collision_mask = 1
		if not space.intersect_ray(q).is_empty():
			best = p
			best_d = d
	if best_d == INF:
		return false
	_go(best)
	state = State.COVER
	_cover_until = _clock + randf_range(2.0, 3.5)
	weapon.reload()
	return true


func _cover(delta: float) -> void:
	var arrived := _follow(delta, true)
	if arrived:
		play("Idle")
		if weapon.magazine < weapon.mag_size:
			weapon.reload()
		heal(6.0 * delta)
	if _clock >= _cover_until and not weapon.reloading:
		# Peek out: back to the fight (or hunt if it moved).
		state = State.ENGAGE if _sees else State.HUNT
		_repath = 0.0
