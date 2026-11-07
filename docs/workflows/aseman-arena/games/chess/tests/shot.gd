## Renders the game and saves a screenshot (needs a display; xvfb works):
##   godot --path games/chess --script res://tests/shot.gd -- out.png [moves…]
extends SceneTree

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://shot.png"
	root.size = Vector2i(1280, 800)
	var game: Node = load("res://arena/chess/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.arena_start({"player_color": "white", "level": 1, "player_name": "Shayan"})
	for i in range(1, args.size()):
		game.arena_play(args[i])
		while game.arena_state().thinking:
			await process_frame
		for f in 30:
			await process_frame
	var Rules = load("res://arena/chess/chess_rules.gd")
	game.tap_square(Rules.sq_from_name("g1"))
	for f in 40:
		await process_frame
	root.get_texture().get_image().save_png(out)
	print("shot ", out)
	quit()
