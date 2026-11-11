extends CharacterBody3D
## Free skate physics: push, carve, ollie, flip tricks, ramps and rail grinds.

signal trick_landed(text: String, points: int)
signal bailed

const SkaterModel = preload("res://scripts/skater_model.gd")

const GRAVITY := 22.0
const PUSH_ACCEL := 8.0
const PUSH_MAX := 13.0
const BRAKE := 14.0
const FRICTION := 0.9
const TURN := 2.3
const AIR_TURN := 6.5
const OLLIE_V := 7.2
const SNAP := 0.35
const GRIND_REACH := 0.5
const TRICK_POINTS := {"Ollie": 25, "Kickflip": 200, "Shove-it": 150}

## Yaw in radians; 0 faces -Z.
var heading := 0.0
## Signed speed along the heading (negative means rolling backwards).
var speed := 0.0
## Rails that can be ground: each entry is [start, end] along the top of the bar.
var rails: Array = []
var model: Node3D

var _was_on_floor := false
var _air_vel := Vector3.ZERO
var _air_spin := 0.0
var _air_tricks: Array[String] = []
var _grind: Array = []
var _grind_dir := Vector3.ZERO
var _grind_len := 0.0
var _grind_cool := 0.0
var _steer := 0.0
var _visual_basis := Basis.IDENTITY


func _ready() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.5
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 0.75
	add_child(col)
	model = SkaterModel.new()
	add_child(model)
	# Steep limit so quarter pipes count as floor rather than walls.
	floor_max_angle = deg_to_rad(75.0)
	floor_snap_length = SNAP
	floor_stop_on_slope = false
	_visual_basis = Basis(Vector3.UP, heading)


func forward() -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))


func is_grinding() -> bool:
	return not _grind.is_empty()


## Direction of travel as a yaw, for the chase camera.
func travel_yaw() -> float:
	var v := _grind_dir * speed if is_grinding() else velocity
	if Vector2(v.x, v.z).length() > 2.0:
		return atan2(-v.x, -v.z)
	return heading


func respawn(pos: Vector3, yaw: float) -> void:
	global_position = pos
	heading = yaw
	speed = 0.0
	velocity = Vector3.ZERO
	_grind = []
	_air_tricks.clear()
	_air_spin = 0.0
	_was_on_floor = false
	_visual_basis = Basis(Vector3.UP, yaw)


func _physics_process(dt: float) -> void:
	_grind_cool = maxf(0.0, _grind_cool - dt)
	_steer = Input.get_axis("steer_right", "steer_left")
	if is_grinding():
		_process_grind(dt)
	elif is_on_floor():
		_process_ground(dt)
	else:
		_process_air(dt)
	_update_model(dt)


func _process_ground(dt: float) -> void:
	var n := get_floor_normal()
	if not _was_on_floor:
		_land(n)
	heading += _steer * TURN * dt
	var slope_dir := forward().slide(n).normalized()

	if Input.is_action_pressed("push") and speed < PUSH_MAX:
		speed = minf(speed + PUSH_ACCEL * dt, PUSH_MAX)
	if Input.is_action_pressed("brake"):
		speed = move_toward(speed, 0.0, BRAKE * dt)
	speed = move_toward(speed, 0.0, FRICTION * dt)
	# Gravity along the slope: climbing costs speed, rolling down gains it.
	speed -= GRAVITY * slope_dir.y * dt

	# Rolling backwards on the flat: swing round to face the direction of travel.
	if speed < -0.5 and n.y > 0.98:
		heading += PI
		speed = -speed
		slope_dir = forward().slide(n).normalized()

	velocity = slope_dir * speed
	floor_snap_length = SNAP
	var ollied := false
	if Input.is_action_just_pressed("ollie"):
		velocity += Vector3.UP * OLLIE_V
		floor_snap_length = 0.0
		ollied = true

	_was_on_floor = true
	_air_vel = velocity
	move_and_slide()

	if is_on_floor():
		# Hitting a wall bleeds off whatever speed was aimed into it. Only the
		# horizontal part is compared: move_and_slide drops the vertical part of
		# the velocity on down-slopes, which must not count as lost speed.
		if is_on_wall():
			var flat_before := Vector2(_air_vel.x, _air_vel.z)
			var flat_after := Vector2(velocity.x, velocity.z)
			if flat_before.length_squared() > 0.0001:
				speed *= clampf(flat_after.dot(flat_before) / flat_before.length_squared(), 0.0, 1.0)
	else:
		_air_spin = 0.0
		_air_tricks.clear()
		if ollied:
			_air_tricks.append("Ollie")


func _process_air(dt: float) -> void:
	heading += _steer * AIR_TURN * dt
	_air_spin += _steer * AIR_TURN * dt
	velocity.y -= GRAVITY * dt

	if not model.trick_busy:
		if Input.is_action_just_pressed("flip"):
			model.do_flip()
			_air_tricks.erase("Ollie")
			_air_tricks.append("Kickflip")
		elif Input.is_action_just_pressed("grind"):
			model.do_shove()
			_air_tricks.erase("Ollie")
			_air_tricks.append("Shove-it")

	if _try_grind():
		return
	_was_on_floor = false
	_air_vel = velocity
	move_and_slide()


func _land(n: Vector3) -> void:
	var slope_dir := forward().slide(n).normalized()
	var flat_speed := Vector2(_air_vel.x, _air_vel.z).length()
	speed = _air_vel.dot(slope_dir)
	var sideways := flat_speed > 5.0 and absf(speed) < flat_speed * 0.45 and n.y > 0.9
	if model.trick_busy or sideways:
		model.bail()
		speed *= 0.3
		bailed.emit()
	else:
		_score_air()
	_air_tricks.clear()
	_air_spin = 0.0


func _score_air() -> void:
	var parts := PackedStringArray()
	var points := 0
	var spins := int(round(absf(_air_spin) / PI))
	if spins > 0:
		parts.append(str(spins * 180))
		points += spins * 150
	for trick in _air_tricks:
		parts.append(trick)
		var value: int = TRICK_POINTS.get(trick, 50)
		points += value
	if parts.is_empty():
		return
	trick_landed.emit(" ".join(parts), points)


# --- Grinding ---------------------------------------------------------------

func _try_grind() -> bool:
	if _grind_cool > 0.0 or velocity.y > 1.0:
		return false
	var p := global_position
	for r in rails:
		var a: Vector3 = r[0]
		var b: Vector3 = r[1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var q := a + ab * t
		var flat := Vector2(p.x - q.x, p.z - q.z).length()
		if flat < GRIND_REACH and absf(p.y - q.y) < 0.4 and t > 0.02 and t < 0.98:
			var dir := ab.normalized()
			var along := velocity.dot(dir)
			if along < 0.0:
				dir = -dir
				along = -along
			_grind = r
			_grind_dir = dir
			_grind_len = 0.0
			speed = maxf(along, 4.0)
			heading = atan2(-dir.x, -dir.z)
			global_position = q
			velocity = Vector3.ZERO
			return true
	return false


func _process_grind(dt: float) -> void:
	speed = maxf(speed - 0.6 * dt, 2.5)
	var step := _grind_dir * speed * dt
	global_position += step
	_grind_len += step.length()
	var a: Vector3 = _grind[0]
	var b: Vector3 = _grind[1]
	var end := b if _grind_dir.dot(b - a) > 0.0 else a
	var past := (global_position - end).dot(_grind_dir) > 0.0
	var jump := Input.is_action_just_pressed("ollie")
	if not (past or jump):
		return
	velocity = _grind_dir * speed
	if jump:
		velocity.y = OLLIE_V
	trick_landed.emit("50-50 Grind  %.1f m" % _grind_len, 100 + int(_grind_len * 20.0))
	_grind = []
	_grind_cool = 0.35
	_was_on_floor = false
	_air_spin = 0.0
	_air_tricks.clear()
	if jump:
		_air_tricks.append("Ollie")


# --- Visuals ----------------------------------------------------------------

func _update_model(dt: float) -> void:
	var grounded := is_on_floor() and not is_grinding()
	var up := get_floor_normal() if grounded else Vector3.UP
	var fwd := forward().slide(up).normalized()
	var target := Basis.looking_at(fwd, up)
	_visual_basis = _visual_basis.orthonormalized().slerp(target, 1.0 - exp(-14.0 * dt))
	model.basis = _visual_basis
	model.airborne = not grounded and not is_grinding()
	model.lean = _steer * clampf(absf(speed) / 7.0, 0.0, 1.0)
	if is_grinding():
		model.crouch = 0.5
	elif grounded:
		model.crouch = 0.35 if Input.is_action_pressed("brake") else 0.15
	else:
		model.crouch = 0.3
