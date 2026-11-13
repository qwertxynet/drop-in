"""Builds the skater from Reallusion's free CC Toon base and exports it for Godot.

Run:  blender --background --python tools/make_skater_cc.py

Needs the "CC Character Base" folder (Reallusion, free account download) in the
project root. Writes assets/skater_cc/, which is git-ignored: Reallusion's
licence forbids redistributing the base or models built from it, so this
model must be built locally and never committed.

The T-shirt and trousers are draped with Blender's cloth simulation: each
starts as a shell around the body with extra fabric, pinned at the collar and
hems or the waistband, and falls into folds against the body and shoes. Vertices keep their link to the body
vertex they grew from, so they inherit its bone weights after draping.
The hair is a set of modelled locks that flow out from the crown.
"""
import math
import os
import random

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "CC Character Base", "FBX", "05_Toon Neutral_M")
OUT_DIR = os.path.join(ROOT, "assets", "skater_cc")
os.makedirs(OUT_DIR, exist_ok=True)

COLORS = {
    "Shirt": (0.9, 0.9, 0.88),
    "ShirtCollar": (0.8, 0.8, 0.78),
    "Trousers": (0.2, 0.21, 0.25),
    "Waistband": (0.14, 0.15, 0.18),
    "Shoes": (0.75, 0.08, 0.08),
    "Sole": (0.92, 0.92, 0.9),
    "Hair": (0.035, 0.035, 0.05),
}
TEXTURE_SIZE = 1024
DROP = ("EyeOcclusion", "TearLine", "Tongue", "Teeth")

# Cloth: how much bigger than the body the fabric wants to be, and sim length.
SHIRT_EXTRA = 0.06
TROUSER_EXTRA = 0.1
SIM_FRAMES = 50
HEM_BAND = 0.015      # shirt hems held level while draping
WAIST_BAND = 0.04     # trouser waistband held in place while draping
SLEEVE_LENGTH = 0.5   # short sleeves end this far from shoulder to elbow

random.seed(4)
bpy.ops.wm.read_factory_settings(use_empty=True)
fbx = [f for f in os.listdir(SOURCE) if f.lower().endswith(".fbx")][0]
bpy.ops.import_scene.fbx(filepath=os.path.join(SOURCE, fbx))
scene = bpy.context.scene

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
HAND_WORDS = ("Hand", "Index", "Mid", "Ring", "Pinky", "Thumb")

def along_upper_arm(p):
    """0 at the shoulder joint, 1 at the elbow, for the nearer arm."""
    side = "L" if p.x > 0 else "R"
    a = bone_head("CC_Base_%s_Upperarm" % side)
    b = bone_head("CC_Base_%s_Forearm" % side)
    return (p - a).dot(b - a) / (b - a).length_squared


shirt_set, trouser_set, head_set = set(), set(), set()
for v in mesh.vertices:
    d = dominant[v.index]
    z = world[v.index].z
    # Torso is everything between the hips and the neck except the hands, so
    # helper bones such as the chest ones are covered too.
    torso = hip_z - 0.05 < z < neck.z - 0.01 and not has(d, *HAND_WORDS, "Neck", "Head")
    sleeve = has(d, *ARM_WORDS) and along_upper_arm(world[v.index]) < SLEEVE_LENGTH
    if (torso and not has(d, *ARM_WORDS)) or sleeve or has(d, "Clavicle"):
        shirt_set.add(v.index)
    if has(d, *LEG_WORDS) or (has(d, "Pelvis", "Hip") and z < hip_z + 0.1):
        trouser_set.add(v.index)
    if d == "CC_Base_Head":
        head_set.add(v.index)

head_z = [world[i].z for i in head_set]
head_min, head_max = min(head_z), max(head_z)
head_h = head_max - head_min
head_mid_y = sum(world[i].y for i in head_set) / len(head_set)
head_centre = sum((world[i] for i in head_set), Vector()) / len(head_set)
eye_obj = next((o for o in keep if "Eye" in o.name and "Brow" not in o.name), None)
eye_top = max((eye_obj.matrix_world @ Vector(c)).z for c in eye_obj.bound_box) if eye_obj else head_min + head_h * 0.55



def near_front(x, z, ids, pts=None):
    pts = pts or world
    near = sorted(ids, key=lambda i: (pts[i].x - x) ** 2 + (pts[i].z - z) ** 2)[:12]
    return min(pts[i].y for i in near)


def near_back(x, z, ids):
    near = sorted(ids, key=lambda i: (world[i].x - x) ** 2 + (world[i].z - z) ** 2)[:12]
    return max(world[i].y for i in near)


# --- Object helpers ----------------------------------------------------------
def link(name, new_mesh):
    obj = bpy.data.objects.new(name, new_mesh)
    scene.collection.objects.link(obj)
    return obj


def attach(obj):
    """Parents to the rig without moving it, and deforms it with the skeleton."""
    obj.parent = rig
    obj.matrix_parent_inverse = rig.matrix_world.inverted()
    arm = obj.modifiers.new("Armature", "ARMATURE")
    arm.object = rig


def finish(obj, mat_names, rigid_bone=None, thickness=0.0):
    for name in mat_names:
        obj.data.materials.append(material(name))
    if rigid_bone:
        group = obj.vertex_groups.new(name=rigid_bone)
        group.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
    if thickness:
        solid = obj.modifiers.new("Thickness", "SOLIDIFY")
        solid.thickness = thickness
        solid.offset = -1.0
    attach(obj)
    return obj


def world_object(name, new_mesh, mat_name, rigid_bone=None):
    """An object whose vertex coordinates are already in world space."""
    return finish(link(name, new_mesh), [mat_name], rigid_bone)


def copy_body_weights(obj, used):
    """Gives each vertex the bone weights of the body vertex it grew from."""
    for bone in bone_names:
        obj.vertex_groups.new(name=bone)
    for k, old in enumerate(used):
        for bone, weight in bone_weights(mesh.vertices[old]):
            obj.vertex_groups[bone].add([k], weight, "REPLACE")


def shell_mesh(name, vert_set, push, smooth_iters):
    """A surface grown out from the body faces inside vert_set. Returns the
    mesh and, per new vertex, the body vertex it came from."""
    faces = [p for p in mesh.polygons if all(i in vert_set for i in p.vertices)]
    used = sorted({i for p in faces for i in p.vertices})
    remap = {old: new for new, old in enumerate(used)}
    new_mesh = bpy.data.meshes.new(name)
    new_mesh.from_pydata([world[i] + push(i) for i in used], [],
                         [[remap[i] for i in p.vertices] for p in faces])
    new_mesh.update()
    bm = bmesh.new()
    bm.from_mesh(new_mesh)
    for _ in range(smooth_iters):
        bmesh.ops.smooth_vert(bm, verts=bm.verts, factor=0.5, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bm.to_mesh(new_mesh)
    bm.free()
    for p in new_mesh.polygons:
        p.use_smooth = True
    return new_mesh, used


def boundary_verts(new_mesh):
    bm = bmesh.new()
    bm.from_mesh(new_mesh)
    out = {v.index for v in bm.verts if any(e.is_boundary for e in v.link_edges)}
    bm.free()
    return out


def world_copy(name, coords, faces):
    """A static world-space mesh, used as a collider."""
    m = bpy.data.meshes.new(name)
    m.from_pydata(coords, [], faces)
    m.update()
    return link(name, m)


def make_collider(obj, thickness):
    mod = obj.modifiers.new("Collision", "COLLISION")
    obj.collision.thickness_outer = thickness
    obj.collision.cloth_friction = 8.0
    return mod


def drape(obj, pin_group, extra, frames):
    """Runs a cloth simulation on obj and freezes the result into its mesh."""
    cloth = obj.modifiers.new("Cloth", "CLOTH")
    s = cloth.settings
    s.quality = 8
    s.mass = 0.25
    s.air_damping = 1.0
    s.tension_stiffness = 15.0
    s.compression_stiffness = 15.0
    s.shear_stiffness = 6.0
    s.bending_stiffness = 1.2      # heavy jersey: a few broad folds, not crumples
    s.vertex_group_mass = pin_group
    s.pin_stiffness = 1.0
    s.shrink_min = -extra          # negative shrink = fabric larger than the shell
    c = cloth.collision_settings
    c.use_collision = True
    c.distance_min = 0.006
    c.use_self_collision = True
    c.self_distance_min = 0.004
    c.collision_quality = 3
    cloth.point_cache.frame_start = 1
    cloth.point_cache.frame_end = frames
    scene.frame_start = 1
    scene.frame_end = frames
    for f in range(1, frames + 1):
        scene.frame_set(f)
    dg = bpy.context.evaluated_depsgraph_get()
    frozen = bpy.data.meshes.new_from_object(obj.evaluated_get(dg), depsgraph=dg)
    obj.modifiers.remove(cloth)
    old = obj.data
    obj.data = frozen
    bpy.data.meshes.remove(old)
    for p in obj.data.polygons:
        p.use_smooth = True
    scene.frame_set(1)


# Collider: a static copy of the whole body in world space.
body_collider = world_copy("BodyCollider", world, [list(p.vertices) for p in mesh.polygons])
make_collider(body_collider, 0.008)

pieces = list(keep)

# --- Shoes: an upper hugging each foot on a wider, flat sole ------------------
# Built before the trousers so the trouser legs can settle on them.
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


shoe_colliders = []
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
    upper_mesh = hull_mesh("Shoe_" + side, upper)
    sole_mesh = hull_mesh("Sole_" + side, sole)
    for m in (upper_mesh, sole_mesh):
        c = world_copy("ShoeCollider", [v.co.copy() for v in m.vertices], [list(p.vertices) for p in m.polygons])
        make_collider(c, 0.004)
        shoe_colliders.append(c)
    pieces.append(world_object("Shoe_" + side, upper_mesh, "Shoes", rigid_bone=foot))
    pieces.append(world_object("Sole_" + side, sole_mesh, "Sole", rigid_bone=foot))

# Ground, so trouser hems rest on the floor rather than falling through it.
ground = world_copy("Ground", [Vector((-1, -1, 0)), Vector((1, -1, 0)), Vector((1, 1, 0)), Vector((-1, 1, 0))], [[0, 1, 2, 3]])
make_collider(ground, 0.002)


# --- Trousers -------------------------------------------------------------------
def trouser_push(i):
    """Snug at the waistband, then a straight leg that widens to the ankle."""
    p = world[i]
    if p.z > hip_z + 0.04:
        return normals[i] * 0.012
    n = normals[i]
    flat = Vector((n.x, n.y, 0.0))
    direction = flat.normalized() if flat.length > 0.2 else n
    drop = max(0.0, min(1.0, (hip_z - p.z) / hip_z))
    return direction * (0.02 + 0.03 * drop)


trouser_mesh, trouser_used = shell_mesh("Trousers", trouser_set, trouser_push, 5)
trousers = link("Trousers", trouser_mesh)
top_z = max(v.co.z for v in trouser_mesh.vertices)
waist = {v.index for v in trouser_mesh.vertices if v.co.z > top_z - WAIST_BAND}
pins = trousers.vertex_groups.new(name="Pin")
pins.add(sorted(waist), 1.0, "REPLACE")
print("TROUSERS", len(trouser_mesh.vertices), "verts", len(waist), "pinned")
drape(trousers, "Pin", TROUSER_EXTRA, SIM_FRAMES)
trousers.vertex_groups.remove(trousers.vertex_groups["Pin"])
copy_body_weights(trousers, trouser_used)
trousers.data.materials.append(material("Trousers"))
trousers.data.materials.append(material("Waistband"))
for p in trousers.data.polygons:
    if all(i in waist for i in p.vertices):
        p.material_index = 1
solid = trousers.modifiers.new("Thickness", "SOLIDIFY")
solid.thickness = 0.008
solid.offset = -1.0
# The draped trousers are a collider for the shirt, which hangs over them.
trouser_collider = world_copy("TrouserCollider", [v.co.copy() for v in trousers.data.vertices],
                              [list(p.vertices) for p in trousers.data.polygons])
make_collider(trouser_collider, 0.006)
attach(trousers)
pieces.append(trousers)

# --- T-shirt -------------------------------------------------------------------
def shirt_push(i):
    """Close to the body at the pinned collar and hems, roomier elsewhere."""
    p = world[i]
    if p.z > neck.z - 0.05:
        return normals[i] * 0.01      # crew neck
    if p.z < hip_z + 0.14:
        return normals[i] * 0.045     # starts outside the trouser waistband
    return normals[i] * 0.016


shirt_mesh, shirt_used = shell_mesh("Shirt", shirt_set, shirt_push, 4)
shirt = link("Shirt", shirt_mesh)
edge = boundary_verts(shirt_mesh)
collar_pts = {k for k in edge if shirt_mesh.vertices[k].co.z > neck.z - 0.12}
# Pin the collar edge plus a narrow band at the sleeve and body hems, so the
# hems stay level and the spare fabric folds above them.
hem_from = [shirt_mesh.vertices[k].co.copy() for k in edge if k not in collar_pts]
hem_verts = {v.index for v in shirt_mesh.vertices
             if min((v.co - q).length for q in hem_from) < HEM_BAND}
collar_band = {v.index for v in shirt_mesh.vertices
               if min((v.co - shirt_mesh.vertices[k].co).length for k in collar_pts) < 0.015}
pins = shirt.vertex_groups.new(name="Pin")
pins.add(sorted(collar_pts | hem_verts), 1.0, "REPLACE")
print("SHIRT", len(shirt_mesh.vertices), "verts", len(collar_pts | hem_verts), "pinned")
drape(shirt, "Pin", SHIRT_EXTRA, SIM_FRAMES)
shirt.vertex_groups.remove(shirt.vertex_groups["Pin"])
copy_body_weights(shirt, shirt_used)
shirt.data.materials.append(material("Shirt"))
shirt.data.materials.append(material("ShirtCollar"))
for p in shirt.data.polygons:
    if all(i in collar_band for i in p.vertices):
        p.material_index = 1
solid = shirt.modifiers.new("Thickness", "SOLIDIFY")
solid.thickness = 0.006
solid.offset = -1.0
attach(shirt)
pieces.append(shirt)


# --- Hair: anime locks flowing out from the crown -----------------------------
head_faces = [list(p.vertices) for p in mesh.polygons if any(i in head_set for i in p.vertices)]
head_bvh = BVHTree.FromPolygons(world, head_faces)
scalp_ids = [i for i in head_set
             if (world[i].z - head_min) / head_h > 0.62
             or (world[i].y > head_mid_y + 0.02 and (world[i].z - head_min) / head_h > 0.3)]
crown = max((world[i] for i in scalp_ids), key=lambda q: q.z + 0.5 * (q.y - head_mid_y))

# Spread roots over the scalp: farthest-point sampling keeps them even.
roots = [min(scalp_ids, key=lambda i: (world[i] - crown).length)]
while len(roots) < 60:
    best = max(scalp_ids, key=lambda i: min((world[i] - world[r]).length for r in roots))
    if min((world[best] - world[r]).length for r in roots) < 0.02:
        break
    roots.append(best)


def lock(bm, root):
    p = world[root]
    n = normals[root]
    away = p - crown
    away -= n * away.dot(n)
    if away.length < 0.01:
        away = Vector((random.uniform(-1, 1), random.uniform(-1, 1), 0.0))
    direction = away.normalized()
    front = p.y < head_mid_y - 0.01
    side = abs(p.x) > 0.05 and not front
    length = 0.14 if front else (0.13 if side else 0.12)
    length *= random.uniform(0.85, 1.15)
    width = random.uniform(0.05, 0.065)
    steps = 10
    pts = [p + n * 0.002]
    for k in range(1, steps + 1):
        t = k / steps
        direction = (direction + Vector((0.0, 0.0, -0.25 - 0.3 * t))).normalized()
        q = pts[-1] + direction * (length / steps)
        loc, nrm, _, _ = head_bvh.find_nearest(q)
        margin = 0.004 + 0.016 * t
        if loc is not None and (q - loc).dot(nrm) < margin:
            q = loc + nrm * margin
        if front:
            q.z = max(q.z, eye_top + 0.012)       # fringe stops above the eyes
        elif q.y > head_mid_y:
            q.z = max(q.z, neck.z + 0.03)         # clear of the hood at the back
        pts.append(q)
    # Flick the tip outward a little.
    pts[-1] += (pts[-1] - head_centre).normalized() * 0.01
    rings = []
    for k, q in enumerate(pts):
        t = k / steps
        tangent = (pts[min(k + 1, steps)] - pts[max(k - 1, 0)]).normalized()
        out = (q - head_centre)
        out = (out - tangent * out.dot(tangent)).normalized()
        across = tangent.cross(out).normalized()
        # Flat, wide locks that keep their width and only taper near the tip,
        # so neighbours overlap like layered anime hair.
        w = width * (1.0 - t ** 1.8) * 0.5
        h = (0.01 * (1.0 - t ** 1.5) + 0.002) * 0.5
        if k == steps:
            rings.append([bm.verts.new(q)])
        else:
            rings.append([bm.verts.new(q + across * w), bm.verts.new(q + out * h),
                          bm.verts.new(q - across * w), bm.verts.new(q - out * h)])
    bm.faces.new(list(reversed(rings[0])))
    for a, b in zip(rings, rings[1:]):
        for j in range(4):
            if len(b) == 1:
                bm.faces.new((a[j], a[(j + 1) % 4], b[0]))
            else:
                bm.faces.new((a[j], a[(j + 1) % 4], b[(j + 1) % 4], b[j]))


bm = bmesh.new()
for r in roots:
    lock(bm, r)
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
locks = bpy.data.meshes.new("HairLocks")
bm.to_mesh(locks)
bm.free()
for p in locks.polygons:
    p.use_smooth = True
pieces.append(world_object("HairLocks", locks, "Hair", rigid_bone="CC_Base_Head"))
print("HAIR", len(roots), "locks")

# A thin dark cap under the locks so no bald patches show between them.
cap_mesh, _ = shell_mesh("HairCap", set(scalp_ids), lambda i: normals[i] * 0.002, 1)
pieces.append(world_object("HairCap", cap_mesh, "Hair", rigid_bone="CC_Base_Head"))


# --- Remove skin hidden under clothes, so it cannot poke through -------------
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


hidden = eroded(shirt_set, 2) | eroded(trouser_set, 2)
bm = bmesh.new()
bm.from_mesh(mesh)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(v.index in hidden for v in f.verts)], context="FACES")
bm.to_mesh(mesh)
bm.free()

for helper in [body_collider, ground, trouser_collider] + shoe_colliders:
    bpy.data.objects.remove(helper)

# --- Export -------------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
for obj in pieces + [rig]:
    obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT_DIR, "skater.glb"),
                          use_selection=True, export_yup=True, export_apply=True)

# --- Preview renders ------------------------------------------------------------
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
look = Vector((0.0, head_mid_y, head_min + head_h * 0.55))
for label, angle, dist, target, cam_z in (
        ("front", 28.0, 4.3, Vector((0.0, 0.0, 0.9)), 1.25),
        ("back", 152.0, 4.3, Vector((0.0, 0.0, 0.9)), 1.25),
        ("head", 22.0, 1.0, look, look.z + 0.05),
        ("head_back", 150.0, 1.1, look - Vector((0.0, 0.0, 0.08)), look.z + 0.1)):
    a = math.radians(angle)
    cam.location = Vector((math.sin(a) * dist, -math.cos(a) * dist, cam_z))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = os.path.join(OUT_DIR, "preview_%s.png" % label)
    bpy.ops.render.render(write_still=True)

os.makedirs(os.path.join(OUT_DIR, "source"), exist_ok=True)
open(os.path.join(OUT_DIR, "source", ".gdignore"), "w").close()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT_DIR, "source", "skater.blend"))
print("DONE")
