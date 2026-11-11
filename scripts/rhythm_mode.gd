extends Node3D
## Rhythm run: the skater rolls down a street locked to the beat. Steer into
## line with each hoop, then hit its key as the approach ring closes on it.

signal exit_requested
signal restart_requested

const Build = preload("res://scripts/build.gd")
const SkaterModel = preload("res://scripts/skater_model.gd")
const Metronome = preload("res://scripts/metronome.gd")

const BPM := 110.0
const MIX_RATE := 44100
const COUNT_IN := 8            # beats of clicks before the first note
const TOTAL_BEATS := 104
const UNITS_PER_BEAT := 7.0    # metres travelled per beat
const LANE_X: Array[float] = [-3.0, 0.0, 3.0]
const ROAD_HALF := 4.8
const STEER_SPEED := 9.5
const LINE_TOLERANCE := 1.3    # how far off a hoop's centre still counts
const PERFECT_WINDOW := 0.055  # seconds either side of the beat
const GOOD_WINDOW := 0.13
const APPROACH_BEATS := 2.0
const SHOW_BEATS := 7.0        # how far ahead hoops become visible
const RAIL_H := 0.55
const HOOP_Y := 1.25
const HOOP_R := 1.25

enum { OLLIE, FLIP, GRIND }
enum { PENDING, HOLDING, DONE }

const TYPE_ACTION: Array[String] = ["ollie", "flip", "grind"]
const TYPE_KEY: Array[String] = ["SPACE", "J", "K"]
const TYPE_COLOR: Array[Color] = [Color(1.0, 0.8, 0.2), Color(1.0, 0.35, 0.7), Color(0.25, 0.9, 1.0)]

## Plays itself with perfect timing. Used for testing and demos.
var autoplay := false

var _beat_len := 0.5
var _speed := 14.0
var _notes: Array[Dictionary] = []
var _next := 0
var _hold: Dictionary = {}

var _started := false
var _finished := false
var _time_begin := 0
var _time_delay := 0.0

var _x := 0.0
var _base_y := 0.0
var _hop_t := 1.0
var _hop_h := 0.0
var _hop_dur := 0.4

var _score := 0
var _combo := 0
var _max_combo := 0
var _perfect := 0
var _good := 0
var _miss := 0
var _judged := 0

var _player: AudioStreamPlayer
var _hit_player: AudioStreamPlayer
var _model: Node3D
var _cam: Camera3D
var _hoop_mesh: TorusMesh
var _approach_mesh: TorusMesh

var _hud: Control
var _score_label: Label
var _combo_label: Label
var _judge_label: Label
var _count_label: Label
var _acc_label: Label
var _progress: ColorRect
var _judge_fade := 0.0


func _ready() -> void:
	var track: Dictionary = Metronome.build_track(BPM, TOTAL_BEATS, MIX_RATE)
	var beat_len: float = track["beat_len"]
	_beat_len = beat_len
	_speed = UNITS_PER_BEAT / _beat_len

	_player = AudioStreamPlayer.new()
	_player.stream = track["stream"]
	add_child(_player)
	_hit_player = AudioStreamPlayer.new()
	_hit_player.stream = Metronome.blip(660.0, 0.07, 0.5, MIX_RATE)
	_hit_player.volume_db = -8.0
	add_child(_hit_player)

	_hoop_mesh = _torus(HOOP_R, 0.07)
	_approach_mesh = _torus(HOOP_R, 0.035)

	_build_world()
	_notes = _make_chart()
	for n in _notes:
		_spawn_note(n)

	_model = SkaterModel.new()
	add_child(_model)
	_cam = Camera3D.new()
	_cam.fov = 72.0
	add_child(_cam)
	_cam.make_current()
	Build.add_outline(_cam)
	_place_skater(0.0, 0.0)

	_build_hud()
	get_tree().create_timer(0.8).timeout.connect(_begin)


func _begin() -> void:
	# Clock runs off the system timer, offset by the audio pipeline delay, so
	# what you see lines up with what you hear.
	_time_begin = Time.get_ticks_usec()
	_time_delay = AudioServer.get_time_to_next_mix() + AudioServer.get_output_latency()
	_player.play()
	_started = true


func _clock() -> float:
	if not _started:
		return 0.0
	return maxf(0.0, (Time.get_ticks_usec() - _time_begin) / 1000000.0 - _time_delay)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		exit_requested.emit()
		return
	if _finished:
		if event.is_action_pressed("confirm") or event.is_action_pressed("ollie"):
			restart_requested.emit()
		return
	if autoplay or not _started:
		return
	for type in 3:
		if event.is_action_pressed(TYPE_ACTION[type]):
			_press(type)


func _process(dt: float) -> void:
	if _finished:
		return
	var now := _clock()

	# Steering. While grinding the skater is locked to the rail.
	var steer := Input.get_axis("steer_left", "steer_right")
	if autoplay:
		steer = _auto_steer()
	if _hold.is_empty():
		_x = clampf(_x + steer * STEER_SPEED * dt, -ROAD_HALF + 0.5, ROAD_HALF - 0.5)
	else:
		var lane: int = _hold["lane"]
		_x = move_toward(_x, LANE_X[lane], STEER_SPEED * dt)
		steer = 0.0

	if autoplay:
		_auto_press(now)
	_update_hold(now)
	_update_notes(now)

	# Skater pose and position.
	var hop := 0.0
	if _hop_t < 1.0:
		_hop_t = minf(1.0, _hop_t + dt / _hop_dur)
		hop = sin(_hop_t * PI) * _hop_h
	_base_y = move_toward(_base_y, 0.0 if _hold.is_empty() else RAIL_H, 6.0 * dt)
	_place_skater(now, _base_y + hop)
	_model.airborne = _hop_t < 1.0
	_model.lean = -steer
	_model.crouch = 0.15 if _hold.is_empty() else 0.5

	_update_hud(now, dt)
	if now >= (TOTAL_BEATS - 3) * _beat_len:
		_finish()


func _place_skater(now: float, y: float) -> void:
	var z := -now * _speed
	_model.position = Vector3(_x, y, z)
	_cam.position = Vector3(_x * 0.55, 3.5, z + 7.0)
	_cam.look_at(Vector3(_x * 0.75, 1.0, z - 9.0))


# --- Judging ----------------------------------------------------------------

func _press(type: int) -> void:
	var now := _clock()
	var best: Dictionary = {}
	var best_off := GOOD_WINDOW
	for i in range(_next, mini(_next + 12, _notes.size())):
		var n := _notes[i]
		var time: float = n["time"]
		if time > now + GOOD_WINDOW:
			break
		if n["state"] != PENDING or n["type"] != type:
			continue
		var off := absf(time - now)
		if off <= best_off:
			best = n
			best_off = off

	if best.is_empty():
		# Nothing to hit: a free hop, no penalty.
		if type != GRIND and _hold.is_empty():
			_hop(0.7, 0.36)
		return

	var lane: int = best["lane"]
	if absf(_x - LANE_X[lane]) > LINE_TOLERANCE:
		_miss_note(best, "OFF LINE")
		return

	var grade := "PERFECT" if best_off <= PERFECT_WINDOW else "GOOD"
	_award(grade)
	_hide_markers(best)
	_hit_player.play()
	match type:
		OLLIE:
			best["state"] = DONE
			_hop(1.0, 0.42)
		FLIP:
			best["state"] = DONE
			_hop(1.35, 0.46)
			_model.do_flip(0.4)
		GRIND:
			best["state"] = HOLDING
			_hold = best
			_hop(0.35, 0.22)


func _award(grade: String) -> void:
	_combo += 1
	_max_combo = maxi(_max_combo, _combo)
	_judged += 1
	var multiplier := 1 + mini(int(_combo * 0.1), 7)
	if grade == "PERFECT":
		_perfect += 1
		_score += 300 * multiplier
		_show_judgement("PERFECT", Color(1.0, 0.85, 0.25))
	else:
		_good += 1
		_score += 100 * multiplier
		_show_judgement(grade, Color(0.45, 1.0, 0.55))


func _miss_note(n: Dictionary, text: String) -> void:
	n["state"] = DONE
	_hide_markers(n)
	_combo = 0
	_miss += 1
	_judged += 1
	_model.bail()
	_show_judgement(text, Color(1.0, 0.4, 0.35))


func _update_notes(now: float) -> void:
	while _next < _notes.size() and _notes[_next]["state"] == DONE:
		_next += 1
	var window := APPROACH_BEATS * _beat_len
	for i in range(_next, mini(_next + 14, _notes.size())):
		var n := _notes[i]
		if n["state"] != PENDING:
			continue
		var time: float = n["time"]
		if now > time + GOOD_WINDOW:
			_miss_note(n, "MISS")
			continue
		# Markers only appear once a note is close, to keep the distance clear.
		var remaining := time - now
		var near := remaining < SHOW_BEATS * _beat_len
		var hoop: MeshInstance3D = n["hoop"]
		var label: Label3D = n["label"]
		hoop.visible = near
		label.visible = near
		# Approach ring closes onto the hoop as the beat arrives.
		var ring: MeshInstance3D = n["approach"]
		ring.visible = remaining < window
		if ring.visible:
			ring.scale = Vector3.ONE * (1.0 + 2.2 * clampf(remaining / window, 0.0, 1.0))


func _update_hold(now: float) -> void:
	if _hold.is_empty():
		return
	var end_time: float = _hold["end_time"]
	var held := autoplay or Input.is_action_pressed("grind")
	if now >= end_time or (not held and now >= end_time - 0.2):
		# Rode it to the end.
		_hold["state"] = DONE
		_hold = {}
		_combo += 1
		_max_combo = maxi(_max_combo, _combo)
		_judged += 1
		_perfect += 1
		_score += 300 * (1 + mini(int(_combo * 0.1), 7))
		_show_judgement("GRIND!", Color(0.3, 0.95, 1.0))
		_hit_player.play()
		_hop(0.6, 0.34)
	elif not held:
		# Let go early.
		var dropped := _hold
		_hold = {}
		_miss_note(dropped, "DROPPED")


func _hop(height: float, duration: float) -> void:
	_hop_t = 0.0
	_hop_h = height
	_hop_dur = duration


func _hide_markers(n: Dictionary) -> void:
	for key in ["hoop", "approach", "label"]:
		var node: Node3D = n[key]
		node.visible = false


# --- Autoplay ---------------------------------------------------------------

func _next_pending() -> Dictionary:
	for i in range(_next, mini(_next + 6, _notes.size())):
		if _notes[i]["state"] == PENDING:
			return _notes[i]
	return {}


func _auto_steer() -> float:
	var n := _next_pending()
	if n.is_empty():
		return 0.0
	var lane: int = n["lane"]
	return clampf((LANE_X[lane] - _x) * 4.0, -1.0, 1.0)


func _auto_press(now: float) -> void:
	var n := _next_pending()
	if n.is_empty():
		return
	var time: float = n["time"]
	if now >= time:
		var type: int = n["type"]
		_press(type)


# --- Chart ------------------------------------------------------------------

func _note(beat: float, lane: int, type: int, length: float) -> Dictionary:
	return {
		"beat": beat,
		"time": beat * _beat_len,
		"end_time": (beat + length) * _beat_len,
		"lane": lane,
		"type": type,
		"len": length,
		"state": PENDING,
	}


## A fixed, seeded chart that ramps up: slow ollies first, then flips, rails
## and off-beat doubles. Lanes only ever move one step per beat.
func _make_chart() -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 110261110
	var notes: Array[Dictionary] = []
	var lane := 1
	var beat := float(COUNT_IN)
	var last := float(TOTAL_BEATS - 8)
	while beat <= last:
		var phase := (beat - COUNT_IN) / (last - COUNT_IN)
		var step := 2.0 if phase < 0.2 else 1.0
		lane = clampi(lane + rng.randi_range(-1, 1), 0, 2)
		var roll := rng.randf()
		if phase >= 0.2 and roll < 0.22 and beat + 4.0 <= last:
			var length := float(rng.randi_range(2, 3))
			notes.append(_note(beat, lane, GRIND, length))
			beat += length + 1.0
			continue
		var type := OLLIE
		if phase >= 0.1 and roll > 0.6:
			type = FLIP
		notes.append(_note(beat, lane, type, 0.0))
		if phase >= 0.55 and rng.randf() < 0.3:
			notes.append(_note(beat + 0.5, lane, OLLIE, 0.0))
		beat += step
	return notes


func _torus(radius: float, thickness: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - thickness
	mesh.outer_radius = radius + thickness
	mesh.rings = 28
	mesh.ring_segments = 6
	return mesh


func _spawn_note(n: Dictionary) -> void:
	var type: int = n["type"]
	var lane: int = n["lane"]
	var time: float = n["time"]
	var color: Color = TYPE_COLOR[type]
	var root := Node3D.new()
	root.position = Vector3(LANE_X[lane], 0.0, -time * _speed)
	add_child(root)

	# The hoop stands upright at the exact spot the skater is on the beat.
	var upright := Vector3(90, 0, 0)
	var hoop := Build.part(root, _hoop_mesh, Build.glow(color, 2.5), Vector3(0, HOOP_Y, 0), upright)
	hoop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hoop.visible = false
	n["hoop"] = hoop
	var approach := Build.part(root, _approach_mesh, Build.glow(color.lightened(0.5), 3.0), Vector3(0, HOOP_Y, 0), upright)
	approach.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	approach.visible = false
	n["approach"] = approach

	var label := Label3D.new()
	label.text = TYPE_KEY[type]
	label.font_size = 96
	label.pixel_size = 0.0065
	label.outline_size = 24
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, HOOP_Y + HOOP_R + 0.5, 0)
	label.visible = false
	root.add_child(label)
	n["label"] = label

	# The obstacle sits just past the hoop, under the top of the jump.
	var ahead := -_speed * 0.21
	match type:
		OLLIE:
			Build.box(root, Vector3(2.2, 0.45, 0.25), color, Vector3(0, 0.3, ahead))
			Build.box(root, Vector3(2.22, 0.12, 0.27), Color(0.95, 0.95, 0.95), Vector3(0, 0.3, ahead))
			for x in [-0.9, 0.9]:
				var lx: float = x
				Build.box(root, Vector3(0.12, 0.1, 0.6), Color(0.2, 0.2, 0.24), Vector3(lx, 0.05, ahead))
		FLIP:
			Build.box(root, Vector3(1.7, 0.5, 1.0), color.darkened(0.25), Vector3(0, 0.25, ahead))
			Build.box(root, Vector3(1.2, 0.4, 0.8), color, Vector3(0.1, 0.7, ahead))
		GRIND:
			var length: float = n["len"]
			var rail_len := length * UNITS_PER_BEAT
			Build.rail(root, Vector3(0, RAIL_H, 0.5), Vector3(0, RAIL_H, -rail_len), color, -1.0, false)
			var finish := Build.part(root, _approach_mesh, Build.glow(color, 2.0), Vector3(0, HOOP_Y, -rail_len), upright)
			finish.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# --- World ------------------------------------------------------------------

func _build_world() -> void:
	var env := Build.add_environment(self, Color(0.05, 0.04, 0.17), Color(0.8, 0.38, 0.45), Color(1.0, 0.72, 0.6), 1.1, Vector3(-32, 28, 0), true)
	env.fog_enabled = true
	env.fog_light_color = Color(0.55, 0.3, 0.45)
	env.fog_density = 0.006

	var length := (TOTAL_BEATS + 8) * UNITS_PER_BEAT
	var mid_z := -length * 0.5 + 25.0
	Build.box(self, Vector3(ROAD_HALF * 2.0, 0.2, length), Color(0.13, 0.13, 0.18), Vector3(0, -0.1, mid_z))
	for s in [-1.0, 1.0]:
		var side: float = s
		Build.box(self, Vector3(4.0, 0.35, length), Color(0.3, 0.29, 0.36), Vector3(side * (ROAD_HALF + 2.0), -0.05, mid_z))
		Build.box(self, Vector3(0.08, 0.02, length), Color(0.42, 0.42, 0.55), Vector3(side * 1.5, 0.005, mid_z))

	# A stripe across the road on every beat, heavier on each bar.
	var beat_mesh := BoxMesh.new()
	beat_mesh.size = Vector3(ROAD_HALF * 2.0, 0.02, 0.1)
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(ROAD_HALF * 2.0, 0.02, 0.32)
	var beat_mat := Build.mat(Color(0.3, 0.3, 0.42))
	var bar_mat := Build.glow(Color(0.55, 0.45, 0.9), 0.8)
	for b in TOTAL_BEATS:
		var on_bar := b % 4 == 0
		Build.part(self, bar_mesh if on_bar else beat_mesh, bar_mat if on_bar else beat_mat, Vector3(0, 0.006, -b * UNITS_PER_BEAT))

	# Buildings down both sides, with the odd lit sign.
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var palette := [Color(0.28, 0.24, 0.42), Color(0.2, 0.3, 0.45), Color(0.42, 0.25, 0.38), Color(0.24, 0.24, 0.32), Color(0.35, 0.3, 0.5)]
	var signs := [Color(1.0, 0.35, 0.7), Color(0.25, 0.9, 1.0), Color(1.0, 0.8, 0.2)]
	for s in [-1.0, 1.0]:
		var side: float = s
		var z := 40.0
		while z > -length + 25.0:
			var w := rng.randf_range(7.0, 13.0)
			var h := rng.randf_range(6.0, 22.0)
			var d := rng.randf_range(8.0, 14.0)
			var tint: Color = palette[rng.randi() % palette.size()]
			var x := side * (ROAD_HALF + 4.0 + d * 0.5)
			Build.box(self, Vector3(d, h, w), tint, Vector3(x, h * 0.5, z - w * 0.5))
			if rng.randf() < 0.45:
				var sign_color: Color = signs[rng.randi() % signs.size()]
				var sign_mesh := BoxMesh.new()
				sign_mesh.size = Vector3(0.15, 0.6, w * 0.6)
				Build.part(self, sign_mesh, Build.glow(sign_color, 2.0), Vector3(side * (ROAD_HALF + 3.9), rng.randf_range(3.0, 5.0), z - w * 0.5))
			z -= w + rng.randf_range(0.5, 3.0)

	# Street lamps every bar, alternating sides.
	var lamp_index := 0
	var lamp_z := 0.0
	while lamp_z > -length + 40.0:
		var lamp_side := -1.0 if lamp_index % 2 == 0 else 1.0
		Build.lamp(self, Vector3(lamp_side * (ROAD_HALF + 0.7), 0, lamp_z), Color(1.0, 0.85, 0.6), -lamp_side)
		lamp_z -= UNITS_PER_BEAT * 4.0
		lamp_index += 1


# --- HUD --------------------------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)

	var track := ColorRect.new()
	track.color = Color(1, 1, 1, 0.15)
	track.anchor_right = 1.0
	track.offset_bottom = 6.0
	_hud.add_child(track)
	_progress = ColorRect.new()
	_progress.color = Color(0.25, 0.9, 1.0)
	_progress.anchor_right = 0.0
	_progress.offset_bottom = 6.0
	_hud.add_child(_progress)

	_score_label = Build.label(_hud, "0", 44, Vector2(0.025, 0.035), -1)
	_acc_label = Build.label(_hud, "100.0%", 26, Vector2(0.975, 0.035), 1)
	_combo_label = Build.label(_hud, "", 54, Vector2(0.5, 0.86), 0, Color(1.0, 0.85, 0.25))
	_judge_label = Build.label(_hud, "", 46, Vector2(0.5, 0.2), 0)
	_count_label = Build.label(_hud, "GET READY", 80, Vector2(0.5, 0.4), 0)
	Build.label(_hud, "A / D  steer", 20, Vector2(0.025, 0.97), -1, Color(1, 1, 1, 0.9))
	Build.label(_hud, "SPACE  ollie", 20, Vector2(0.36, 0.97), 0, TYPE_COLOR[OLLIE])
	Build.label(_hud, "J  kickflip", 20, Vector2(0.52, 0.97), 0, TYPE_COLOR[FLIP])
	Build.label(_hud, "K  hold to grind", 20, Vector2(0.7, 0.97), 0, TYPE_COLOR[GRIND])
	Build.label(_hud, "ESC  menu", 20, Vector2(0.975, 0.97), 1, Color(1, 1, 1, 0.7))
	if autoplay:
		Build.label(_hud, "AUTOPLAY", 22, Vector2(0.5, 0.035), 0, Color(1, 1, 1, 0.7))


func _show_judgement(text: String, color: Color) -> void:
	_judge_label.text = text
	_judge_label.add_theme_color_override("font_color", color)
	_judge_fade = 0.7


func _accuracy() -> float:
	if _judged == 0:
		return 100.0
	return 100.0 * (_perfect * 300.0 + _good * 100.0) / (_judged * 300.0)


func _update_hud(now: float, dt: float) -> void:
	_score_label.text = str(_score)
	_acc_label.text = "%.1f%%" % _accuracy()
	_combo_label.text = "%d x" % _combo if _combo >= 2 else ""
	_progress.anchor_right = clampf(now / ((TOTAL_BEATS - 3) * _beat_len), 0.0, 1.0)
	_judge_fade = maxf(0.0, _judge_fade - dt)
	_judge_label.modulate.a = clampf(_judge_fade * 3.0, 0.0, 1.0)

	var beat := now / _beat_len
	var text := ""
	if not _started or beat < COUNT_IN - 4:
		text = "GET READY"
	elif beat < COUNT_IN - 1:
		text = str(int(ceil(COUNT_IN - 1 - beat)))
	elif beat < COUNT_IN + 0.5:
		text = "GO!"
	_count_label.text = text


func _finish() -> void:
	_finished = true
	_judge_label.text = ""
	_combo_label.text = ""
	_count_label.text = ""
	var acc := _accuracy()
	var grade := "D"
	if acc >= 95.0:
		grade = "S"
	elif acc >= 88.0:
		grade = "A"
	elif acc >= 75.0:
		grade = "B"
	elif acc >= 60.0:
		grade = "C"

	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.08, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.add_child(shade)
	Build.label(_hud, "RUN COMPLETE", 40, Vector2(0.5, 0.2), 0, Color(0.6, 0.95, 1.0))
	Build.label(_hud, grade, 150, Vector2(0.5, 0.38), 0, Color(1.0, 0.85, 0.25))
	Build.label(_hud, "Score  %d" % _score, 40, Vector2(0.5, 0.56), 0)
	Build.label(_hud, "Accuracy  %.1f%%      Best combo  %d" % [acc, _max_combo], 28, Vector2(0.5, 0.66), 0)
	Build.label(_hud, "Perfect  %d      Good  %d      Miss  %d" % [_perfect, _good, _miss], 28, Vector2(0.5, 0.74), 0)
	Build.label(_hud, "ENTER  run it again        ESC  menu", 24, Vector2(0.5, 0.86), 0, Color(1, 1, 1, 0.85))
