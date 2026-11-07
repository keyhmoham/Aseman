## City Strike — a third-person shooter in a city, against AI squads.
##
## The person fights through waves of AI fighters (bot.gd) across a city
## block grid (city.gd): each wave is larger and comes from a different
## side; supply drops (health, armour, ammunition) appear between waves.
## Clear every wave to win; fall and the city is lost.
##
## Like Arena Chess it runs as the main scene (the Web export) or mounted in
## a host (the Aseman client's Scene3D, from this project's resource pack):
## arena_start(params) starts a match, arena_event(json) reports
## ready / started / wave / kill / result. The result:
## {"type":"result","game":"city-strike","outcome":"win|loss","score":N,
##  "kills":N,"headshots":N,"accuracy":0..1,"waves_cleared":N,"waves":N,
##  "duration_s":N,"difficulty":D}
extends Node3D

signal arena_event(json: String)

const City = preload("res://arena/city_strike/city.gd")
const Player = preload("res://arena/city_strike/player.gd")
const Bot = preload("res://arena/city_strike/bot.gd")
const HUD = preload("res://arena/city_strike/hud.gd")
const Inputs = preload("res://arena/city_strike/inputs.gd")

const SQUAD_NAMES := ["Viper", "Ghost", "Raven", "Talon", "Havoc", "Specter", "Cobra", "Wraith", "Onyx", "Blitz", "Fang", "Rook"]

var params := {"difficulty": 3, "waves": 3, "player_name": "You", "seed": 7}
var city
var player
var hud
var wave := 0
var waves := 3
var score := 0
var kills := 0
var over := false
var started := false
var started_at := 0
var _bots: Array = []
var _between := 0.0
var _pickups: Array = []
var _standalone := false
var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	Inputs.ensure()
	_environment()
	city = City.new()
	city.name = "City"
	add_child(city)
	city.build(int(params.seed))
	hud = HUD.new()
	add_child(hud)
	hud.game = self
	hud.action.connect(func(what):
		if what == "restart":
			arena_start({}))
	_standalone = get_tree().current_scene == self
	if _standalone:
		call_deferred("arena_start", _params_from_page())
	_emit({"type": "ready", "game": "city-strike"})


func _environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.2, 0.32, 0.55)
	sm.sky_horizon_color = Color(0.95, 0.62, 0.42)
	sm.ground_horizon_color = Color(0.5, 0.42, 0.38)
	sm.ground_bottom_color = Color(0.12, 0.12, 0.14)
	sm.sun_angle_max = 20.0
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	e.fog_enabled = true
	e.fog_light_color = Color(0.75, 0.6, 0.55)
	e.fog_density = 0.0035
	e.glow_enabled = true
	e.glow_intensity = 0.3
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32, -125, 0)
	sun.light_color = Color(1.0, 0.86, 0.72)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)


# ---------------------------------------------------------------------------
# The host's API
# ---------------------------------------------------------------------------

## params: difficulty 1..5, waves 1..6, player_name, seed.
func arena_start(p: Dictionary = {}) -> void:
	for k in p:
		params[k] = p[k]
	waves = clampi(int(params.get("waves", 3)), 1, 6)
	for b in _bots:
		if is_instance_valid(b):
			b.queue_free()
	_bots.clear()
	for k in _pickups:
		if is_instance_valid(k):
			k.queue_free()
	_pickups.clear()
	if player and is_instance_valid(player):
		player.queue_free()
	hud.clear_modal()
	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(Color(0.35, 0.6, 1.0))
	player.display_name = str(params.get("player_name", "You"))
	player.global_position = city.spawn_player
	player.yaw_node.rotation.y = -PI * 0.25     # face into the city (north-east)
	player.weapon.fx_parent = self
	player.died.connect(_on_player_died)
	player.damaged.connect(func(_a, _amt, from): hud.hurt(from))
	player.weapon.fired.connect(_on_player_fired)
	hud.player = player
	wave = 0
	score = 0
	kills = 0
	over = false
	started = true
	started_at = Time.get_ticks_msec()
	_between = 2.5
	if not _headless and _standalone:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_emit({"type": "started", "game": "city-strike", "difficulty": difficulty(), "waves": waves})


func arena_stop() -> void:
	if started and not over:
		_finish(false, "abandoned")


func arena_state() -> Dictionary:
	return {"wave": wave, "waves": waves, "enemies_left": enemies_left(), "score": score, "kills": kills,
		"over": over, "health": player.health if player else 0.0}


func difficulty() -> int:
	return clampi(int(params.get("difficulty", 3)), 1, 5)


func enemies_left() -> int:
	var n := 0
	for b in _bots:
		if is_instance_valid(b) and b.alive:
			n += 1
	return n


# ---------------------------------------------------------------------------
# The match
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not started or over:
		return
	if _between > 0.0:
		_between -= delta
		if _between <= 0.0:
			_next_wave()
	elif enemies_left() == 0 and wave > 0:
		var bonus := 250 * wave * difficulty()
		score += bonus
		_emit({"type": "wave_cleared", "wave": wave, "bonus": bonus})
		if wave >= waves:
			_finish(true, "all waves cleared")
		else:
			hud.banner("WAVE %d CLEARED  +%d" % [wave, bonus])
			_supply_drop()
			_between = 6.0
	_check_pickups()


func _next_wave() -> void:
	wave += 1
	var count := 3 + wave * 2 + (difficulty() - 3)
	count = clampi(count, 3, 14)
	# Enemies come from the side of the city farthest from the person.
	var spawns: Array = city.spawn_enemies.duplicate()
	spawns.sort_custom(func(a, b): return a.distance_to(player.global_position) > b.distance_to(player.global_position))
	spawns = spawns.slice(0, max(6, spawns.size() / 2))
	for k in count:
		var b = Bot.new()
		b.name = "Bot%d_%d" % [wave, k]
		add_child(b)
		b.add_to_group("bots")
		var colors := [Color(0.95, 0.3, 0.25), Color(0.95, 0.55, 0.2), Color(0.8, 0.25, 0.6)]
		b.setup(city, player, difficulty(), colors[wave % 3], SQUAD_NAMES[(wave * 5 + k) % SQUAD_NAMES.size()])
		b.weapon.fx_parent = self
		var at: Vector3 = spawns[k % spawns.size()] + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3))
		b.global_position = city.cell_to_world(city.nearest_free(city.world_to_cell(at))) + Vector3(0, 0.2, 0)
		b.died.connect(_on_bot_died)
		# Later waves know roughly where the person is.
		if wave >= 2:
			b.alert(player.global_position + Vector3(randf_range(-15, 15), 0, randf_range(-15, 15)))
		_bots.append(b)
	hud.banner("WAVE %d  ·  %d HOSTILES" % [wave, count])
	_emit({"type": "wave", "wave": wave, "enemies": count})


func _on_player_fired(origin: Vector3, hit: Dictionary) -> void:
	# Shots are loud: bots within earshot come to look.
	for b in _bots:
		if is_instance_valid(b) and b.alive and b.global_position.distance_to(origin) < 50.0:
			b.alert(origin)
	if not hit.is_empty() and hit.damage > 0.0:
		hud.hit(hit.headshot)


func _on_bot_died(bot, killer, headshot: bool) -> void:
	if killer != player:
		return
	kills += 1
	var points := (150 if headshot else 100) * difficulty()
	score += points
	hud.feed("%s  ✕  %s%s" % [player.display_name, bot.display_name, "  ◎" if headshot else ""], Color(1.0, 0.9, 0.6) if headshot else Color(0.95, 0.96, 1.0))
	_emit({"type": "kill", "victim": bot.display_name, "headshot": headshot, "points": points})
	# Bodies fade away after a while.
	get_tree().create_timer(6.0).timeout.connect(func():
		if is_instance_valid(bot):
			bot.queue_free())


func _on_player_died(_actor, killer, _headshot: bool) -> void:
	if killer:
		hud.feed("%s  ✕  %s" % [killer.display_name, player.display_name], Color(1.0, 0.4, 0.35))
	_finish(false, "killed in action")


func _finish(won: bool, reason: String) -> void:
	if over:
		return
	over = true
	var w = player.weapon
	var summary := {
		"type": "result", "game": "city-strike", "outcome": "win" if won else "loss", "reason": reason,
		"score": score, "kills": kills, "headshots": w.headshots, "accuracy": snapped(w.accuracy(), 0.001),
		"waves_cleared": wave if won else max(0, wave - 1), "waves": waves,
		"duration_s": int((Time.get_ticks_msec() - started_at) / 1000), "difficulty": difficulty(),
	}
	# Accuracy is worth up to a fifth more.
	summary.score = int(summary.score * (1.0 + 0.2 * summary.accuracy))
	score = summary.score
	hud.show_result(won, summary)
	_emit(summary)


# ---------------------------------------------------------------------------
# Supply drops
# ---------------------------------------------------------------------------

func _supply_drop() -> void:
	var kinds := ["health", "armor", "ammo"]
	for k in 3:
		var p: Vector3 = city.road_points[randi() % city.road_points.size()]
		if p.distance_to(player.global_position) > 55.0:
			p = player.global_position.lerp(p, 0.35)
		p = city.cell_to_world(city.nearest_free(city.world_to_cell(p)))
		var crate := Node3D.new()
		crate.set_meta("kind", kinds[k])
		var colors := {"health": Color(0.3, 0.95, 0.5), "armor": Color(0.42, 0.66, 1.0), "ammo": Color(1.0, 0.8, 0.3)}
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.7, 0.5, 0.7)
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = colors[kinds[k]]
		m.emission_enabled = true
		m.emission = colors[kinds[k]]
		m.emission_energy_multiplier = 0.8
		mi.material_override = m
		mi.position.y = 0.6
		crate.add_child(mi)
		var light := OmniLight3D.new()
		light.light_color = colors[kinds[k]]
		light.omni_range = 4.0
		light.position.y = 1.2
		crate.add_child(light)
		add_child(crate)
		crate.global_position = p
		var tw: Tween = crate.create_tween().set_loops()
		tw.tween_property(mi, "rotation:y", TAU, 2.5).from(0.0)
		_pickups.append(crate)


func _check_pickups() -> void:
	for crate in _pickups.duplicate():
		if not is_instance_valid(crate):
			_pickups.erase(crate)
			continue
		if crate.global_position.distance_to(player.global_position) < 1.6:
			match crate.get_meta("kind"):
				"health":
					player.heal(60)
				"armor":
					player.armor = min(100.0, player.armor + 50)
				"ammo":
					player.weapon.reserve += 90
			hud.feed("+ " + str(crate.get_meta("kind")).to_upper(), Color(0.6, 1.0, 0.7))
			_pickups.erase(crate)
			crate.queue_free()


# ---------------------------------------------------------------------------
# Talking to the outside
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _standalone or over:
		return
	if event is InputEventMouseButton and event.pressed and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _emit(ev: Dictionary) -> void:
	var json := JSON.stringify(ev)
	arena_event.emit(json)
	if _standalone and OS.has_feature("web"):
		JavaScriptBridge.eval("window.parent && window.parent.postMessage({arena: %s}, '*')" % json, true)
	if _standalone and ev.get("type") == "result":
		_report(ev)


func _report(ev: Dictionary) -> void:
	var url := str(params.get("report_url", ""))
	if url == "":
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := ev.duplicate()
	body["token"] = str(params.get("token", ""))
	http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))


func _params_from_page() -> Dictionary:
	var out := {}
	if not OS.has_feature("web"):
		return out
	var q = JavaScriptBridge.eval("window.location.search", true)
	if typeof(q) != TYPE_STRING:
		return out
	for pair in str(q).trim_prefix("?").split("&", false):
		var kv := pair.split("=")
		if kv.size() == 2:
			out[kv[0].uri_decode()] = kv[1].uri_decode()
	var names := {"level": "difficulty", "name": "player_name", "report": "report_url"}
	for k in names:
		if out.has(k):
			out[names[k]] = out[k]
	for k in ["difficulty", "waves", "seed"]:
		if out.has(k):
			out[k] = int(out[k])
	return out
