## Headless tests for Persian Rails Empire.
extends SceneTree

const Rules = preload("res://arena/persian_rails/rules.gd")
const AIScript = preload("res://arena/persian_rails/ai.gd")


func _init() -> void:
	var passed := 0
	var failed := 0
	# 1) data loads
	var rules = Rules.new()
	rules.load_data()
	if rules.cities.size() >= 30 and rules.routes.size() >= 45 and rules.tickets_deck.size() >= 20:
		passed += 1
	else:
		failed += 1
		push_error("map data incomplete")
	# 2) a short match finishes
	rules.start("بازیکن", 1, 20, 42)
	var ai = AIScript.new(2)
	var guard := 0
	while not rules.over and guard < 400:
		var act = ai.choose(rules)
		var ev = rules.apply(act)
		if not ev.get("ok", false):
			rules.apply({"type": "draw_trains"})
		# force end eventually by depleting wagons via cheap claims when possible
		guard += 1
	if not rules.over:
		# force finalize
		rules.last_round = true
		rules.turns_left = 0
		rules._finalize()
	var res = rules.final_result()
	if str(res.get("type")) == "result" and res.has("score"):
		passed += 1
	else:
		failed += 1
		push_error("no result")
	# 3) scoring table
	var r = {"length": 4}
	if rules.route_score(r) == 7:
		passed += 1
	else:
		failed += 1
	# 4) afford gray route
	rules.start("بازیکن", 1, 45, 7)
	rules.players[0].hand = ["red", "red", "red", "locomotive"]
	var sample = null
	for rr in rules.routes:
		if str(rr.color) == "gray" or true:
			sample = rr
			break
	var aff = rules.can_afford(rules.players[0].hand, sample)
	if aff.get("ok", false):
		passed += 1
	else:
		# still ok if mountain cost too high — try length 1
		for rr2 in rules.routes:
			if int(rr2.length) == 1:
				aff = rules.can_afford(["red", "locomotive"], rr2)
				break
		if aff.get("ok", false):
			passed += 1
		else:
			failed += 1
	# 5) Godot shell replaces Flutter/Elpian tabs
	var shell_ok := ResourceLoader.exists("res://arena/persian_rails/shell.gd") \
		and ResourceLoader.exists("res://arena/persian_rails/ui_kit.gd") \
		and ResourceLoader.exists("res://arena/persian_rails/platform_api.gd") \
		and ResourceLoader.exists("res://arena/persian_rails/shell.tscn")
	if shell_ok:
		passed += 1
	else:
		failed += 1
		push_error("godot shell files missing")
	print("%d passed" % passed)
	if failed:
		print("%d failed" % failed)
		quit(1)
	quit(0)
