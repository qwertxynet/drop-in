extends Node
## Entry point: registers the controls, shows the menu and swaps game modes.

const Build = preload("res://scripts/build.gd")
const SkaterModel = preload("res://scripts/skater_model.gd")
const FreeSkate = preload("res://scripts/free_skate.gd")
const RhythmMode = preload("res://scripts/rhythm_mode.gd")

var _mode: Node = null
var _menu_layer: CanvasLayer
var _menu_world: Node3D = null
var _turntable: Node3D = null
var _first_button: Button


func _ready() -> void:
	_register_inputs()
	_build_menu_ui()
	_show_menu()
	_debug_args()


func _process(dt: float) -> void:
	if _turntable != null:
		_turntable.rotate_y(dt * 0.6)


func _register_inputs() -> void:
	var bindings := {
		"push": [KEY_W, KEY_UP],
		"brake": [KEY_S, KEY_DOWN],
		"steer_left": [KEY_A, KEY_LEFT],
		"steer_right": [KEY_D, KEY_RIGHT],
		"ollie": [KEY_SPACE],
		"flip": [KEY_J],
		"grind": [KEY_K],   # shove-it in free skate
		"reset": [KEY_R],
		"back": [KEY_ESCAPE],
		"confirm": [KEY_ENTER],
	}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)


# --- Menu -------------------------------------------------------------------

func _build_menu_ui() -> void:
	_menu_layer = CanvasLayer.new()
	add_child(_menu_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_layer.add_child(root)

	Build.label(root, "DROP IN", 120, Vector2(0.07, 0.12), -1, Color(1.0, 0.85, 0.25))
	Build.label(root, "skate to the beat", 30, Vector2(0.075, 0.36), -1, Color(0.6, 0.95, 1.0))

	var box := VBoxContainer.new()
	box.anchor_left = 0.075
	box.anchor_top = 0.48
	box.anchor_right = 0.075
	box.anchor_bottom = 0.48
	box.add_theme_constant_override("separation", 14)
	root.add_child(box)
	_first_button = _menu_button(box, "Rhythm Run", func() -> void: _start(RhythmMode, {}))
	_menu_button(box, "Free Skate", func() -> void: _start(FreeSkate, {}))
	_menu_button(box, "Quit", func() -> void: get_tree().quit())

	Build.label(root, "Arrow keys and ENTER to choose", 18, Vector2(0.075, 0.95), -1, Color(1, 1, 1, 0.7))


func _menu_button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 62)
	button.add_theme_font_size_override("font_size", 28)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _show_menu() -> void:
	_menu_layer.visible = true
	_first_button.grab_focus()

	# A skater on a turntable behind the menu.
	_menu_world = Node3D.new()
	add_child(_menu_world)
	Build.add_environment(_menu_world, Color(0.05, 0.04, 0.17), Color(0.8, 0.38, 0.45), Color(1.0, 0.75, 0.62), 1.2, Vector3(-35, 140, 0), true)
	Build.cyl(_menu_world, 2.4, 0.2, Color(0.2, 0.2, 0.28), Vector3(1.5, -0.1, 0), Vector3.ZERO, 24)
	Build.box(_menu_world, Vector3(80, 0.1, 80), Color(0.1, 0.1, 0.15), Vector3(0, -0.25, 0))
	_turntable = Node3D.new()
	_turntable.position = Vector3(1.5, 0, 0)
	_menu_world.add_child(_turntable)
	_turntable.add_child(SkaterModel.new())
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.position = Vector3(0, 1.3, 4.6)
	_menu_world.add_child(cam)
	cam.look_at(Vector3(0, 0.85, 0))
	cam.make_current()
	Build.add_outline(cam)


func _clear() -> void:
	if _mode != null:
		_mode.free()
		_mode = null
	if _menu_world != null:
		_menu_world.free()
		_menu_world = null
		_turntable = null


func _start(script: GDScript, options: Dictionary) -> void:
	_clear()
	_menu_layer.visible = false
	_mode = script.new()
	for key in options:
		_mode.set(key, options[key])
	# Deferred so a mode is never freed in the middle of its own signal.
	_mode.exit_requested.connect(func() -> void: _to_menu.call_deferred())
	if _mode.has_signal("restart_requested"):
		_mode.restart_requested.connect(func() -> void: _start.call_deferred(script, options))
	add_child(_mode)


func _to_menu() -> void:
	_clear()
	_show_menu()


## Prints the free skate skater's state twice a second (demo runs only).
func _trace_skater() -> void:
	while _mode != null and is_instance_valid(_mode):
		var skater: CharacterBody3D = _mode.get("_skater")
		if skater != null:
			print("t=%.1f pos=%s speed=%.1f floor=%s" % [Time.get_ticks_msec() / 1000.0, skater.global_position.snapped(Vector3.ONE * 0.1), skater.get("speed"), skater.is_on_floor()])
		await get_tree().create_timer(0.5).timeout


# --- Testing hooks ----------------------------------------------------------
# Run with:  godot --path . -- --mode=rhythm --autoplay --shot=out.png --delay=6

func _debug_args() -> void:
	var mode := ""
	var shot := ""
	var delay := 3.0
	var auto := false
	var demo := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = arg.substr(7)
		elif arg.begins_with("--shot="):
			shot = arg.substr(7)
		elif arg.begins_with("--delay="):
			delay = float(arg.substr(8))
		elif arg == "--autoplay":
			auto = true
		elif arg == "--demo":
			demo = true
	if mode == "rhythm":
		_start(RhythmMode, {"autoplay": auto})
	elif mode == "free":
		_start(FreeSkate, {})
		if demo:
			Input.action_press("push")
			_trace_skater()
	if shot != "":
		await get_tree().create_timer(delay).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shot)
		get_tree().quit()
