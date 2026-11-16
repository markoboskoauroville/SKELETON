"""Classic artist's wooden mannequin with an armature on Apple Vision's 17 3D joints.

Rebuild the saved file (headless, never the GUI):
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P blender/mannequin.py
It writes blender/mannequin.blend: the mannequin (rigid wooden parts, each parented to one bone),
the armature "Skeleton", a light grey cyclorama, three soft area lights and a camera.
render_mannequin.py opens that file and imports this module for the bone rules (rest frames).

Coordinates: Blender Z up, the mannequin faces -Y, its LEFT is +X. Rest pose = T-pose, 1.75 m tall,
soles on Z = 0. Units are metres; render_mannequin.py scales the armature object to the recording.
"""
import math
import os
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
REST_HEIGHT = 1.75
ANKLE_HEIGHT = 0.08          # ankle joint above the sole in the rest pose
HAND_LEN = 0.18
FOOT_LEN = 0.22

# Apple VNHumanBodyPose3DObservation joint names -> rest position (T-pose, Blender coords)
REST_JOINTS = {
    "root":           (0.00, 0.0, 0.98),
    "spine":          (0.00, 0.0, 1.18),
    "centerShoulder": (0.00, 0.0, 1.45),
    "centerHead":     (0.00, 0.0, 1.60),
    "topHead":        (0.00, 0.0, 1.75),
    "leftShoulder":   (0.19, 0.0, 1.43),
    "leftElbow":      (0.47, 0.0, 1.43),
    "leftWrist":      (0.72, 0.0, 1.43),
    "rightShoulder":  (-0.19, 0.0, 1.43),
    "rightElbow":     (-0.47, 0.0, 1.43),
    "rightWrist":     (-0.72, 0.0, 1.43),
    "leftHip":        (0.10, 0.0, 0.95),
    "leftKnee":       (0.10, 0.0, 0.52),
    "leftAnkle":      (0.10, 0.0, ANKLE_HEIGHT),
    "rightHip":       (-0.10, 0.0, 0.95),
    "rightKnee":      (-0.10, 0.0, 0.52),
    "rightAnkle":     (-0.10, 0.0, ANKLE_HEIGHT),
}
JOINTS = list(REST_JOINTS)

# (bone, head joint, tail joint or None, parent, rule)
#   rule "torso": Y from head to tail joint, X along a left-right line (hips or shoulders)
#   rule "swing": Y aimed at the tail joint by the smallest rotation from the parent-carried rest
#   rule "hand":  rigid continuation of the forearm
#   rule "foot":  flat on the floor, turned toward where the knee and pelvis face
BONES = [
    ("pelvis", "root", "spine", None, "torso"),
    ("chest", "spine", "centerShoulder", "pelvis", "torso"),
    ("neck", "centerShoulder", "centerHead", "chest", "torso"),
    ("head", "centerHead", "topHead", "neck", "torso"),
]
for S, s in (("L", "left"), ("R", "right")):
    BONES += [
        ("clavicle." + S, "centerShoulder", s + "Shoulder", "chest", "swing"),
        ("upperarm." + S, s + "Shoulder", s + "Elbow", "clavicle." + S, "swing"),
        ("forearm." + S, s + "Elbow", s + "Wrist", "upperarm." + S, "swing"),
        ("hand." + S, s + "Wrist", None, "forearm." + S, "hand"),
        ("hip." + S, "root", s + "Hip", "pelvis", "swing"),
        ("thigh." + S, s + "Hip", s + "Knee", "hip." + S, "swing"),
        ("shin." + S, s + "Knee", s + "Ankle", "thigh." + S, "swing"),
        ("foot." + S, s + "Ankle", None, "shin." + S, "foot"),
    ]

TORSO_XREF = {"pelvis": ("rightHip", "leftHip"), "chest": ("rightShoulder", "leftShoulder"),
              "neck": ("rightShoulder", "leftShoulder"), "head": ("rightShoulder", "leftShoulder")}


def frame_from(y, xref, fallback=Vector((0, -1, 0))):
    """3x3 rotation whose Y axis is y and X axis is xref made orthogonal to y."""
    y = y.normalized()
    x = xref - y * xref.dot(y)
    if x.length < 1e-4:
        x = fallback - y * fallback.dot(y)
    x.normalize()
    z = x.cross(y)
    return Matrix((x, y, z)).transposed()   # columns x, y, z


def rest_frames():
    """Armature-space rest matrices (4x4, head as translation) and lengths for every bone."""
    J = {k: Vector(v) for k, v in REST_JOINTS.items()}
    out = {}
    for name, hj, tj, parent, rule in BONES:
        head = J[hj]
        if rule == "torso":
            a, b = TORSO_XREF[name]
            R = frame_from(J[tj] - head, J[b] - J[a])
            length = (J[tj] - head).length
        elif rule == "swing":
            R = frame_from(J[tj] - head, Vector((0, -1, 0)), Vector((0, 0, 1)))
            length = (J[tj] - head).length
        elif rule == "hand":
            R = out[parent][0].to_3x3()
            length = HAND_LEN
        else:  # foot: points forward (-Y), Z axis up
            R = frame_from(Vector((0, -1, 0)), Vector((1, 0, 0)))
            length = FOOT_LEN
        M = R.to_4x4()
        M.translation = head
        out[name] = (M, length)
    return out


# ---------------------------------------------------------------- geometry helpers

def lathe(profile, segs=32):
    """Mesh of revolution around local Z. profile: list of (z, r), r = 0 at the closed ends."""
    bm = bmesh.new()
    rings = []
    for z, r in profile:
        if r <= 1e-6:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / segs),
                                        r * math.sin(2 * math.pi * i / segs), z)) for i in range(segs)])
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            for i in range(segs):
                bm.faces.new((a[0], b[(i + 1) % segs], b[i]))
        elif len(b) == 1:
            for i in range(segs):
                bm.faces.new((a[i], a[(i + 1) % segs], b[0]))
        else:
            for i in range(segs):
                bm.faces.new((a[i], a[(i + 1) % segs], b[(i + 1) % segs], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def capsule_profile(length, r0, r1, bulge=0.10, n=14, cap=8):
    """Tapered limb segment: rounded ends, slight belly, along +Z from 0 to length."""
    prof = []
    for i in range(cap + 1):                       # bottom cap (quarter circle of r0)
        a = -math.pi / 2 + (math.pi / 2) * i / cap
        prof.append((r0 + r0 * math.sin(a), r0 * math.cos(a)))
    z0, z1 = r0, length - r1
    for i in range(1, n):
        t = i / n
        r = (r0 + (r1 - r0) * t) * (1 + bulge * math.sin(math.pi * t))
        prof.append((z0 + (z1 - z0) * t, r))
    for i in range(cap + 1):                       # top cap
        a = (math.pi / 2) * i / cap
        prof.append((z1 + r1 * math.sin(a), r1 * math.cos(a)))
    prof[0] = (prof[0][0], 0.0)
    prof[-1] = (prof[-1][0], 0.0)
    return prof


def ellipsoid_profile(n=16):
    return [(-math.cos(math.pi * i / n), math.sin(math.pi * i / n)) for i in range(n + 1)]


def egg_profile(n=18, top=1.0, bottom=0.75):
    """Unit-height egg: z from 0 to 1, wider toward `top` end when top > bottom."""
    prof = []
    for i in range(n + 1):
        t = i / n
        z = (1 - math.cos(math.pi * t)) / 2
        r = math.sin(math.pi * t) * (bottom + (top - bottom) * z) / 2
        prof.append((z, r))
    return prof


def make_object(name, bm, mat, coll, matrix, scale=(1, 1, 1), flatten_below=None):
    for v in bm.verts:
        v.co = Vector((v.co.x * scale[0], v.co.y * scale[1], v.co.z * scale[2]))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    ob.matrix_world = matrix
    coll.objects.link(ob)
    if flatten_below is not None:     # in world Z: squash everything under it onto it (sole)
        mw = ob.matrix_world
        inv = mw.inverted()
        for v in me.vertices:
            w = mw @ v.co
            if w.z < flatten_below:
                w.z = flatten_below
                v.co = inv @ w
    return ob


def aim_matrix(p0, p1, side=Vector((1, 0, 0))):
    """Object matrix at p0 whose local +Z points to p1."""
    z = (p1 - p0).normalized()
    x = side - z * side.dot(z)
    if x.length < 1e-4:
        x = Vector((0, 1, 0)) - z * z.y
    x.normalize()
    y = z.cross(x)
    M = Matrix((x, y, z)).transposed().to_4x4()
    M.translation = p0
    return M


# ---------------------------------------------------------------- materials

def wood_material():
    m = bpy.data.materials.new("Wood")
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Location"].default_value = (0.37, 0.23, 0.0)
    mp.inputs["Scale"].default_value = (1.0, 1.0, 0.25)
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 6.0
    noise.inputs["Detail"].default_value = 4.0
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.wave_type = "RINGS"
    wave.rings_direction = "Z"
    wave.inputs["Scale"].default_value = 5.0
    wave.inputs["Distortion"].default_value = 9.0
    wave.inputs["Detail"].default_value = 3.0
    wave.inputs["Detail Scale"].default_value = 1.5
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.50, 0.29, 0.13, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.74, 0.50, 0.28, 1)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.08
    bump.inputs["Distance"].default_value = 0.002
    L = nt.links
    L.new(tc.outputs["Object"], mp.inputs["Vector"])
    L.new(mp.outputs["Vector"], wave.inputs["Vector"])
    L.new(wave.outputs["Fac"], ramp.inputs["Fac"])
    L.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    L.new(wave.outputs["Fac"], bump.inputs["Height"])
    L.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Roughness"].default_value = 0.42
    bsdf.inputs["Coat Weight"].default_value = 0.15
    bsdf.inputs["Coat Roughness"].default_value = 0.35
    L.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    m.diffuse_color = (0.80, 0.60, 0.38, 1)
    return m


def plain_material(name, rgb, rough=0.8):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*rgb, 1)
    return m


# ---------------------------------------------------------------- build

def parent_to_bone(ob, arm, bone):
    mw = ob.matrix_world.copy()
    ob.parent = arm
    ob.parent_type = "BONE"
    ob.parent_bone = bone
    bpy.context.view_layer.update()
    ob.matrix_world = mw


def build_armature(coll):
    data = bpy.data.armatures.new("Skeleton")
    data.display_type = "OCTAHEDRAL"
    arm = bpy.data.objects.new("Skeleton", data)
    coll.objects.link(arm)
    arm.show_in_front = True
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    frames = rest_frames()
    for name, hj, tj, parent, rule in BONES:
        M, length = frames[name]
        eb = data.edit_bones.new(name)
        eb.head = M.translation
        eb.tail = M.translation + M.col[1].to_3d() * length
        eb.align_roll(M.col[2].to_3d())
        if parent:
            eb.parent = data.edit_bones[parent]
            eb.use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
    return arm


def build_mannequin(coll, wood, arm):
    J = {k: Vector(v) for k, v in REST_JOINTS.items()}
    parts = []

    def part(name, bm, M, bone, scale=(1, 1, 1), flatten_below=None):
        ob = make_object(name, bm, wood, coll, M, scale, flatten_below)
        parent_to_bone(ob, arm, bone)
        parts.append(ob)
        return ob

    def ball(name, center, r, bone):
        M = Matrix.Translation(center)
        return part(name, lathe([(z * r, rr * r) for z, rr in ellipsoid_profile()], 24), M, bone)

    def limb(name, a, b, r0, r1, gap0, gap1, bone, bulge=0.10, side=Vector((0, -1, 0))):
        d = (b - a).normalized()
        p0, p1 = a + d * gap0, b - d * gap1
        prof = capsule_profile((p1 - p0).length, r0, r1, bulge)
        return part(name, lathe(prof), aim_matrix(p0, p1, side), bone)

    # pelvis block: wide, shallow, slightly narrower at the bottom
    part("Pelvis", lathe(egg_profile(top=1.0, bottom=0.80)),
         Matrix.Translation((0, 0, 0.86)), "pelvis", scale=(0.33, 0.22, 0.21))
    # waist joint
    part("Waist", lathe([(z * 0.07, r * 0.07) for z, r in ellipsoid_profile()], 24),
         Matrix.Translation((0, 0, 1.11)), "chest", scale=(1.55, 1.05, 1.0))
    # chest block: egg, broad at the shoulders
    part("Chest", lathe(egg_profile(top=1.0, bottom=0.55)),
         Matrix.Translation((0, 0, 1.13)), "chest", scale=(0.40, 0.22, 0.35))
    # neck and head
    part("Neck", lathe(capsule_profile(0.13, 0.042, 0.038, 0.0)),
         Matrix.Translation((0, 0, 1.44)), "neck")
    part("Head", lathe(egg_profile(n=20, top=1.0, bottom=0.78)),
         Matrix.Translation((0, -0.008, 1.515)), "head", scale=(0.17, 0.20, 0.24))

    for S, s, sx in (("L", "left", 1), ("R", "right", -1)):
        sh, el, wr = J[s + "Shoulder"], J[s + "Elbow"], J[s + "Wrist"]
        hp, kn, an = J[s + "Hip"], J[s + "Knee"], J[s + "Ankle"]
        ball("Shoulder." + S, sh, 0.052, "upperarm." + S)
        limb("UpperArm." + S, sh, el, 0.044, 0.033, 0.040, 0.032, "upperarm." + S)
        ball("Elbow." + S, el, 0.036, "forearm." + S)
        limb("Forearm." + S, el, wr, 0.034, 0.025, 0.030, 0.022, "forearm." + S)
        ball("Wrist." + S, wr, 0.027, "hand." + S)
        # mitten hand: flat paddle (thin in Z, palm down in the T-pose) and a thumb toward the front
        d = Vector((sx, 0, 0))
        hand_prof = [(z, r) for z, r in egg_profile(n=16, top=0.92, bottom=1.0)]
        part("Hand." + S, lathe(hand_prof), aim_matrix(wr + d * 0.018, wr + d * 0.2, Vector((0, -1, 0))),
             "hand." + S, scale=(0.105, 0.048, 0.17))
        tb = wr + d * 0.045 + Vector((0, -0.035, -0.006))
        part("Thumb." + S, lathe(capsule_profile(0.07, 0.016, 0.012, 0.05)),
             aim_matrix(tb, tb + Vector((sx * 0.7, -0.7, 0)), Vector((0, 0, 1))), "hand." + S)
        ball("Hip." + S, hp, 0.052, "thigh." + S)
        limb("Thigh." + S, hp, kn, 0.068, 0.047, 0.045, 0.040, "thigh." + S, bulge=0.12)
        ball("Knee." + S, kn, 0.050, "shin." + S)
        limb("Shin." + S, kn, an, 0.048, 0.031, 0.040, 0.030, "shin." + S, bulge=0.14)
        ball("Ankle." + S, an, 0.036, "foot." + S)
        # foot: long rounded wedge, heel behind the ankle, flat sole on the floor
        heel = an + Vector((0, 0.06, -0.05))
        toe = an + Vector((0, -0.20, -0.055))
        part("Foot." + S, lathe(capsule_profile((toe - heel).length, 0.040, 0.034, 0.25)),
             aim_matrix(heel, toe, Vector((1, 0, 0))), "foot." + S, scale=(1.15, 0.85, 1.0),
             flatten_below=0.0)
    return parts


def build_studio(coll):
    grey = plain_material("Studio Grey", (0.50, 0.50, 0.50), 0.9)
    # cyclorama: floor from y=-14 to y=2.5, quarter circle (r=2) up to a wall to z=8
    prof = []
    for i in range(8):
        prof.append((-14 + i * (16.5 / 8), 0.0))
    for i in range(17):
        a = (math.pi / 2) * i / 16
        prof.append((2.5 + 2.0 * math.sin(a), 2.0 - 2.0 * math.cos(a)))
    for i in range(1, 6):
        prof.append((4.5, 2.0 + i * 1.2))
    bm = bmesh.new()
    W = 12.0
    cols = 12
    grid = []
    for y, z in prof:
        grid.append([bm.verts.new((-W + 2 * W * c / cols, y, z)) for c in range(cols + 1)])
    for a, b in zip(grid, grid[1:]):
        for c in range(cols):
            bm.faces.new((a[c], a[c + 1], b[c + 1], b[c]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("Cyclorama")
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        if p.normal.z < 0 and p.center.z < 0.01:
            pass
        p.use_smooth = True
    me.materials.append(grey)
    cyc = bpy.data.objects.new("Cyclorama", me)
    coll.objects.link(cyc)
    # make sure the normals point up / toward the subject
    if me.polygons[0].normal.z < 0:
        bm = bmesh.new(); bm.from_mesh(me)
        bmesh.ops.reverse_faces(bm, faces=bm.faces); bm.to_mesh(me); bm.free()

    def area(name, loc, target, size, power, rgb=(1, 1, 1)):
        ld = bpy.data.lights.new(name, "AREA")
        ld.shape = "DISK"
        ld.size = size
        ld.energy = power
        ld.color = rgb
        ob = bpy.data.objects.new(name, ld)
        ob.location = loc
        direction = Vector(target) - Vector(loc)
        ob.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        coll.objects.link(ob)
        return ob

    area("Key", (-3.0, -4.0, 4.0), (0, 0, 1.0), 3.0, 850, (1.0, 0.97, 0.92))
    area("Fill", (4.0, -3.5, 2.2), (0, 0, 1.0), 4.0, 280, (0.92, 0.95, 1.0))
    area("Rim", (1.5, 3.0, 4.0), (0, 0, 1.3), 2.0, 600)

    cam_data = bpy.data.cameras.new("Camera")
    cam_data.lens = 50
    cam_data.sensor_width = 36
    cam = bpy.data.objects.new("Camera", cam_data)
    cam.location = (0, -6.2, 1.4)
    cam.rotation_euler = (math.radians(86), 0, 0)
    coll.objects.link(cam)
    return cam


def setup_render(scene):
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = 16
    scene.eevee.use_shadows = True
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    world = scene.world or bpy.data.worlds.new("World")
    scene.world = world
    bg = world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs["Color"].default_value = (0.55, 0.55, 0.56, 1)
        bg.inputs["Strength"].default_value = 0.25
    try:
        scene.view_settings.view_transform = "AgX"
        scene.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass


def build(path=None):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.name = "Mannequin"
    coll = scene.collection
    rig = bpy.data.collections.new("Mannequin")
    coll.children.link(rig)
    studio = bpy.data.collections.new("Studio")
    coll.children.link(studio)
    wood = wood_material()
    arm = build_armature(rig)
    build_mannequin(rig, wood, arm)
    cam = build_studio(studio)
    scene.camera = cam
    setup_render(scene)
    if path:
        bpy.context.preferences.filepaths.save_version = 0   # no .blend1 backup
        bpy.ops.wm.save_as_mainfile(filepath=path, compress=True)
    return arm


if __name__ == "__main__":
    out = os.path.join(HERE, "mannequin.blend")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if argv:
        out = os.path.abspath(argv[0])
    build(out)
    print("DONE", out)
