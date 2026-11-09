## Repro: bottom HUD / map vanish as the hand grows from repeated draws.
extends SceneTree

const MainScript = preload("res://arena/persian_rails/main.gd")
const ThemeX = preload("res://arena/persian_rails/theme.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = MainScript.new()
	root.add_child(main)
	await process_frame
	await process_frame
	main.arena_start({"level": 1, "ai_count": 1, "wagons": 45, "skip_tutorial": true, "seed": 11})
	await process_frame
	await process_frame

	var hud = main._hud
	var map = main._map
	var vp := root.get_viewport().get_visible_rect().size
	var ok := true
	var board0 := _meshes(map)
	print("VP=", vp, " BOARD0=", board0, " BOTTOM0=", hud._bottom.size, " HAND0=", main.rules.players[0].hand.size())

	for i in range(20):
		if main.rules.over:
			break
		# Force human turn draws even if AI is mid-burst.
		while not main.rules.over and main.rules.players[main.rules.current].is_ai:
			await process_frame
		if main.rules.over:
			break
		main._do_action({"type": "draw_trains"})
		await process_frame
		await process_frame
		await process_frame
		var hand_n: int = main.rules.players[0].hand.size()
		var bottom_h: float = hud._bottom.size.y
		var board_n := _meshes(map)
		var ratio := bottom_h / maxf(vp.y, 1.0)
		var child_n: int = hud._cards.get_child_count() if hud._cards else -1
		print("i=", i, " hand=", hand_n, " card_widgets=", child_n, " bottom_h=", bottom_h, " ratio=", ratio, " board=", board_n, " dim=", hud._dim.visible)
		var dens_bottom: float = float(hud._d.get("bottom_h", vp.y * 0.45))
		if bottom_h > dens_bottom + 8.0:
			push_error("bottom HUD grew past locked chrome at hand=%d (%.1f > %.1f)" % [hand_n, bottom_h, dens_bottom])
			ok = false
			break
		if ratio > 0.48:
			push_error("bottom HUD covers too much of the viewport at hand=%d ratio=%.2f" % [hand_n, ratio])
			ok = false
			break
		if board_n < board0 * 0.5:
			push_error("board meshes collapsed at hand=%d (%d -> %d)" % [hand_n, board0, board_n])
			ok = false
			break
		if not is_instance_valid(map) or map.get_child_count() < 1:
			push_error("map node lost at hand=%d" % hand_n)
			ok = false
			break

	if ok:
		print("cards_cover_map OK")
		quit(0)
	else:
		print("cards_cover_map FAILED")
		quit(1)


func _meshes(map) -> int:
	if map == null or not is_instance_valid(map) or map._board == null:
		return 0
	return _count(map._board)


func _count(n: Node) -> int:
	var c := 1 if n is MeshInstance3D else 0
	for ch in n.get_children():
		c += _count(ch)
	return c
