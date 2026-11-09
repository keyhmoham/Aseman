## Headless smoke: tutorial starts on force, advances through actions, then releases play.
extends SceneTree

const MainScene = preload("res://arena/persian_rails/main.tscn")
const Tutorial = preload("res://arena/persian_rails/tutorial.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("TUTORIAL_SMOKE_START")
	Tutorial.clear_completed()
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main.arena_start({
		"level": 1, "ai_count": 1, "wagons": 45, "seed": 7,
		"player_name": "تو", "force_tutorial": true,
	})
	await process_frame
	await process_frame
	var tut = main.get_node_or_null("Tutorial")
	assert(tut != null and tut.is_blocking(), "tutorial should be active on enter")
	print("TUTORIAL_ACTIVE=", tut.is_blocking())
	print("TUTORIAL_STEP=", tut.step_i, " KIND=", tut.current_kind())

	# welcome → CTA
	tut._on_cta()
	await process_frame
	assert(tut.current_kind() == "pan", "expected pan step")
	print("TUTORIAL_AFTER_WELCOME=", tut.current_kind())

	# pan
	tut.notify_pan(40.0)
	await process_frame
	assert(tut.current_kind() == "info", "expected hand info")
	print("TUTORIAL_AFTER_PAN=", tut.step_i)

	tut._on_cta() # hand
	await process_frame
	assert(tut.wants_action("draw_trains"), "expected draw tap")
	assert(tut.notify_action("draw_trains"), "draw should advance")
	await process_frame
	assert(tut.wants_action("claim_mode"), "expected claim tap")
	assert(tut.notify_action("claim_mode"), "claim should advance")
	await process_frame
	assert(tut.current_kind() == "tap_route", "expected route tap")
	assert(tut.notify_route("r1"), "route should advance")
	await process_frame
	tut._on_cta() # tickets
	await process_frame
	tut._on_cta() # ready → finish
	await process_frame
	await process_frame
	assert(not tut.is_blocking(), "tutorial should finish")
	print("TUTORIAL_DONE=1")

	# Every new match should show the coach again.
	main.arena_start({"level": 1, "ai_count": 1, "wagons": 45, "seed": 8})
	await process_frame
	await process_frame
	if not tut.is_blocking():
		push_error("tutorial should show again on every game enter")
		quit(1)
		return
	print("TUTORIAL_RESHOW_ON_RETURN=1")

	tut._on_skip()
	await process_frame
	await process_frame
	if tut.is_blocking():
		push_error("skip should finish")
		quit(1)
		return

	# Opt-out still works for headless/tools.
	main.arena_start({"level": 1, "skip_tutorial": true})
	await process_frame
	await process_frame
	if tut.is_blocking():
		push_error("skip_tutorial must suppress the coach")
		quit(1)
		return
	print("TUTORIAL_SMOKE_OK")
	quit(0)
