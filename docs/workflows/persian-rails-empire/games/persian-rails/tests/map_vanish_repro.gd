## Repro: map covered/vanished after advancing coach cards or drawing trains.
extends SceneTree

const MainScript = preload("res://arena/persian_rails/main.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = MainScript.new()
	root.add_child(main)
	await process_frame
	await process_frame
	main.arena_start({"level": 1, "ai_count": 1, "wagons": 45, "force_tutorial": true, "seed": 1})
	await process_frame
	await process_frame

	var tut = main._tutorial
	var map = main._map
	var hud = main._hud
	var ok := true

	print("TUT_ACTIVE=", tut.active, " STEP=", tut.step_i)
	_dump("start", main, tut, map, hud)

	# Advance through coach cards (info steps + forced advances).
	var guard := 0
	while tut.active and guard < 20:
		var kind := str(tut.current_kind())
		var step_id := str(tut._cur().get("id", ""))
		print("STEP id=", step_id, " kind=", kind, " shell=", _shell_info(tut), " veil=", tut._veil)
		if kind == "info" or kind == "ready":
			tut._on_cta()
		elif kind == "pan":
			tut.notify_pan(40.0)
		elif kind == "tap_action":
			var act := str(tut._cur().get("action", ""))
			tut.notify_action(act)
		elif kind == "tap_route":
			# Critical: map must remain largely visible for this step.
			var cover := _map_cover_ratio(tut, hud)
			print("ROUTE_STEP_COVER=", cover)
			if cover > 0.45:
				push_error("coach card covers too much of the board on route step: %.2f" % cover)
				ok = false
			tut.notify_route("r1")
		else:
			tut._advance()
		await process_frame
		guard += 1

	_dump("after_tutorial", main, tut, map, hud)
	if map == null or not is_instance_valid(map):
		push_error("map node invalid after tutorial")
		ok = false
	elif map.get_child_count() < 1:
		push_error("map has no children after tutorial")
		ok = false

	# Draw trains repeatedly and ensure board survives.
	main.arena_start({"level": 1, "ai_count": 1, "wagons": 45, "skip_tutorial": true, "seed": 2})
	await process_frame
	var board_before := _board_mesh_count(main._map)
	for i in range(12):
		if main.rules.over:
			break
		if main.rules.players[main.rules.current].is_ai:
			await process_frame
			await process_frame
			continue
		main._do_action({"type": "draw_trains"})
		await process_frame
		await process_frame
	var board_after := _board_mesh_count(main._map)
	print("BOARD_MESH before=", board_before, " after=", board_after)
	_dump("after_draws", main, main._tutorial, main._map, main._hud)
	if board_after < 5:
		push_error("board meshes vanished after draws")
		ok = false
	if main._hud and main._hud._dim.visible:
		push_error("dim overlay stuck visible after draws")
		ok = false

	# Bottom chrome must not eat the whole viewport.
	var vp := root.get_viewport().get_visible_rect().size
	if hud and hud._bottom:
		var bh: float = hud._bottom.size.y
		print("BOTTOM_H=", bh, " VP_H=", vp.y, " RATIO=", bh / maxf(vp.y, 1.0))
		if bh > vp.y * 0.55:
			push_error("bottom HUD covers majority of viewport")
			ok = false

	if ok:
		print("map_vanish_repro OK")
		quit(0)
	else:
		print("map_vanish_repro FAILED")
		quit(1)


func _board_mesh_count(map) -> int:
	if map == null or not is_instance_valid(map):
		return 0
	var board = map._board
	if board == null or not is_instance_valid(board):
		return 0
	return _count_meshes(board)


func _count_meshes(n: Node) -> int:
	var c := 0
	if n is MeshInstance3D:
		c += 1
	for ch in n.get_children():
		c += _count_meshes(ch)
	return c


func _shell_info(tut) -> String:
	if tut._shell == null:
		return "null"
	var r: Rect2 = tut._shell.get_global_rect()
	return "pos=%s size=%s" % [r.position, r.size]


func _map_cover_ratio(tut, hud) -> float:
	var vp := root.get_viewport().get_visible_rect()
	var insets: Vector2 = hud.chrome_insets() if hud else Vector2(80, 160)
	var map_rect := Rect2(
		vp.position.x,
		vp.position.y + insets.x,
		vp.size.x,
		maxf(80.0, vp.size.y - insets.x - insets.y)
	)
	var shell: Rect2 = tut._shell.get_global_rect()
	var inter := map_rect.intersection(shell)
	if map_rect.get_area() <= 1.0:
		return 1.0
	return inter.get_area() / map_rect.get_area()


func _dump(tag: String, main, tut, map, hud) -> void:
	var vp := root.get_viewport().get_visible_rect().size
	print(
		"DUMP ", tag,
		" vp=", vp,
		" map_children=", (map.get_child_count() if map else -1),
		" board_meshes=", _board_mesh_count(map),
		" tut_vis=", (tut.visible if tut else false),
		" shell=", _shell_info(tut) if tut else "n/a",
		" dim=", (hud._dim.visible if hud else false)
	)
