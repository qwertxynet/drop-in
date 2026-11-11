"""Generates the skater (body, clothes, shoes, hair, face) with MPFB and exports it.

Run:  blender --background --python tools/make_skater.py
Writes assets/skater/skater.glb, skater.blend and preview renders.

Clothes are shells grown from the body surface, so they inherit its bone
weights. Each piece is its own object with its own material, which keeps them
swappable for customization later.
"""
import importlib
import math
import os
import random
import traceback

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "skater")
os.makedirs(OUT_DIR, exist_ok=True)

COLORS = {
    "Skin": (0.80, 0.58, 0.44),
    "Hoodie": (0.06, 0.06, 0.07),
    "Trousers": (0.2, 0.21, 0.25),
    "Shoes": (0.75, 0.08, 0.08),
    "Sole": (0.92, 0.92, 0.9),
    "Hair": (0.03, 0.03, 0.035),
    "Eyes": (0.02, 0.02, 0.02),
}

# Tunable face layout, as fractions of head height / metres.
EYE_HEIGHT = 0.50
EYE_SPACING = 0.033

mpfb = importlib.import_module("bl_ext.blender_org.mpfb")
HumanService = importlib.import_module(mpfb.__name__ + ".services.humanservice").HumanService
TargetService = importlib.import_module(mpfb.__name__ + ".services.targetservice").TargetService

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.preferences.addon_enable(module="bl_ext.blender_org.mpfb")

# --- Body -------------------------------------------------------------------
macros = TargetService.get_default_macro_info_dict()
macros["gender"] = 1.0
macros["age"] = 0.45
macros["muscle"] = 0.6
macros["weight"] = 0.42
macros["height"] = 0.55

body = HumanService.create_human(scale=0.1, macro_detail_dict=macros)
body.name = "Body"
bpy.context.view_layer.objects.active = body
body.select_set(True)
rig = HumanService.add_builtin_rig(body, "game_engine", import_weights=True)
rig.name = "SkaterRig"

for step in ("bake_shapekeys", "delete_helpers"):
    try:
        bpy.context.view_layer.objects.active = body
        getattr(bpy.ops.mpfb, step)()
    except Exception:
        print("FAILED", step)
        traceback.print_exc()

_materials = {}


def material(name):
    if name in _materials:
        return _materials[name]
    mat = bpy.data.materials.new(name)
    r, g, b = COLORS[name]
    mat.diffuse_color = (r, g, b, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (r, g, b, 1.0)
        bsdf.inputs["Roughness"].default_value = 1.0
    _materials[name] = mat
    return mat


body.data.materials.clear()
body.data.materials.append(material("Skin"))

mesh = body.data
bone_names = {b.name for b in rig.data.bones}
group_name = {g.index: g.name for g in body.vertex_groups}


def bone_weights(v):
    return [(group_name[g.group], g.weight) for g in v.groups
            if group_name.get(g.group) in bone_names and g.weight > 0.0]


dominant = {}
for v in mesh.vertices:
    weights = bone_weights(v)
    dominant[v.index] = max(weights, key=lambda w: w[1])[0] if weights else ""


def bone_head(name):
    return rig.matrix_world @ rig.data.bones[name].head_local


pelvis_z = bone_head("pelvis").z
hands = [bone_head("hand_l"), bone_head("hand_r")]


def finish_object(name, new_mesh, mat_name, rigid_bone=None):
    """Links a mesh, gives it a material and binds it to the skeleton."""
    obj = bpy.data.objects.new(name, new_mesh)
    bpy.context.scene.collection.objects.link(obj)
    new_mesh.materials.append(material(mat_name))
    if rigid_bone:
        group = obj.vertex_groups.new(name=rigid_bone)
        group.add(list(range(len(new_mesh.vertices))), 1.0, "REPLACE")
    return obj


def bind(obj):
    arm = obj.modifiers.new("Armature", "ARMATURE")
    arm.object = rig
    obj.parent = rig


# --- Regions ----------------------------------------------------------------
ARMS = {s + side for s in ("clavicle_", "upperarm_", "lowerarm_") for side in ("l", "r")}
LEGS = {s + side for s in ("thigh_", "calf_") for side in ("l", "r")}

hoodie_set, trouser_set, scalp_set = set(), set(), set()
head_verts = [v for v in mesh.vertices if dominant[v.index] == "head"]
head_min = min(v.co.z for v in head_verts)
head_max = max(v.co.z for v in head_verts)
head_h = head_max - head_min
head_mid_y = sum(v.co.y for v in head_verts) / len(head_verts)

for v in mesh.vertices:
    d = dominant[v.index]
    z = v.co.z
    if d in ARMS or d in ("spine_02", "spine_03") or (d in ("spine_01", "pelvis") and z > pelvis_z - 0.05):
        hoodie_set.add(v.index)
    if d in LEGS or (d in ("pelvis", "spine_01") and z < pelvis_z + 0.1):
        trouser_set.add(v.index)
    if d == "head":
        t = (z - head_min) / head_h
        # Top of the skull, plus the back of the head down to the nape.
        if t > 0.78 or (v.co.y > head_mid_y + 0.045 and t > 0.3):
            scalp_set.add(v.index)


def hoodie_push(v):
    """Loose body and sleeves, gathered in at the cuffs and the hem."""
    amount = 0.05
    if dominant[v.index].startswith("lowerarm") and min((v.co - h).length for h in hands) < 0.07:
        amount = 0.02
    elif v.co.z < pelvis_z + 0.0:
        amount = 0.032
    elif dominant[v.index] in ARMS:
        amount = 0.042
    return v.normal * amount


def trouser_push(v):
    """Straight-leg cut: pushed out sideways, widening towards the ankle."""
    flat = Vector((v.normal.x, v.normal.y, 0.0))
    direction = flat.normalized() if flat.length > 0.2 else v.normal
    drop = max(0.0, min(1.0, (pelvis_z - v.co.z) / pelvis_z))
    return direction * (0.03 + 0.035 * drop)


def hair_push(v):
    return v.normal * 0.016


def make_shell(name, vert_set, push, smooth_iters, thickness):
    """A garment grown out from the body faces inside vert_set."""
    faces = [p for p in mesh.polygons if all(i in vert_set for i in p.vertices)]
    used = sorted({i for p in faces for i in p.vertices})
    remap = {old: new for new, old in enumerate(used)}
    coords = [mesh.vertices[i].co + push(mesh.vertices[i]) for i in used]
    new_mesh = bpy.data.meshes.new(name)
    new_mesh.from_pydata(coords, [], [[remap[i] for i in p.vertices] for p in faces])
    new_mesh.update()

    bm = bmesh.new()
    bm.from_mesh(new_mesh)
    for _ in range(smooth_iters):
        bmesh.ops.smooth_vert(bm, verts=bm.verts, factor=0.5, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bm.to_mesh(new_mesh)
    bm.free()
    for p in new_mesh.polygons:
        p.use_smooth = True

    obj = finish_object(name, new_mesh, name)
    for bone in bone_names:
        obj.vertex_groups.new(name=bone)
    for old in used:
        for bone, weight in bone_weights(mesh.vertices[old]):
            obj.vertex_groups[bone].add([remap[old]], weight, "REPLACE")
    # Close the gap between the shell and the skin at cuffs and hems.
    solid = obj.modifiers.new("Thickness", "SOLIDIFY")
    solid.thickness = thickness
    solid.offset = -1.0
    bind(obj)
    print("SHELL", name, len(used), "verts", len(faces), "faces")
    return obj


def eroded(vert_set, rings):
    """vert_set shrunk by `rings` edge steps, so skin stays under cuffs/hems."""
    current = set(vert_set)
    for _ in range(rings):
        edge_touch = set()
        for e in mesh.edges:
            a, b = e.vertices
            if (a in current) != (b in current):
                edge_touch.add(a)
                edge_touch.add(b)
        current -= edge_touch
    return current


hoodie = make_shell("Hoodie", hoodie_set, hoodie_push, 6, 0.03)
trousers = make_shell("Trousers", trouser_set, trouser_push, 6, 0.03)
pieces = [body, hoodie, trousers]


def surface_front(x, z, verts, co=lambda v: v.co):
    """Front-most (lowest Y) point of `verts` near the given x and z."""
    near = sorted(verts, key=lambda v: (co(v).x - x) ** 2 + (co(v).z - z) ** 2)[:12]
    return min(co(v).y for v in near)


def surface_back(x, z, verts):
    near = sorted(verts, key=lambda v: (v.co.x - x) ** 2 + (v.co.z - z) ** 2)[:12]
    return max(v.co.y for v in near)


# --- Hood and kangaroo pocket ------------------------------------------------
neck = bone_head("neck_01")
torso_verts = [mesh.vertices[i] for i in hoodie_set if dominant[i].startswith("spine")]
bm = bmesh.new()
hood_y = surface_back(0.0, neck.z - 0.03, torso_verts) + 0.045
bmesh.ops.create_uvsphere(
    bm, u_segments=12, v_segments=8, radius=1.0,
    matrix=Matrix.Translation((0.0, hood_y, neck.z - 0.02))
    @ Matrix.Rotation(math.radians(-25), 4, "X")
    @ Matrix.Diagonal((0.15, 0.075, 0.13, 1.0)))
pocket_z = pelvis_z + 0.1
pocket_y = surface_front(0.0, pocket_z, torso_verts) - 0.04
bmesh.ops.create_cube(
    bm, size=1.0,
    matrix=Matrix.Translation((0.0, pocket_y, pocket_z)) @ Matrix.Diagonal((0.22, 0.012, 0.1, 1.0)))
extras = bpy.data.meshes.new("HoodieExtras")
bm.to_mesh(extras)
bm.free()
for p in extras.polygons:
    p.use_smooth = True
hood = finish_object("HoodieExtras", extras, "Hoodie")
hood_group = hood.vertex_groups.new(name="spine_03")
pocket_group = hood.vertex_groups.new(name="spine_01")
for v in extras.vertices:
    (hood_group if v.co.z > pelvis_z + 0.3 else pocket_group).add([v.index], 1.0, "REPLACE")
bind(hood)
pieces.append(hood)

# --- Hair: a scalp shell plus messy clumps -----------------------------------
hair = make_shell("Hair", scalp_set, hair_push, 2, 0.015)
random.seed(4)
bm = bmesh.new()
scalp = [mesh.vertices[i] for i in sorted(scalp_set)]
for v in scalp[::9]:
    t = (v.co.z - head_min) / head_h
    front = v.co.y < head_mid_y
    # Clumps on top sweep forward into a fringe; the rest hang down and back.
    sweep = Vector((0.0, -0.9, -0.35)) if (front and t > 0.8) else Vector((0.0, 0.25, -0.8))
    direction = (v.normal * 0.8 + sweep + Vector((random.uniform(-0.3, 0.3), random.uniform(-0.2, 0.2), 0.0))).normalized()
    length = random.uniform(0.045, 0.08)
    rot = Vector((0.0, 0.0, 1.0)).rotation_difference(direction).to_matrix().to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=5, radius1=random.uniform(0.028, 0.04), radius2=0.004, depth=length,
        matrix=Matrix.Translation(v.co + direction * (length * 0.35)) @ rot)
clumps = bpy.data.meshes.new("HairClumps")
bm.to_mesh(clumps)
bm.free()
clump_obj = finish_object("HairClumps", clumps, "Hair", rigid_bone="head")
bind(clump_obj)
pieces += [hair, clump_obj]

# --- Face: simple dark eyes and brows, read well under cel shading -----------
eye_z = head_min + head_h * EYE_HEIGHT
bm = bmesh.new()
for side in (-1.0, 1.0):
    x = side * EYE_SPACING
    y = surface_front(x, eye_z, head_verts)
    bmesh.ops.create_uvsphere(
        bm, u_segments=10, v_segments=6, radius=1.0,
        matrix=Matrix.Translation((x, y + 0.002, eye_z)) @ Matrix.Diagonal((0.014, 0.006, 0.0075, 1.0)))
    brow_y = surface_front(x, eye_z + 0.022, head_verts)
    bmesh.ops.create_cube(
        bm, size=1.0,
        matrix=Matrix.Translation((x, brow_y - 0.001, eye_z + 0.022))
        @ Matrix.Rotation(math.radians(side * -8.0), 4, "Y")
        @ Matrix.Diagonal((0.034, 0.008, 0.006, 1.0)))
face = bpy.data.meshes.new("Face")
bm.to_mesh(face)
bm.free()
face_obj = finish_object("Face", face, "Eyes", rigid_bone="head")
bind(face_obj)
pieces.append(face_obj)

# --- Shoes: an upper hugging each foot on a wider, flat white sole -----------
for side in ("l", "r"):
    foot = "foot_" + side
    ankle_z = bone_head(foot).z + 0.035
    pts = [mesh.vertices[i].co.copy() for i in dominant
           if dominant[i] in (foot, "ball_" + side) and mesh.vertices[i].co.z < ankle_z]
    centre = sum(pts, Vector()) / len(pts)
    floor = min(p.z for p in pts)

    def hull_mesh(name, points):
        bm = bmesh.new()
        for p in points:
            bm.verts.new(p)
        hull = bmesh.ops.convex_hull(bm, input=bm.verts)
        bmesh.ops.delete(bm, geom=hull["geom_interior"], context="VERTS")
        out = bpy.data.meshes.new(name)
        bm.to_mesh(out)
        bm.free()
        return out

    upper_pts = []
    for p in pts:
        q = centre + (p - centre) * 1.12
        q.z = max(p.z + 0.012, floor + 0.02)
        upper_pts.append(q)
    sole_pts = []
    for p in pts:
        q = centre + (p - centre) * 1.2
        sole_pts.append(Vector((q.x, q.y, floor)))
        sole_pts.append(Vector((q.x, q.y, floor + 0.03)))
    for name, points, mat_name in (("Shoe_", upper_pts, "Shoes"), ("Sole_", sole_pts, "Sole")):
        obj = finish_object(name + side, hull_mesh(name + side, points), mat_name, rigid_bone=foot)
        bind(obj)
        pieces.append(obj)

# --- Remove skin that is fully hidden under clothes, so it cannot poke out ---
hidden = eroded(hoodie_set, 2) | eroded(trouser_set, 2)
bm = bmesh.new()
bm.from_mesh(mesh)
doomed = [f for f in bm.faces if all(v.index in hidden for v in f.verts)]
bmesh.ops.delete(bm, geom=doomed, context="FACES")
bm.to_mesh(mesh)
bm.free()
for p in mesh.polygons:
    p.use_smooth = True

# --- Export -----------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
for obj in pieces + [rig]:
    obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT_DIR, "skater.glb"),
                          use_selection=True, export_yup=True, export_apply=True)

# --- Preview renders --------------------------------------------------------
scene = bpy.context.scene
cam_data = bpy.data.cameras.new("Cam")
cam_data.lens = 50
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "MATERIAL"
scene.display.shading.show_object_outline = True
scene.render.resolution_x = 600
scene.render.resolution_y = 900
shots = (
    ("front", 28.0, 4.3, Vector((0.0, 0.0, 0.9)), 1.25),
    ("back", 152.0, 4.3, Vector((0.0, 0.0, 0.9)), 1.25),
    ("head", 22.0, 1.0, Vector((0.0, 0.0, head_min + head_h * 0.5)), head_min + head_h * 0.6),
)
for label, angle, dist, target, cam_z in shots:
    a = math.radians(angle)
    cam.location = Vector((math.sin(a) * dist, -math.cos(a) * dist, cam_z))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = os.path.join(OUT_DIR, "skater_preview_%s.png" % label)
    bpy.ops.render.render(write_still=True)

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT_DIR, "source", "skater.blend"))
print("DONE")
