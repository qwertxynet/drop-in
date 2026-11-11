extends RefCounted
## Helpers for assembling low-poly geometry, lighting and HUD text in code.
## Everything in Drop In is built from these, so there are no imported assets.


## Shared toon lighting: two hard bands of light instead of a smooth falloff.
const TOON_LIGHT := """
void light() {
	float ndl = dot(NORMAL, LIGHT);
	float lit = smoothstep(0.0, 0.04, ndl) * 0.7 + smoothstep(0.6, 0.64, ndl) * 0.3;
	float shadow = smoothstep(0.35, 0.45, ATTENUATION);
	DIFFUSE_LIGHT += lit * shadow * LIGHT_COLOR / PI;
}
"""

static var _toon_shader: Shader
static var _outline_shader: Shader


## Cel-shaded material. `rough` and `metallic` are kept for call compatibility;
## the toon look ignores them.
static func mat(color: Color, _rough: float = 0.85, _metallic: float = 0.0) -> Material:
	if _toon_shader == null:
		_toon_shader = Shader.new()
		_toon_shader.code = """
shader_type spatial;
render_mode specular_disabled;
uniform vec4 albedo : source_color = vec4(1.0);
void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
}
""" + TOON_LIGHT
	var m := ShaderMaterial.new()
	m.shader = _toon_shader
	m.set_shader_parameter("albedo", color)
	return m


## Full-screen ink outlines, drawn where depth or surface direction changes
## sharply. Attach once per camera.
static func add_outline(camera: Camera3D, line_color: Color = Color(0.03, 0.02, 0.05)) -> void:
	if _outline_shader == null:
		_outline_shader = Shader.new()
		_outline_shader.code = """
shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;
uniform vec4 line_color : source_color = vec4(0.03, 0.02, 0.05, 1.0);
uniform float thickness = 1.4;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float linear_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

vec3 normal_at(vec2 uv) {
	return texture(normal_tex, uv).rgb * 2.0 - 1.0;
}

void fragment() {
	vec2 px = thickness / VIEWPORT_SIZE;
	vec2 uv = SCREEN_UV;
	float dc = linear_depth(uv, INV_PROJECTION_MATRIX);
	float dl = linear_depth(uv - vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float dr = linear_depth(uv + vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float du = linear_depth(uv - vec2(0.0, px.y), INV_PROJECTION_MATRIX);
	float dd = linear_depth(uv + vec2(0.0, px.y), INV_PROJECTION_MATRIX);
	// Second difference: flat surfaces cancel out, steps in depth do not.
	float depth_edge = (abs(dl + dr - 2.0 * dc) + abs(du + dd - 2.0 * dc)) / dc;
	vec3 nc = normal_at(uv);
	float normal_edge = 4.0
		- dot(nc, normal_at(uv - vec2(px.x, 0.0))) - dot(nc, normal_at(uv + vec2(px.x, 0.0)))
		- dot(nc, normal_at(uv - vec2(0.0, px.y))) - dot(nc, normal_at(uv + vec2(0.0, px.y)));
	float edge = max(smoothstep(0.04, 0.09, depth_edge), smoothstep(0.5, 0.9, normal_edge));
	edge *= 1.0 - smoothstep(70.0, 140.0, dc);
	ALBEDO = line_color.rgb;
	ALPHA = edge * line_color.a;
}
"""
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var m := ShaderMaterial.new()
	m.shader = _outline_shader
	m.set_shader_parameter("line_color", line_color)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = m
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(mi)


static func glow(color: Color, energy: float = 2.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


static func part(parent: Node, mesh: Mesh, material: Material, pos: Vector3 = Vector3.ZERO, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi


static func box(parent: Node, size: Vector3, color: Color, pos: Vector3 = Vector3.ZERO, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return part(parent, mesh, mat(color), pos, rot_deg)


static func cyl(parent: Node, radius: float, height: float, color: Color, pos: Vector3 = Vector3.ZERO, rot_deg: Vector3 = Vector3.ZERO, segments: int = 8, top_radius: float = -1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.rings = 1
	return part(parent, mesh, mat(color), pos, rot_deg)


static func solid_box(parent: Node, size: Vector3, color: Color, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg
	parent.add_child(body)
	box(body, size, color)
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	return body


# --- Convex prisms (ramps, quarter pipes) -----------------------------------

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, centre: Vector3) -> void:
	# Godot treats clockwise triangles as front-facing; flip any that face inward.
	var n := (c - a).cross(b - a)
	if n.length_squared() < 0.0000001:
		return
	var face_centre := (a + b + c) / 3.0
	if n.dot(face_centre - centre) < 0.0:
		var swap := b
		b = c
		c = swap
		n = -n
	n = n.normalized()
	st.set_normal(n)
	st.add_vertex(a)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_normal(n)
	st.add_vertex(c)


## Adds a convex prism to `body`. `profile` is a convex outline given as (z, y)
## points, extruded `width` metres along X.
static func add_prism(body: Node3D, profile: PackedVector2Array, width: float, material: Material) -> void:
	var hw := width * 0.5
	var c2 := Vector2.ZERO
	for p in profile:
		c2 += p
	c2 /= profile.size()
	var centre := Vector3(0.0, c2.y, c2.x)
	var count := profile.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points := PackedVector3Array()
	for i in count:
		var p := profile[i]
		var q := profile[(i + 1) % count]
		var l0 := Vector3(-hw, p.y, p.x)
		var l1 := Vector3(-hw, q.y, q.x)
		var r0 := Vector3(hw, p.y, p.x)
		var r1 := Vector3(hw, q.y, q.x)
		_tri(st, l0, l1, r1, centre)
		_tri(st, l0, r1, r0, centre)
		points.append(l0)
		points.append(r0)
	for i in range(1, count - 1):
		for x in [-hw, hw]:
			var sx: float = x
			_tri(st,
				Vector3(sx, profile[0].y, profile[0].x),
				Vector3(sx, profile[i].y, profile[i].x),
				Vector3(sx, profile[i + 1].y, profile[i + 1].x),
				centre)
	part(body, st.commit(), material)
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)


## A wedge that rises towards local -Z. `pos` is the centre of its footprint.
static func ramp(parent: Node, width: float, height: float, length: float, color: Color, pos: Vector3, yaw_deg: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees.y = yaw_deg
	parent.add_child(body)
	var hl := length * 0.5
	var profile := PackedVector2Array([Vector2(hl, 0.0), Vector2(-hl, 0.0), Vector2(-hl, height)])
	add_prism(body, profile, width, mat(color))
	return body


## A curved transition that starts flat at `pos` and curls up towards local -Z,
## ending in a flat deck.
static func quarter_pipe(parent: Node, width: float, radius: float, color: Color, pos: Vector3, yaw_deg: float = 0.0, max_angle_deg: float = 62.0, deck: float = 2.5) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees.y = yaw_deg
	parent.add_child(body)
	var material := mat(color)
	var segments := 7
	var max_a := deg_to_rad(max_angle_deg)
	for i in segments:
		var a0 := max_a * i / segments
		var a1 := max_a * (i + 1) / segments
		var z0 := -radius * sin(a0)
		var z1 := -radius * sin(a1)
		var y0 := radius * (1.0 - cos(a0))
		var y1 := radius * (1.0 - cos(a1))
		add_prism(body, PackedVector2Array([Vector2(z0, 0.0), Vector2(z1, 0.0), Vector2(z1, y1), Vector2(z0, y0)]), width, material)
	var top_z := -radius * sin(max_a)
	var top_y := radius * (1.0 - cos(max_a))
	var deck_size := Vector3(width, top_y, deck)
	var deck_pos := Vector3(0.0, top_y * 0.5, top_z - deck * 0.5)
	box(body, deck_size, color.darkened(0.12), deck_pos)
	var shape := BoxShape3D.new()
	shape.size = deck_size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = deck_pos
	body.add_child(col)
	# Coping along the lip.
	var coping := cyl(body, 0.06, width, Color(0.8, 0.82, 0.86), Vector3(0.0, top_y, top_z), Vector3(0, 0, 90), 6)
	coping.material_override = mat(Color(0.8, 0.82, 0.86), 0.3, 0.8)
	return body


## A grind rail from `a` to `b` (both on the top of the bar). Returns [a, b].
static func rail(parent: Node, a: Vector3, b: Vector3, color: Color, post_h: float = -1.0, solid: bool = true) -> Array:
	var length := a.distance_to(b)
	var holder := Node3D.new()
	holder.position = (a + b) * 0.5
	holder.basis = Basis.looking_at((b - a).normalized(), Vector3.UP)
	parent.add_child(holder)
	var bar_size := Vector3(0.09, 0.09, length)
	var bar := box(holder, bar_size, color, Vector3(0.0, -0.045, 0.0))
	bar.material_override = mat(color, 0.3, 0.7)
	var ph := a.y if post_h < 0.0 else post_h
	var posts := maxi(2, int(length / 2.5) + 1)
	for i in posts:
		var t := float(i) / (posts - 1)
		var z := lerpf(-length * 0.5 + 0.15, length * 0.5 - 0.15, t)
		box(holder, Vector3(0.07, ph, 0.07), color.darkened(0.3), Vector3(0.0, -ph * 0.5, z))
	if solid:
		var body := StaticBody3D.new()
		holder.add_child(body)
		var shape := BoxShape3D.new()
		shape.size = bar_size
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = Vector3(0.0, -0.045, 0.0)
		body.add_child(col)
	return [a, b]


# --- Scenery ----------------------------------------------------------------

static func tree(parent: Node, pos: Vector3, s: float = 1.0) -> void:
	var root := Node3D.new()
	root.position = pos
	root.scale = Vector3.ONE * s
	parent.add_child(root)
	cyl(root, 0.16, 1.6, Color(0.42, 0.28, 0.18), Vector3(0, 0.8, 0), Vector3.ZERO, 6)
	cyl(root, 1.25, 1.9, Color(0.2, 0.55, 0.3), Vector3(0, 2.3, 0), Vector3.ZERO, 6, 0.0)
	cyl(root, 0.95, 1.6, Color(0.25, 0.63, 0.34), Vector3(0, 3.2, 0), Vector3.ZERO, 6, 0.0)
	cyl(root, 0.6, 1.2, Color(0.32, 0.7, 0.38), Vector3(0, 4.0, 0), Vector3.ZERO, 6, 0.0)


static func lamp(parent: Node, pos: Vector3, bulb: Color, reach: float = 1.0) -> void:
	var root := Node3D.new()
	root.position = pos
	parent.add_child(root)
	cyl(root, 0.07, 4.4, Color(0.2, 0.2, 0.24), Vector3(0, 2.2, 0), Vector3.ZERO, 6)
	box(root, Vector3(absf(reach), 0.08, 0.08), Color(0.2, 0.2, 0.24), Vector3(reach * 0.5, 4.36, 0))
	var mesh := SphereMesh.new()
	mesh.radius = 0.2
	mesh.height = 0.4
	mesh.radial_segments = 8
	mesh.rings = 4
	part(root, mesh, glow(bulb, 3.0), Vector3(reach, 4.2, 0))


static func add_environment(parent: Node, sky_top: Color, sky_horizon: Color, sun_color: Color, sun_energy: float, sun_rot_deg: Vector3, glow_enabled: bool) -> Environment:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = sky_top
	sky_mat.sky_horizon_color = sky_horizon
	sky_mat.ground_horizon_color = sky_horizon
	sky_mat.ground_bottom_color = sky_horizon.darkened(0.5)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = glow_enabled
	var world := WorldEnvironment.new()
	world.environment = env
	parent.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = sun_rot_deg
	sun.light_color = sun_color
	sun.light_energy = sun_energy
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	parent.add_child(sun)
	return env


## Concrete slabs with joints, drawn in world space so motion is readable.
static func ground_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
varying vec3 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 g = world_pos.xz / 4.0;
	vec2 f = abs(fract(g) - 0.5);
	float joint = step(0.488, max(f.x, f.y));
	vec2 id = floor(g);
	float n = fract(sin(dot(id, vec2(12.9898, 78.233))) * 43758.5453);
	vec3 slab = mix(vec3(0.38, 0.39, 0.42), vec3(0.47, 0.48, 0.5), n);
	ALBEDO = mix(slab, vec3(0.25, 0.26, 0.29), joint);
	ROUGHNESS = 0.95;
}
""" + TOON_LIGHT
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


# --- HUD --------------------------------------------------------------------

## A label pinned to a normalised screen point. align: -1 left, 0 centre, 1 right.
static func label(parent: Control, text: String, size: int, anchor: Vector2, align: int = 0, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", maxi(4, int(size * 0.2)))
	parent.add_child(l)
	if align < 0:
		l.grow_horizontal = Control.GROW_DIRECTION_END
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	elif align > 0:
		l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	else:
		l.grow_horizontal = Control.GROW_DIRECTION_BOTH
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if anchor.y > 0.7:
		l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	elif anchor.y < 0.3:
		l.grow_vertical = Control.GROW_DIRECTION_END
	else:
		l.grow_vertical = Control.GROW_DIRECTION_BOTH
	l.anchor_left = anchor.x
	l.anchor_right = anchor.x
	l.anchor_top = anchor.y
	l.anchor_bottom = anchor.y
	l.offset_left = 0.0
	l.offset_right = 0.0
	l.offset_top = 0.0
	l.offset_bottom = 0.0
	return l
