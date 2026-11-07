## Renders City Strike and saves screenshots (needs a display; xvfb works):
##   godot --path games/city-strike --script res://tests/shot.gd -- out_prefix
extends SceneTree

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://shot"
	root.size = Vector2i(1280, 720)
	var game: Node = load("res://arena/city_strike/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.arena_start({"difficulty": 1, "waves": 3})
	for f in 200:
		await physics_frame
	var p = game.player
	p.max_health = 1e6
	p.health = 1e6
	# Two bots in view, one firing.
	var k := 0
	for b in game._bots:
		b.global_position = p.global_position + Vector3(-6 - k * 4, 0, -14 - k * 3)
		k += 1
	p.yaw_node.rotation.y = atan2(6, 14)
	for f in 40:
		await process_frame
	Input.action_press("fire")
	for f in 8:
		await process_frame
	root.get_texture().get_image().save_png(out + "_tps.png")
	Input.action_release("fire")
	# The city from above.
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(-95, 70, 95)
	cam.look_at(Vector3(0, 0, 0))
	cam.current = true
	game.hud.visible = false
	for f in 10:
		await process_frame
	root.get_texture().get_image().save_png(out + "_city.png")
	print("shots ", out)
	quit()
