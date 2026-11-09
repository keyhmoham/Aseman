## Headless smoke: Godot shell scripts parse and expose Arena contract.
extends SceneTree

const Shell = preload("res://arena/persian_rails/shell.gd")
const Ui = preload("res://arena/persian_rails/ui_kit.gd")
const Api = preload("res://arena/persian_rails/platform_api.gd")


func _init() -> void:
	var passed := 0
	var failed := 0
	if Shell != null and Ui != null and Api != null:
		passed += 1
	else:
		failed += 1
		push_error("shell preloads failed")
	var d := Ui.density_for(Vector2(390, 844))
	if d.has("btn_h") and d.has("font_title"):
		passed += 1
	else:
		failed += 1
		push_error("ui density missing keys")
	var base := Api.detect_base()
	if typeof(base) == TYPE_STRING and base != "":
		passed += 1
	else:
		failed += 1
		push_error("api base empty")
	print("%d passed" % passed)
	if failed:
		print("%d failed" % failed)
		quit(1)
	quit(0)
