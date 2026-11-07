## Headless tests of City Strike: the city, navigation and cover, the AI,
## weapons, waves and the result.
##   godot --headless --path games/city-strike --script res://tests/run_tests.gd
extends SceneTree

var failures := []
var checks := 0
var events := []


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures.append(what)
		printerr("FAIL: ", what)


func _init() -> void:
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var game: Node = load("res://arena/city_strike/main.tscn").instantiate()
	game.arena_event.connect(func(j): events.append(JSON.parse_string(j)))
	host.add_child(game)
	await frames(2)
	check(events.size() >= 1 and events[0].type == "ready", "ready event")

	# --- The city ---------------------------------------------------------
	var city = game.city
	check(city.road_points.size() > 60, "the city has roads: %d" % city.road_points.size())
	check(city.cover_cells.size() > 200, "there is cover: %d cells" % city.cover_cells.size())
	check(city.spawn_enemies.size() > 10, "enemy spawn points: %d" % city.spawn_enemies.size())
	check(city.is_walkable(city.spawn_player), "the person starts on walkable ground")
	var far: Vector3 = city.spawn_enemies[0]
	var p: PackedVector3Array = city.path(city.spawn_player, far)
	check(p.size() > 10, "a path crosses the city (%d points)" % p.size())
	var blocked := 0
	for pt in p:
		if not city.is_walkable(pt):
			blocked += 1
	check(blocked == 0, "the path stays on walkable cells")
	# Every road point is reachable from the start.
	var unreachable := 0
	for rp in city.road_points:
		if city.path(city.spawn_player, rp).is_empty():
			unreachable += 1
	check(unreachable == 0, "every road is reachable (%d not)" % unreachable)

	# --- A match ----------------------------------------------------------
	game.arena_start({"difficulty": 2, "waves": 2, "player_name": "Tester"})
	var player = game.player
	await frames(40)
	check(player.is_on_floor(), "the person stands on the ground")
	check(events.any(func(e): return e.type == "started"), "started event")
	await frames(200)
	check(game.wave == 1 and game.enemies_left() > 0, "wave 1 arrives (%d enemies)" % game.enemies_left())

	# Weapons: a shot at a bot standing in the open hits and hurts.
	var bot = game._bots[0]
	bot.global_position = player.global_position + Vector3(0, 0, -8)
	await frames(3)
	var hp: float = bot.health
	player.weapon.spread = 0.0
	player.weapon.base_spread = 0.0
	var hit: Dictionary = player.weapon.fire(player.global_position + Vector3(0, 1.2, -0.6), bot.chest_position())
	check(not hit.is_empty() and hit.collider == bot, "the shot hits the bot")
	check(bot.health < hp, "the bot is hurt (%.0f → %.0f)" % [hp, bot.health])
	check(player.weapon.magazine == 29, "a round is spent")

	# The AI sees the person in the open and fights back.
	await frames(120)
	check(bot.state == bot.State.ENGAGE or bot.state == bot.State.COVER or not bot.alive, "the bot engages (state %d)" % bot.state)
	var shots_before: int = bot.weapon.shots
	await frames(180)
	check(bot.weapon.shots > shots_before or not bot.alive or bot.state == bot.State.COVER, "the bot fires")
	check(player.health < 100.0 or player.armor < 25.0 or not bot.alive, "the person takes fire")
	check(player.alive, "the person survives the first exchange")
	# From here on the test's person cannot fall.
	player.max_health = 100000.0
	player.health = 100000.0

	# Hearing: a far bot comes to look when the person shoots.
	var other = null
	for b in game._bots:
		if b != bot and b.alive:
			other = b
			break
	if other:
		other.state = other.State.PATROL
		other._alert = false
		other.global_position = player.global_position + Vector3(30, 0, 0)
		await frames(2)
		player.weapon.fire(player.global_position + Vector3(0, 1.4, 0), player.global_position + Vector3(0, 1.4, -20))
		check(other.state != other.State.PATROL, "a bot within earshot reacts to a shot")

	# Reload.
	player.weapon.magazine = 0
	check(player.weapon.reload(), "reload starts")
	await frames(130)
	check(player.weapon.magazine == 30 and not player.weapon.reloading, "reload fills the magazine")

	# Clear the waves: kills score; waves advance; the match is won.
	for round in 2:
		for b in game._bots.duplicate():
			if is_instance_valid(b) and b.alive:
				b.take_damage(1000.0, player.global_position, player, true)
		await frames(10)
		if game.over:
			break
		while game._between > 0.0 and not game.over:
			await frames(20)
		await frames(5)
	check(game.over, "the match ends when every wave is cleared")
	var res := events.filter(func(e): return e.type == "result")
	check(res.size() == 1, "one result event")
	if res.size() == 1:
		check(res[0].outcome == "win" and res[0].waves_cleared == 2, "won with both waves cleared: " + str(res[0]))
		check(res[0].kills >= 5 and res[0].score > 0, "kills and score are counted")
	check(events.filter(func(e): return e.type == "kill").size() >= 5, "kill events")

	# A loss: the person falls.
	game.arena_start({"difficulty": 5, "waves": 1})
	await frames(5)
	game.player.take_damage(1000.0, Vector3.ZERO, null)
	res = events.filter(func(e): return e.type == "result")
	check(res.size() == 2 and res[1].outcome == "loss", "falling loses the match")

	host.queue_free()
	await frames(2)
	if failures.is_empty():
		print("city-strike-tests passed %d checks" % checks)
		quit(0)
	else:
		print("city-strike-tests FAILED %d of %d" % [failures.size(), checks])
		quit(1)
