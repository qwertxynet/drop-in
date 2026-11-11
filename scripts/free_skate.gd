extends Node3D
## Free skate: an open park with no timer and no beat. Roam and string tricks.

signal exit_requested

const Build = preload("res://scripts/build.gd")
const Skater = preload("res://scripts/skater.gd")

const HALF := 42.0
const SPAWN := Vector3(0, 0.05, 25)

var _skater: CharacterBody3D
var _cam: Camera3D
var _cam_yaw := 0.0
var _rails: Array = []
var _score := 0
var _trick_fade := 0.0
var _speed_label: Label
var _score_label: Label
var _trick_label: Label


func _ready() -> void:
	var env := Build.add_environment(self, Color(0.2, 0.45, 0.85), Color(0.75, 0.85, 0.95), Color(1.0, 0.96, 0.88), 1.05, Vector3(-48, 40, 0), false)
	env.ambient_light_energy = 0.6
	_build_park()

	_skater = Skater.new()
	_skater.position = SPAWN
	_skater.rails = _rails
	add_child(_skater)
	_skater.trick_landed.connect(_on_trick)
	_skater.bailed.connect(_on_bail)

	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.position = SPAWN + Vector3(0, 2.8, 6)
	add_child(_cam)
	_cam.make_current()
	Build.add_outline(_cam)

	_build_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		exit_requested.emit()
	elif event.is_action_pressed("reset"):
		_skater.respawn(SPAWN, 0.0)


func _physics_process(dt: float) -> void:
	if _skater.global_position.y < -10.0:
		_skater.respawn(SPAWN, 0.0)

	# Chase camera: sits behind the direction of travel, kept inside the walls.
	_cam_yaw = lerp_angle(_cam_yaw, _skater.travel_yaw(), 1.0 - exp(-3.5 * dt))
	var back := Vector3(sin(_cam_yaw), 0.0, cos(_cam_yaw))
	var want: Vector3 = _skater.global_position + back * 5.2 + Vector3.UP * 2.6
	var limit := HALF - 0.8
	want.x = clampf(want.x, -limit, limit)
	want.z = clampf(want.z, -limit, limit)
	_cam.global_position = _cam.global_position.lerp(want, 1.0 - exp(-8.0 * dt))
	_cam.look_at(_skater.global_position + Vector3.UP * 1.1)

	var kmh: float = absf(_skater.speed) * 3.6
	_speed_label.text = "%d km/h" % int(kmh)
	if _trick_fade > 0.0:
		_trick_fade -= dt
		_trick_label.modulate.a = clampf(_trick_fade, 0.0, 1.0)


func _on_trick(text: String, points: int) -> void:
	_score += points
	_score_label.text = "Session  %d" % _score
	_trick_label.text = "%s   +%d" % [text, points]
	_trick_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_trick_fade = 2.2


func _on_bail() -> void:
	_trick_label.text = "Bail!"
	_trick_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35))
	_trick_fade = 1.5


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)
	Build.label(hud, "FREE SKATE", 22, Vector2(0.025, 0.03), -1, Color(0.6, 0.95, 1.0))
	_score_label = Build.label(hud, "Session  0", 34, Vector2(0.025, 0.075), -1)
	_speed_label = Build.label(hud, "0 km/h", 30, Vector2(0.975, 0.03), 1)
	_trick_label = Build.label(hud, "", 44, Vector2(0.5, 0.16), 0, Color(1.0, 0.85, 0.3))
	_trick_label.modulate.a = 0.0
	Build.label(hud,
		"W push   S brake   A/D steer   SPACE ollie   J kickflip   K shove-it   R reset   ESC menu",
		18, Vector2(0.5, 0.975), 0, Color(1, 1, 1, 0.85))


# --- Park -------------------------------------------------------------------

func _build_park() -> void:
	var wood := Color(0.8, 0.62, 0.42)
	var concrete := Color(0.5, 0.51, 0.56)
	var teal := Color(0.15, 0.62, 0.66)
	var pink := Color(0.95, 0.4, 0.6)
	var steel := Color(0.85, 0.87, 0.92)

	# Grass out to the horizon, concrete inside the walls.
	Build.box(self, Vector3(600, 0.1, 600), Color(0.33, 0.55, 0.3), Vector3(0, -0.08, 0))
	var floor_body := StaticBody3D.new()
	add_child(floor_body)
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(HALF * 2.0 + 20.0, 1.0, HALF * 2.0 + 20.0)
	var floor_col := CollisionShape3D.new()
	floor_col.shape = floor_shape
	floor_col.position.y = -0.5
	floor_body.add_child(floor_col)
	var plane := PlaneMesh.new()
	plane.size = Vector2(HALF * 2.0, HALF * 2.0)
	Build.part(floor_body, plane, Build.ground_material())

	# Perimeter walls.
	var span := HALF * 2.0 + 1.2
	Build.solid_box(self, Vector3(span, 2.4, 0.6), teal, Vector3(0, 1.2, -HALF - 0.3))
	Build.solid_box(self, Vector3(span, 2.4, 0.6), teal, Vector3(0, 1.2, HALF + 0.3))
	Build.solid_box(self, Vector3(0.6, 2.4, span), pink, Vector3(-HALF - 0.3, 1.2, 0))
	Build.solid_box(self, Vector3(0.6, 2.4, span), pink, Vector3(HALF + 0.3, 1.2, 0))

	# Invisible barriers above the walls so big airs come back into the park.
	for edge in [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0)]:
		var dir: Vector3 = edge
		var barrier := StaticBody3D.new()
		barrier.position = dir * (HALF + 0.3) + Vector3.UP * 20.0
		add_child(barrier)
		var barrier_shape := BoxShape3D.new()
		barrier_shape.size = Vector3(0.6, 40.0, span) if dir.x != 0.0 else Vector3(span, 40.0, 0.6)
		var barrier_col := CollisionShape3D.new()
		barrier_col.shape = barrier_shape
		barrier.add_child(barrier_col)

	# Quarter pipes at both ends, banks on the sides.
	# Decks run all the way back to the wall so there is no gap to fall into.
	Build.quarter_pipe(self, 30.0, 5.0, wood, Vector3(0, 0, -33), 0.0, 62.0, 4.7)
	Build.quarter_pipe(self, 30.0, 5.0, wood, Vector3(0, 0, 33), 180.0, 62.0, 4.7)
	Build.ramp(self, 18.0, 1.8, 6.0, concrete, Vector3(38.5, 0, 0), -90.0)
	Build.ramp(self, 18.0, 1.8, 6.0, concrete, Vector3(-38.5, 0, 0), 90.0)

	# Fun box in the middle with a rail along the top.
	Build.solid_box(self, Vector3(5, 1, 5), concrete, Vector3(0, 0.5, 0))
	Build.ramp(self, 5.0, 1.0, 4.0, wood, Vector3(0, 0, 4.5), 0.0)
	Build.ramp(self, 5.0, 1.0, 4.0, wood, Vector3(0, 0, -4.5), 180.0)
	_rails.append(Build.rail(self, Vector3(1.7, 1.45, 2.3), Vector3(1.7, 1.45, -2.3), steel, 0.45))

	# Kicker straight ahead of the spawn.
	Build.ramp(self, 3.0, 0.9, 3.0, pink, Vector3(0, 0, 16), 0.0)

	# Kicker gap: launch ramp and landing ramp facing each other.
	Build.ramp(self, 3.5, 1.0, 3.2, teal, Vector3(-16, 0, -3), 0.0)
	Build.ramp(self, 3.5, 1.0, 3.2, teal, Vector3(-16, 0, -10), 180.0)

	# Flat rails.
	_rails.append(Build.rail(self, Vector3(-10, 0.5, 13), Vector3(-10, 0.5, 4), steel))
	_rails.append(Build.rail(self, Vector3(8, 0.5, 16), Vector3(14, 0.5, 9), steel))
	_rails.append(Build.rail(self, Vector3(6, 0.45, -16), Vector3(19, 0.45, -16), steel))
	_rails.append(Build.rail(self, Vector3(-28, 0.5, -20), Vector3(-18, 0.5, -24), steel))

	# Ledges and manual pads.
	Build.solid_box(self, Vector3(7, 0.4, 2.4), concrete.lightened(0.1), Vector3(13, 0.2, -6))
	Build.solid_box(self, Vector3(2.4, 0.4, 8), concrete.lightened(0.1), Vector3(-25, 0.2, 12))
	Build.solid_box(self, Vector3(5, 0.4, 5), teal.darkened(0.2), Vector3(24, 0.2, 18))
	Build.solid_box(self, Vector3(2.6, 0.8, 2.6), pink.darkened(0.15), Vector3(24, 0.4, 18))
	Build.ramp(self, 4.0, 0.7, 3.0, wood, Vector3(26, 0, -20), 45.0)

	# Scenery outside the walls.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var at := -HALF
	while at <= HALF:
		Build.tree(self, Vector3(at, 0, -HALF - 5.0 - rng.randf() * 3.0), rng.randf_range(0.9, 1.5))
		Build.tree(self, Vector3(at, 0, HALF + 5.0 + rng.randf() * 3.0), rng.randf_range(0.9, 1.5))
		Build.tree(self, Vector3(-HALF - 5.0 - rng.randf() * 3.0, 0, at), rng.randf_range(0.9, 1.5))
		Build.tree(self, Vector3(HALF + 5.0 + rng.randf() * 3.0, 0, at), rng.randf_range(0.9, 1.5))
		at += 8.5
	var towers := [Color(0.85, 0.8, 0.7), Color(0.7, 0.75, 0.85), Color(0.9, 0.7, 0.6), Color(0.65, 0.7, 0.72)]
	for i in 26:
		var angle := TAU * i / 26.0 + rng.randf() * 0.1
		var dist := rng.randf_range(85.0, 130.0)
		var h := rng.randf_range(10.0, 34.0)
		var tint: Color = towers[i % towers.size()]
		Build.box(self, Vector3(rng.randf_range(10, 18), h, rng.randf_range(10, 18)), tint, Vector3(cos(angle) * dist, h * 0.5, sin(angle) * dist))
	for corner in [Vector3(-39, 0, -39), Vector3(39, 0, -39), Vector3(-39, 0, 39), Vector3(39, 0, 39)]:
		var c: Vector3 = corner
		Build.lamp(self, c, Color(1.0, 0.95, 0.75), -signf(c.x))
