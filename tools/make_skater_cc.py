"""Builds the skater from Reallusion's free CC Toon base and exports it for Godot.

Run:  blender --background --python tools/make_skater_cc.py

Needs the "CC Character Base" folder (Reallusion, free account download) in the
project root. Writes assets/skater_cc/, which is git-ignored: Reallusion's
licence forbids redistributing the base or models built from it, so this
model must be built locally and never committed.

Clothes are shells grown from the body surface, so they inherit its bone
weights. Each piece is its own object, which keeps them swappable.
"""
import math
import os
import random

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "CC Character Base", "FBX", "05_Toon Neutral_M")
OUT_DIR = os.path.join(ROOT, "assets", "skater_cc")
os.makedirs(OUT_DIR, exist_ok=True)

COLORS = {
    "Hoodie": (0.06, 0.06, 0.07),
    "Trousers": (0.2, 0.21, 0.25),
    "Shoes": (0.75, 0.08, 0.08),
    "Sole": (0.92, 0.92, 0.9),
    "Hair": (0.03, 0.03, 0.035),
}
TEXTURE_SIZE = 1024
DROP = ("EyeOcclusion", "TearLine", "Tongue", "Teeth")

bpy.ops.wm.read_factory_settings(use_empty=True)
fbx = [f for f in os.listdir(SOURCE) if f.lower().endswith(".fbx")][0]
bpy.ops.import_scene.fbx(filepath=os.path.join(SOURCE, fbx))

rig = next(o for o in bpy.data.objects if o.type == "ARMATURE")
rig.name = "SkaterRig"
body = bpy.data.objects["CC_Base_Body"]
for obj in list(bpy.data.objects):
    if obj.type == "MESH" and any(word in obj.name for word in DROP):
        bpy.data.objects.remove(obj)
keep = [o for o in bpy.data.objects if o.type == "MESH"]

# --- Materials: base colour texture only, downscaled -------------------------
def simplify_material(mat):
    """Rebuilds a material as a plain Principled BSDF with just its colour map."""
    image = None
    if mat.use_nodes:
        bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf and bsdf.inputs["Base Color"].links:
            node = bsdf.inputs["Base Color"].links[0].from_node
            # Follow mix or colour nodes back to the first image.
            seen = 0
            while node is not None and node.type != "TEX_IMAGE" and seen < 6:
                linked = [i for i in node.inputs if i.links]
                node = linked[0].links[0].from_node if linked else None
                seen += 1
            if node is not None and node.type == "TEX_IMAGE":
                image = node.image
        if image is None:
            image = next((n.image for n in mat.node_tree.nodes
                          if n.type == "TEX_IMAGE" and n.image and "iffuse" in n.image.name), None)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Roughness"].default_value = 1.0
    mat.node_tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    if image is not None:
        if image.size[0] > TEXTURE_SIZE:
            image.scale(TEXTURE_SIZE, TEXTURE_SIZE)
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = image
        mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        mat.node_tree.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
        mat.blend_method = "CLIP" if hasattr(mat, "blend_method") else None
    print("MAT", mat.name, image.name if image else None)


for obj in keep:
    for mat in obj.data.materials:
        if mat is not None:
            simplify_material(mat)

_materials = {}


def material(name):
    if name in _materials:
        return _materials[name]
    mat = bpy.data.materials.new(name)
    r, g, b = COLORS[name]
    mat.diffuse_color = (r, g, b, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1.0)
    bsdf.inputs["Roughness"].default_value = 1.0
    _materials[name] = mat
    return mat


# --- Body analysis, all in world space (metres) ------------------------------
mesh = body.data
M = body.matrix_world.copy()
M_inv = M.inverted()
M3 = M.to_3x3()
world = [M @ v.co for v in mesh.vertices]
normals = [(M3 @ v.normal).normalized() for v in mesh.vertices]

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


def has(name, *words):
    return any(w in name for w in words)


hip_z = bone_head("CC_Base_Hip").z
hands = [bone_head("CC_Base_L_Hand"), bone_head("CC_Base_R_Hand")]
neck = bone_head("CC_Base_NeckTwist01")

ARM_WORDS = ("Clavicle", "Upperarm", "Forearm", "Elbow")
LEG_WORDS = ("Thigh", "Calf", "Knee")
TORSO_WORDS = ("Waist", "Spine01", "Spine02")
HAND_WORDS = ("Hand", "Index", "Mid", "Ring", "Pinky", "Thumb")

hoodie_set, trouser_set, scalp_set, head_set = set(), set(), set(), set()
for v in mesh.vertices:
    d = dominant[v.index]
    z = world[v.index].z
    # Torso is everything between the hips and the neck except the hands, so
    # helper bones such as the chest ones are covered too.
    torso = hip_z - 0.05 < z < neck.z - 0.01 and not has(d, *HAND_WORDS, "Neck", "Head")
    if has(d, *ARM_WORDS) or torso:
        hoodie_set.add(v.index)
    if has(d, *LEG_WORDS) or (has(d, "Pelvis", "Hip") and z < hip_z + 0.1):
        trouser_set.add(v.index)
    if d == "CC_Base_Head":
        head_set.add(v.index)

head_z = [world[i].z for i in head_set]
head_min, head_max = min(head_z), max(head_z)
head_h = head_max - head_min
head_mid_y = sum(world[i].y for i in head_set) / len(head_set)
for i in head_set:
    t = (world[i].z - head_min) / head_h
    # Top of the skull, plus the back of the head down to the nape.
    if t > 0.8 or (world[i].y > head_mid_y + 0.03 and t > 0.35):
        scalp_set.add(i)


def hoodie_push(i):
    """Loose body and sleeves, gathered in at the cuffs and the hem."""
    p = world[i]
    amount = 0.045
    if has(dominant[i], "Forearm") and min((p - h).length for h in hands) < 0.07:
        amount = 0.018
    elif p.z < hip_z:
        amount = 0.03
    elif has(dominant[i], *ARM_WORDS):
        amount = 0.038
    return normals[i] * amount


def trouser_push(i):
    """Straight-leg cut: pushed out sideways, widening towards the ankle."""
    n = normals[i]
    flat = Vector((n.x, n.y, 0.0))
    direction = flat.normalized() if flat.length > 0.2 else n
    drop = max(0.0, min(1.0, (hip_z - world[i].z) / hip_z))
    return direction * (0.028 + 0.032 * drop)


def hair_push(i):
    return normals[i] * 0.012


def attach(obj):
    """Parents to the rig without moving it, and deforms it with the skeleton."""
    obj.parent = rig
    obj.matrix_parent_inverse = rig.matrix_world.inverted()
    arm = obj.modifiers.new("Armature", "ARMATURE")
    arm.object = rig


def world_object(name, new_mesh, mat_name, rigid_bone=None):
    """An object whose vertex coordinates are already in world space."""
    obj = bpy.data.objects.new(name, new_mesh)
    bpy.context.scene.collection.objects.link(obj)
    new_mesh.materials.append(material(mat_name))
    if rigid_bone:
        group = obj.vertex_groups.new(name=rigid_bone)
        group.add(list(range(len(new_mesh.vertices))), 1.0, "REPLACE")
    attach(obj)
    return obj


def make_shell(name, vert_set, push, smooth_iters, thickness):
    faces = [p for p in mesh.polygons if all(i in vert_set for i in p.vertices)]
    used = sorted({i for p in faces for i in p.vertices})
    remap = {old: new for new, old in enumerate(used)}
    coords = [world[i] + push(i) for i in used]
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
    obj = world_object(name, new_mesh, name)
    for bone in bone_names:
        obj.vertex_groups.new(name=bone)
    for old in used:
        for bone, weight in bone_weights(mesh.vertices[old]):
            obj.vertex_groups[bone].add([remap[old]], weight, "REPLACE")
    solid = obj.modifiers.new("Thickness", "SOLIDIFY")
    solid.thickness = thickness
    solid.offset = -1.0
    # Thickness must come before the skeleton deforms the shell.
    obj.modifiers.move(obj.modifiers.find("Thickness"), 0)
    print("SHELL", name, len(used), "verts", len(faces), "faces")
    return obj


def eroded(vert_set, rings):
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


def near_front(x, z, ids):
    near = sorted(ids, key=lambda i: (world[i].x - x) ** 2 + (world[i].z - z) ** 2)[:12]
    return min(world[i].y for i in near)


def near_back(x, z, ids):
    near = sorted(ids, key=lambda i: (world[i].x - x) ** 2 + (world[i].z - z) ** 2)[:12]
    return max(world[i].y for i in near)


pieces = list(keep)
pieces.append(make_shell("Hoodie", hoodie_set, hoodie_push, 6, 0.025))
pieces.append(make_shell("Trousers", trouser_set, trouser_push, 6, 0.025))

# --- Hood and kangaroo pocket ------------------------------------------------
torso_ids = [i for i in hoodie_set if not has(dominant[i], *ARM_WORDS)]
bm = bmesh.new()
hood_y = near_back(0.0, neck.z - 0.04, torso_ids) + 0.04
bmesh.ops.create_uvsphere(
    bm, u_segments=12, v_segments=8, radius=1.0,
    matrix=Matrix.Translation((0.0, hood_y, neck.z - 0.03))
    @ Matrix.Rotation(math.radians(-25), 4, "X")
    @ Matrix.Diagonal((0.14, 0.07, 0.12, 1.0)))
hood_mesh = bpy.data.meshes.new("Hood")
bm.to_mesh(hood_mesh)
bm.free()
pocket_z = hip_z + 0.1
bm = bmesh.new()
bmesh.ops.create_cube(
    bm, size=1.0,
    matrix=Matrix.Translation((0.0, near_front(0.0, pocket_z, torso_ids) - 0.037, pocket_z))
    @ Matrix.Diagonal((0.2, 0.012, 0.09, 1.0)))
pocket_mesh = bpy.data.meshes.new("Pocket")
bm.to_mesh(pocket_mesh)
bm.free()
for m in (hood_mesh, pocket_mesh):
    for p in m.polygons:
        p.use_smooth = True
pieces.append(world_object("Hood", hood_mesh, "Hoodie", rigid_bone="CC_Base_Spine02"))
pieces.append(world_object("Pocket", pocket_mesh, "Hoodie", rigid_bone="CC_Base_Waist"))

# --- Hair: scalp shell plus swept clumps --------------------------------------
pieces.append(make_shell("Hair", scalp_set, hair_push, 2, 0.012))
random.seed(4)
bm = bmesh.new()
for i in sorted(scalp_set)[::7]:
    p = world[i]
    t = (p.z - head_min) / head_h
    front = p.y < head_mid_y
    sweep = Vector((0.0, -0.9, -0.35)) if (front and t > 0.82) else Vector((0.0, 0.3, -0.8))
    direction = (normals[i] * 0.8 + sweep + Vector((random.uniform(-0.3, 0.3), random.uniform(-0.2, 0.2), 0.0))).normalized()
    length = random.uniform(0.04, 0.075)
    rot = Vector((0.0, 0.0, 1.0)).rotation_difference(direction).to_matrix().to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=5, radius1=random.uniform(0.024, 0.034), radius2=0.003, depth=length,
        matrix=Matrix.Translation(p + direction * (length * 0.35)) @ rot)
clumps = bpy.data.meshes.new("HairClumps")
bm.to_mesh(clumps)
bm.free()
pieces.append(world_object("HairClumps", clumps, "Hair", rigid_bone="CC_Base_Head"))

# --- Shoes: an upper hugging each foot on a wider, flat sole ------------------
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


for side in ("L", "R"):
    foot = "CC_Base_%s_Foot" % side
    ankle_z = bone_head(foot).z + 0.035
    pts = [world[i].copy() for i in dominant
           if dominant[i].startswith("CC_Base_%s_" % side) and has(dominant[i], "Foot", "Toe")
           and world[i].z < ankle_z]
    centre = sum(pts, Vector()) / len(pts)
    floor = min(p.z for p in pts)
    upper = []
    for p in pts:
        q = centre + (p - centre) * 1.12
        q.z = max(p.z + 0.012, floor + 0.02)
        upper.append(q)
    sole = []
    for p in pts:
        q = centre + (p - centre) * 1.2
        sole.append(Vector((q.x, q.y, floor)))
        sole.append(Vector((q.x, q.y, floor + 0.03)))
    pieces.append(world_object("Shoe_" + side, hull_mesh("Shoe_" + side, upper), "Shoes", rigid_bone=foot))
    pieces.append(world_object("Sole_" + side, hull_mesh("Sole_" + side, sole), "Sole", rigid_bone=foot))

# --- Remove skin hidden under clothes, so it cannot poke through -------------
hidden = eroded(hoodie_set, 2) | eroded(trouser_set, 2)
bm = bmesh.new()
bm.from_mesh(mesh)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(v.index in hidden for v in f.verts)], context="FACES")
bm.to_mesh(mesh)
bm.free()

# --- Export -------------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
for obj in pieces + [rig]:
    obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT_DIR, "skater.glb"),
                          use_selection=True, export_yup=True, export_apply=True)

# --- Preview renders ------------------------------------------------------------
scene = bpy.context.scene
cam_data = bpy.data.cameras.new("Cam")
cam_data.lens = 50
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "TEXTURE"
scene.display.shading.show_object_outline = True
scene.render.resolution_x = 600
scene.render.resolution_y = 900
head_centre = Vector((0.0, head_mid_y, head_min + head_h * 0.5))
for label, angle, dist, target, cam_z in (
        ("front", 28.0, 4.3, Vector((0.0, 0.0, 0.9)), 1.25),
        ("back", 152.0, 4.3, Vector((0.0, 0.0, 0.9)), 1.25),
        ("head", 22.0, 1.0, head_centre, head_centre.z + 0.05)):
    a = math.radians(angle)
    cam.location = Vector((math.sin(a) * dist, -math.cos(a) * dist, cam_z))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = os.path.join(OUT_DIR, "preview_%s.png" % label)
    bpy.ops.render.render(write_still=True)

os.makedirs(os.path.join(OUT_DIR, "source"), exist_ok=True)
open(os.path.join(OUT_DIR, "source", ".gdignore"), "w").close()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT_DIR, "source", "skater.blend"))
print("DONE")
