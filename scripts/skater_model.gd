extends Node3D
## The skater: a rigged model built by tools/make_skater.py, standing on a board
## assembled from primitive meshes. Forward is -Z and the origin sits where the
## wheels touch the ground. Poses are driven directly on the skeleton.

const Build = preload("res://scripts/build.gd")

const SKATER_SCENE := "res://assets/skater/skater.glb"
const BODY_Y := 0.12   # top of the deck
const REST_ARM_DEG := 45.0   # how far the arms sit from hanging in the rest pose

## Pose targets, set by whoever is driving the skater.
var lean := 0.0        # -1 right .. 1 left
var crouch := 0.15     # 0 standing .. 1 tucked
var airborne := false
var trick_busy := false

var _tilt: Node3D
var _board: Node3D
var _body: Node3D
var _figure: Node3D
var _skel: Skeleton3D
var _foot_rest_y := 0.0
var _lean_now := 0.0
var _crouch_now := 0.15
var _arm_now := 25.0
var _wobble := 0.0
var _tween: Tween


func _init() -> void:
	_build()


func _build() -> void:
	var grip := Color(0.1, 0.1, 0.12)
	var deck := Color(0.97, 0.8, 0.18)
	var metal := Color(0.7, 0.72, 0.76)
	var wheel := Color(0.96, 0.95, 0.9)

	_tilt = Node3D.new()
	add_child(_tilt)

	# Board: pivot at the centre of the deck so flips spin in place.
	_board = Node3D.new()
	_board.position.y = 0.1
	_tilt.add_child(_board)
	Build.box(_board, Vector3(0.23, 0.02, 0.6), grip, Vector3(0, 0.01, 0))
	Build.box(_board, Vector3(0.23, 0.015, 0.6), deck, Vector3(0, -0.0075, 0))
	Build.box(_board, Vector3(0.23, 0.03, 0.15), deck, Vector3(0, 0.022, -0.36), Vector3(22, 0, 0))
	Build.box(_board, Vector3(0.23, 0.03, 0.15), deck, Vector3(0, 0.022, 0.36), Vector3(-22, 0, 0))
	for z in [-0.21, 0.21]:
		var tz: float = z
		Build.box(_board, Vector3(0.17, 0.03, 0.05), metal, Vector3(0, -0.035, tz))
		for x in [-0.1, 0.1]:
			var wx: float = x
			Build.cyl(_board, 0.032, 0.04, wheel, Vector3(wx, -0.066, tz), Vector3(0, 0, 90), 8)

	# The model faces +Z; turned side-on to the board, the way a skater rides.
	_body = Node3D.new()
	_body.position.y = BODY_Y
	_body.rotation_degrees.y = 100.0
	_tilt.add_child(_body)

	var scene: PackedScene = load(SKATER_SCENE)
	_figure = scene.instantiate()
	_body.add_child(_figure)
	var skeletons := _figure.find_children("*", "Skeleton3D", true, false)
	if not skeletons.is_empty():
		_skel = skeletons[0]
		_foot_rest_y = _skel.get_bone_global_rest(_skel.find_bone("foot_l")).origin.y
	# Swap the imported materials for cel-shaded ones in the same colours.
	for node in _figure.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node
		for s in mi.mesh.get_surface_count():
			var source := mi.mesh.surface_get_material(s) as BaseMaterial3D
			var color := source.albedo_color if source != null else Color(0.5, 0.5, 0.5)
			mi.set_surface_override_material(s, Build.mat(color))


func _process(dt: float) -> void:
	_lean_now = lerpf(_lean_now, lean, 1.0 - exp(-10.0 * dt))
	_crouch_now = lerpf(_crouch_now, crouch, 1.0 - exp(-14.0 * dt))
	_wobble = move_toward(_wobble, 0.0, dt * 1.8)
	var shake := sin(Time.get_ticks_msec() * 0.035) * _wobble

	_tilt.rotation.z = _lean_now * 0.32 + shake * 0.35
	_tilt.rotation.x = shake * 0.12

	var arm_target := 78.0 if airborne else 25.0 + 25.0 * _crouch_now
	_arm_now = lerpf(_arm_now, arm_target, 1.0 - exp(-12.0 * dt))
	_pose(_crouch_now, _arm_now + shake * 40.0)


## Sets a bone's orientation as a rotation of its rest pose, expressed in the
## skeleton's own space (X side, Y up, Z the way the figure faces).
func _turn(bone: String, rotation: Basis) -> void:
	var i := _skel.find_bone(bone)
	if i < 0:
		return
	var parent := _skel.get_bone_parent(i)
	var parent_basis := _skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var target := rotation * _skel.get_bone_global_rest(i).basis
	_skel.set_bone_pose_rotation(i, (parent_basis.inverse() * target).orthonormalized().get_rotation_quaternion())


func _pose(c: float, arm_deg: float) -> void:
	if _skel == null:
		return
	var knee := deg_to_rad(12.0 + 38.0 * c)
	var fold := deg_to_rad(8.0 + 30.0 * c)
	_turn("spine_01", Basis(Vector3.RIGHT, fold * 0.6))
	_turn("spine_02", Basis(Vector3.RIGHT, fold * 0.8))
	_turn("spine_03", Basis(Vector3.RIGHT, fold))
	# Head looks along the board, towards the direction of travel.
	_turn("neck_01", Basis(Vector3.UP, deg_to_rad(30.0)))
	_turn("head", Basis(Vector3.UP, deg_to_rad(70.0)))
	var arm := deg_to_rad(arm_deg - REST_ARM_DEG)
	for side in [["_l", 1.0], ["_r", -1.0]]:
		var suffix: String = side[0]
		var sign: float = side[1]
		var arm_turn := Basis(Vector3.BACK, sign * arm) * Basis(Vector3.RIGHT, fold)
		_turn("clavicle" + suffix, Basis(Vector3.RIGHT, fold))
		_turn("upperarm" + suffix, arm_turn)
		_turn("lowerarm" + suffix, arm_turn * Basis(Vector3.RIGHT, -0.35))
		_turn("hand" + suffix, arm_turn * Basis(Vector3.RIGHT, -0.35))
		# Wide stance, knees bent forward, feet flat on the deck.
		var splay := Basis(Vector3.BACK, sign * deg_to_rad(11.0))
		_turn("thigh" + suffix, splay * Basis(Vector3.RIGHT, -knee))
		_turn("calf" + suffix, splay * Basis(Vector3.RIGHT, knee * 0.9))
		_turn("foot" + suffix, Basis.IDENTITY)
		_turn("ball" + suffix, Basis.IDENTITY)
	# Bending the legs lifts the feet; drop the figure so they stay on the deck.
	var foot_y := _skel.get_bone_global_pose(_skel.find_bone("foot_l")).origin.y
	_figure.position.y = _foot_rest_y - foot_y


## Board spins once around its long axis.
func do_flip(duration: float = 0.45) -> void:
	_start_trick()
	_tween.tween_method(_trick_pose.bind(2, 1.0), 0.0, 1.0, duration)
	_tween.tween_callback(_end_trick)


## Board spins flat underneath the feet.
func do_shove(duration: float = 0.42) -> void:
	_start_trick()
	_tween.tween_method(_trick_pose.bind(1, 1.0), 0.0, 1.0, duration)
	_tween.tween_callback(_end_trick)


## Stumble after a missed beat or a bad landing.
func bail() -> void:
	if _tween:
		_tween.kill()
	_end_trick()
	_wobble = 1.0


func _start_trick() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	trick_busy = true


func _trick_pose(t: float, axis: int, turns: float) -> void:
	var rot := Vector3.ZERO
	rot[axis] = t * TAU * turns
	_board.rotation = rot
	# The rider lifts off the deck while it spins.
	_body.position.y = BODY_Y + sin(t * PI) * 0.28


func _end_trick() -> void:
	_board.rotation = Vector3.ZERO
	_body.position.y = BODY_Y
	trick_busy = false
