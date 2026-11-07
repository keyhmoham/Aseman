## Headless test of the 3D game as a host mounts it: instance the scene under
## another node, start it, play, let the AI answer, and check the events.
##   godot --headless --path games/chess --script res://tests/test_scene.gd
extends SceneTree

var events := []
var failures := []


func check(cond: bool, what: String) -> void:
	if not cond:
		failures.append(what)
		printerr("FAIL: ", what)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var game: Node = load("res://arena/chess/main.tscn").instantiate()
	game.arena_event.connect(func(j): events.append(JSON.parse_string(j)))
	host.add_child(game)
	await process_frame
	check(events.size() >= 1 and events[0].type == "ready", "the game says it is ready")
	game.arena_start({"player_color": "white", "level": 1, "player_name": "Tester"})
	check(game.arena_state().turn == "white", "white to move")
	check(game.arena_play("e4"), "the person plays e4")
	await game.await_ai()
	check(game.arena_state().moves.size() == 2, "the AI answered: " + str(game.arena_state().moves))
	check(not game.arena_play("e4"), "an illegal move is refused")
	# Tap-to-move through the board API.
	var Rules = load("res://arena/chess/chess_rules.gd")
	game.tap_square(Rules.sq_from_name("g1"))
	game.tap_square(Rules.sq_from_name("f3"))
	await game.await_ai()
	check(game.arena_state().moves[2] == "Nf3", "tap-to-move plays Nf3")
	# Take back restores the position before the person's move.
	game._on_hud_action("undo", {})
	check(game.arena_state().moves.size() == 2, "take-back removes the move and the reply")
	# Fool's mate: the person (black) is mated by a scripted line.
	game.arena_start({"player_color": "black", "level": 1, "fen": "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"})
	check(game.arena_play("Qh4#"), "the person mates")
	var results := events.filter(func(e): return e.type == "result")
	check(results.size() == 1, "one result event")
	if results.size() == 1:
		var r: Dictionary = results[0]
		check(r.outcome == "win" and r.result == "0-1" and r.reason == "checkmate", "result is a win by checkmate: " + str(r))
		check(r.pgn.contains("Qh4#") and r.pgn.contains('[Result "0-1"]'), "the PGN records the game")
		check(r.score > 0, "a win scores")
	game.arena_start({"player_color": "white", "level": 2})
	game._on_hud_action("resign", {})
	results = events.filter(func(e): return e.type == "result")
	check(results.size() == 2 and results[1].outcome == "loss" and results[1].reason == "resignation", "resigning is a loss")
	var moves := events.filter(func(e): return e.type == "move")
	check(moves.size() >= 4, "moves are reported")
	if failures.is_empty():
		print("chess-scene passed (%d events)" % events.size())
		quit(0)
	else:
		quit(1)
