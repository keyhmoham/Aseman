## Headless-capable visual verify: build board, claim routes, dump PNGs.
extends SceneTree

const MainScene = preload("res://arena/persian_rails/main.tscn")

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("VISUAL_VERIFY_START")
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	if main.has_method("arena_start"):
		main.arena_start({"level": 1, "ai_count": 1, "wagons": 45, "seed": 42, "player_name": "تو", "skip_tutorial": true})
	await process_frame
	await process_frame
	await process_frame

	var rules = main.rules
	var map = main.get_node_or_null("Map")
	var claimed := 0
	if rules and map and map.has_method("refresh_claims"):
		for route in rules.routes:
			var rid := str(route.id)
			if rules.claimed.has(rid):
				continue
			var a = rules.city_by_id(str(route.from))
			var b = rules.city_by_id(str(route.to))
			if a.is_empty() or b.is_empty():
				continue
			var mid := Vector2((float(a.x) + float(b.x)) * 0.5, (float(a.z) + float(b.z)) * 0.5)
			if mid.length() > 5.5:
				continue
			rules.claimed[rid] = 0
			if not rules.players[0].routes.has(rid):
				rules.players[0].routes.append(rid)
			claimed += 1
			if claimed >= 3:
				break
		map.refresh_claims()
	print("VISUAL_CLAIMED=", claimed)

	# 1) Full board overview — frame Caspian (N) + Gulf (S) together.
	if main.has_method("_place_camera"):
		main._cam_dist = 17.8
		main._cam_pitch = deg_to_rad(68.0)
		main._target = Vector3(0.1, 0, 0.3)
		main._place_camera()
	for _i in range(14):
		await process_frame
	_dump_png("/tmp/pr_verify_board.png")
	print("VISUAL_SAVED_BOARD")

	# 1b) Circled north corridor (Tehran–Qazvin–Caspian–NW)
	if main.has_method("_place_camera"):
		main._cam_dist = 9.5
		main._cam_pitch = deg_to_rad(62.0)
		main._target = Vector3(-2.2, 0, -2.4)
		main._place_camera()
	for _i in range(8):
		await process_frame
	_dump_png("/tmp/pr_verify_north.png")
	print("VISUAL_SAVED_NORTH")

	# 2) North / Caspian Sea + coastal cities
	if main.has_method("_place_camera"):
		main._cam_dist = 9.2
		main._cam_pitch = deg_to_rad(58.0)
		main._target = Vector3(-1.2, 0, -4.6)
		main._place_camera()
	for _i in range(8):
		await process_frame
	_dump_png("/tmp/pr_verify_caspian.png")
	print("VISUAL_SAVED_CASPIAN")

	# 3) NW lakes + border
	if main.has_method("_place_camera"):
		main._cam_dist = 8.0
		main._target = Vector3(-5.8, 0, -3.4)
		main._place_camera()
	for _i in range(8):
		await process_frame
	_dump_png("/tmp/pr_verify_lakes.png")
	print("VISUAL_SAVED_LAKES")

	# 4) South seas — Persian Gulf + Oman
	if main.has_method("_place_camera"):
		main._cam_dist = 9.0
		main._target = Vector3(0.8, 0, 6.2)
		main._place_camera()
	for _i in range(8):
		await process_frame
	_dump_png("/tmp/pr_verify_gulf.png")
	print("VISUAL_SAVED_GULF")

	# 5) East border / Mashhad corridor
	if main.has_method("_place_camera"):
		main._cam_dist = 8.8
		main._target = Vector3(4.6, 0, -0.6)
		main._place_camera()
	for _i in range(8):
		await process_frame
	_dump_png("/tmp/pr_verify_east.png")
	print("VISUAL_SAVED_EAST")

	# 6) Center routes / wagons
	if main.has_method("_place_camera"):
		main._cam_dist = 7.0
		main._target = Vector3(-1.2, 0, -0.2)
		main._place_camera()
	for _i in range(8):
		await process_frame
	_dump_png("/tmp/pr_verify_wagons.png")
	print("VISUAL_SAVED_WAGONS")

	print("VISUAL_VERIFY_OK")
	quit(0)


func _dump_png(path: String) -> void:
	var vp := root.get_viewport()
	var img: Image = vp.get_texture().get_image()
	if img == null:
		print("VISUAL_FAIL_NO_IMAGE ", path)
		return
	var err := img.save_png(path)
	print("VISUAL_PNG ", path, " err=", err, " size=", img.get_width(), "x", img.get_height())
