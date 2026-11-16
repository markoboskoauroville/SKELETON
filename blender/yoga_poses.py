"""Still renders of the wooden mannequin in the Wyoga poses (wyoga.app missions + its six-step Sun Salutation).

    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P blender/yoga_poses.py -- \
        --out DIR [--only id,id] [--size 2048] [--samples 128] [--json data/poses.json]

Each pose is built in 3D from the mannequin's own bone lengths (Blender coords: Z up, the body faces -Y, its left is +X):
torso directions, two-bone IK for bent limbs, explicit hand and foot frames (palms flat, toes tucked, tops of feet down).
Poses with hands and feet on the floor solve one angle by bisection until both touch the floor; then the lowest point of
the wood is put on the floor. Views: front + 3/4 for standing poses, side + 3/4 for floor poses. No text on the images:
names are in the file names. With --json, the 2D keypoints of the new poses are appended to the app's poses.json
(ids not already there), projected from the pose's main view.
"""
import argparse
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mannequin as MQ  # noqa: E402
import render_mannequin as RM  # noqa: E402

V = Vector
UA, FA, TH, SH = 0.28, 0.25, 0.43, 0.44     # mannequin limb lengths (rest units = metres at 1.75 m)
PEL, CHEST, NECK, HEAD = 0.20, 0.27, 0.15, 0.15


def n(*a):
    return V(a).normalized()


def deg(a):
    return math.radians(a)


def ik(a, c, l1, l2, pole):
    """Middle joint of a two-bone chain from a to c, bending toward pole."""
    d = c - a
    dist = min(d.length, l1 + l2 - 1e-4)
    dn = d.normalized()
    x = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
    h = math.sqrt(max(0.0, l1 * l1 - x * x))
    p = pole - dn * pole.dot(dn)
    p.normalize()
    return a + dn * x + p * h


def torso(root, pel, chest, neck, head, left=V((1, 0, 0))):
    """Centre joints plus shoulders and hips from segment directions."""
    J = {"root": root.copy()}
    J["spine"] = root + pel.normalized() * PEL
    J["centerShoulder"] = J["spine"] + chest.normalized() * CHEST
    J["centerHead"] = J["centerShoulder"] + neck.normalized() * NECK
    J["topHead"] = J["centerHead"] + head.normalized() * HEAD
    cx = MQ.frame_from(chest, left)
    px = MQ.frame_from(pel, left)
    for s, sg in (("left", 1), ("right", -1)):
        J[s + "Shoulder"] = J["centerShoulder"] + cx @ V((sg * 0.19, -0.02, 0))
        J[s + "Hip"] = root + px @ V((sg * 0.10, -0.03, 0))
    return J


def limb(J, s, upper, lower, arm=True):
    a, b, c = (("Shoulder", "Elbow", "Wrist") if arm else ("Hip", "Knee", "Ankle"))
    l1, l2 = (UA, FA) if arm else (TH, SH)
    J[s + b] = J[s + a] + upper.normalized() * l1
    J[s + c] = J[s + b] + lower.normalized() * l2


def limb_ik(J, s, target, pole, arm=True):
    a, b, c = (("Shoulder", "Elbow", "Wrist") if arm else ("Hip", "Knee", "Ankle"))
    l1, l2 = (UA, FA) if arm else (TH, SH)
    J[s + b] = ik(J[s + a], target, l1, l2, pole)
    J[s + c] = J[s + b] + (target - J[s + b]).normalized() * l2


FLAT_HAND = {"L": (n(0, -1, 0), n(0, 0, -1)), "R": (n(0, -1, 0), n(0, 0, -1))}   # fingers forward, palm down
FLAT_FOOT = {"L": (n(0, -1, 0), n(0, 0, -1)), "R": (n(0, -1, 0), n(0, 0, -1))}   # toes forward, sole down


# ------------------------------------------------------------------ the poses
# Each returns (J, hands, feet): hands/feet = {"L": (direction of fingers/toes, palm/sole normal)}

def upward_salute(_=None):
    J = torso(V((0, 0, 0.98)), n(0, 0, 1), n(0, 0.04, 1), n(0, 0.10, 1), n(0, 0.30, 1))
    for s, sg in (("left", 1), ("right", -1)):
        limb(J, s, n(sg * 0.07, 0.03, 1), n(sg * 0.05, 0.03, 1))
        limb(J, s, n(0, 0, -1), n(0, 0, -1), arm=False)
    hands = {"L": (n(0.03, 0.03, 1), n(-1, 0, 0)), "R": (n(-0.03, 0.03, 1), n(1, 0, 0))}  # palms face each other
    return J, hands, FLAT_FOOT


def down_dog(b):
    a = deg(46)                                   # arms + back line, below horizontal toward the hands
    d1 = V((0, -math.cos(a), -math.sin(a)))
    J = torso(V((0, 0, 1.2)), d1, d1, d1, d1)     # head between the arms, neck long
    d2 = V((0, math.cos(b), -math.sin(b)))
    for s in ("left", "right"):
        limb(J, s, d1, d1)
        limb(J, s, d2, d2, arm=False)
    return J, FLAT_HAND, FLAT_FOOT                # heels reaching for the floor


def warrior2(_=None):
    J = torso(V((0, 0, 0.61)), n(0, 0, 1), n(0, 0, 1), n(0, 0.02, 1), n(0, 0.02, 1))
    limb(J, "left", n(math.cos(deg(8)), 0, -math.sin(deg(8))), n(0, 0, -1), arm=False)  # front knee over the ankle
    ra = J["leftAnkle"].z
    hip = J["rightHip"]
    dz = hip.z - ra
    dx = math.sqrt(max(0.0, (TH + SH) ** 2 - dz * dz))
    target = V((hip.x - dx, 0.0, ra))
    limb(J, "right", target - hip, target - hip, arm=False)                               # back leg straight
    limb(J, "left", n(1, 0, 0), n(1, 0, 0))
    limb(J, "right", n(-1, 0, 0), n(-1, 0, 0))
    hands = {"L": (n(1, 0, 0), n(0, 0, -1)), "R": (n(-1, 0, 0), n(0, 0, -1))}            # palms down
    feet = {"L": (n(1, 0, 0), n(0, 0, -1)),                                                 # front foot to the front
            "R": (n(math.sin(deg(15)), -math.cos(deg(15)), 0), n(0, 0, -1))}                # back foot in by 15 deg
    return J, hands, feet


def tree(_=None):
    J = torso(V((0, 0, 0.98)), n(0, 0, 1), n(0, 0, 1), n(0, 0, 1), n(0, 0, 1))
    limb(J, "right", n(0, 0, -1), n(0, 0, -1), arm=False)                                 # standing leg
    limb_ik(J, "left", V((0.045, -0.03, 0.80)), n(1, -0.2, -0.25), arm=False)             # sole on the inner thigh
    for s, sg in (("left", 1), ("right", -1)):
        limb_ik(J, s, V((sg * 0.032, -0.20, 1.22)), n(sg * 1, 0.15, -0.6))               # palms together at the chest
    hands = {"L": (n(0, -0.12, 1), n(-1, 0, 0)), "R": (n(0, -0.12, 1), n(1, 0, 0))}
    feet = {"L": (n(0.05, -0.15, -1), n(-1, 0, 0)), "R": FLAT_FOOT["R"]}
    return J, hands, feet


def forward_fold(t):
    """Legs straight and vertical, hips hinge (sit bones up and back), the spine hangs in front of the legs, the head
    relaxed; t = pelvis tilt, solved until the palms reach the floor beside the feet."""
    def d(a):
        return V((0, -math.sin(a), math.cos(a)))
    J = torso(V((0, 0.17, 0.97)), d(t), d(min(t + deg(38), deg(178))), d(deg(176)), d(deg(180)))
    for s, sx in (("left", 0.10), ("right", -0.10)):
        hip = J[s + "Hip"]
        ankle = V((hip.x, 0.03, MQ.ANKLE_HEIGHT))
        limb(J, s, ankle - hip, ankle - hip, arm=False)
        limb(J, s, n(sx * 0.25, -0.38, -1), n(sx * 0.25, -0.38, -1))   # arms reach down, palms just in front of the feet
    return J, FLAT_HAND, FLAT_FOOT


def _long_body(theta, root_z=0.6):
    u = V((0, -math.cos(theta), math.sin(theta)))         # feet -> head
    J = torso(V((0, 0, root_z)), u, u, u, u)
    for s in ("left", "right"):
        limb(J, s, -u, -u, arm=False)
    feet_tucked = (V((0, -math.sin(theta), -math.cos(theta))), V((0, math.cos(theta), -math.sin(theta))))
    return J, u, {"L": feet_tucked, "R": feet_tucked}


def plank(theta):
    J, u, feet = _long_body(theta)
    for s in ("left", "right"):
        limb(J, s, n(0, 0, -1), n(0, 0, -1))              # arms straight, wrists under the shoulders
    return J, FLAT_HAND, feet


def chaturanga(theta):
    J, u, feet = _long_body(theta, 0.35)
    for s in ("left", "right"):
        limb(J, s, V((0, 1, -0.02)), n(0, 0, -1))         # elbows 90 deg, hugging the ribs, forearms vertical
    return J, FLAT_HAND, feet


def upward_dog(beta):
    J = torso(V((0, 0, 0.3)), V((0, -math.cos(deg(16)), math.sin(deg(16)))),
              V((0, -math.cos(deg(50)), math.sin(deg(50)))),
              V((0, -math.cos(deg(72)), math.sin(deg(72)))),
              V((0, -math.cos(deg(86)), math.sin(deg(86)))))
    leg = V((0, math.cos(beta), -math.sin(beta)))
    for s in ("left", "right"):
        limb(J, s, n(0, 0.04, -1), n(0, 0.04, -1))        # arms straight, shoulders over the wrists
        limb(J, s, leg, leg, arm=False)                    # thighs and knees off the floor
    top = (n(0, 1, -0.03), n(0, 0, 1))                     # tops of the feet on the floor
    return J, FLAT_HAND, {"L": top, "R": top}


# id, file title, sanskrit, builder, solve (lo, hi) or None, views, app entry
POSES = [
    ("upward-salute", "Upward Salute", "Urdhva Hastasana", upward_salute, None, ("front", "three-quarter")),
    ("down-dog", "Down Dog", "Adho Mukha Svanasana", down_dog, (deg(25), deg(80)), ("side", "three-quarter-floor")),
    ("warrior-2", "Warrior II", "Virabhadrasana II", warrior2, None, ("front", "three-quarter")),
    ("tree", "Tree Pose", "Vrksasana", tree, None, ("front", "three-quarter")),
    ("forward-fold", "Forward Fold", "Uttanasana", forward_fold, (deg(95), deg(170)), ("side-front", "three-quarter")),
    ("plank", "Plank", "Phalakasana", plank, (deg(0), deg(40)), ("side", "three-quarter-floor")),
    ("chaturanga", "Chaturanga", "Chaturanga Dandasana", chaturanga, (deg(-15), deg(25)), ("side", "three-quarter-floor")),
    ("upward-dog", "Upward Dog", "Urdhva Mukha Svanasana", upward_dog, (deg(0), deg(35)), ("side", "three-quarter-floor")),
]
# Wyoga order: four missions, then Sun Salutation (Surya Namaskar) in six steps
SEQUENCE = [
    ("01", "upward-salute", ""), ("02", "down-dog", ""), ("03", "warrior-2", ""), ("04", "tree", ""),
    ("05", "upward-salute", "Sun Salutation 1 - "), ("06", "forward-fold", "Sun Salutation 2 - "),
    ("07", "plank", "Sun Salutation 3 - "), ("08", "chaturanga", "Sun Salutation 4 - "),
    ("09", "upward-dog", "Sun Salutation 5 - "), ("10", "down-dog", "Sun Salutation 6 - "),
]
APP_CUES = {
    "down-dog": ("Down dog, Adho Mukha Svanasana", ["Hands shoulder-width, fingers spread, press the floor away.",
                 "Lift the hips up and back into an upside-down V, spine long.", "Heels reach toward the floor, head between the arms."]),
    "forward-fold": ("Forward fold, Uttanasana", ["Fold from the hips, not the waist.",
                     "Let the head hang, hands to the floor or the shins.", "Bend the knees a little if the back rounds."]),
    "plank": ("Plank, Phalakasana", ["Wrists under the shoulders, arms straight.",
              "One straight line from the head to the heels.", "Belly in, hips neither high nor low."]),
    "chaturanga": ("Chaturanga, Chaturanga Dandasana", ["Lower halfway, elbows bent to ninety degrees.",
                   "Elbows hug the ribs, body straight like a plank.", "Shoulders at elbow height, not lower."]),
    "upward-dog": ("Upward dog, Urdhva Mukha Svanasana", ["Arms straight, shoulders over the wrists.",
                   "Chest forward and up, thighs off the floor.", "Tops of the feet press the floor, look forward."]),
}


# ------------------------------------------------------------------ posing in Blender

def hand_foot_frame(y, normal, kind):
    """3x3 for a hand (Z = back of the hand = -palm) or a foot (Z = sole direction)."""
    z = -normal if kind == "hand" else normal.copy()
    y = y.normalized()
    z = (z - y * z.dot(y)).normalized()
    x = y.cross(z)
    return Matrix((x, y, z)).transposed()


def apply_pose(arm, rest, spec):
    J, hands, feet = spec
    P = RM.pose_frame({k: v.copy() for k, v in J.items()}, rest, MQ.ANKLE_HEIGHT)
    for S in ("L", "R"):
        for bone, kind, d in (("hand." + S, "hand", hands[S]), ("foot." + S, "foot", feet[S])):
            M = hand_foot_frame(d[0], d[1], kind).to_4x4()
            M.translation = P[bone].translation
            P[bone] = M
    B = RM.to_basis(P, rest, J["root"])
    for name, *_ in MQ.BONES:
        pb = arm.pose.bones[name]
        pb.rotation_quaternion = B[name].to_quaternion()
        pb.location = B[name].translation if name == "pelvis" else V((0, 0, 0))
    bpy.context.view_layer.update()


def parts():
    return [o for o in bpy.data.objects if o.type == "MESH" and o.parent and o.parent.name == "Skeleton"]


def min_z(objs):
    m = 1e9
    for o in objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            z = (mw @ v.co).z
            if z < m:
                m = z
    return m


def world_points(objs, step=3):
    pts = []
    for o in objs:
        mw = o.matrix_world
        vs = o.data.vertices
        for i in range(0, len(vs), step):
            pts.append(mw @ vs[i].co)
    return pts


def solve(arm, rest, builder, lo, hi):
    """Bisection on the pose parameter until hands and feet touch the floor together."""
    hands = [o for o in parts() if o.name.startswith(("Hand.", "Thumb."))]
    feet = [o for o in parts() if o.name.startswith(("Foot.", "Ankle."))]

    def f(x):
        apply_pose(arm, rest, builder(x))
        return min_z(hands) - min_z(feet)

    flo, fhi = f(lo), f(hi)
    if flo * fhi > 0:
        print(f"WARN no sign change in [{math.degrees(lo):.0f},{math.degrees(hi):.0f}]: {flo:.3f} {fhi:.3f}", flush=True)
        return lo if abs(flo) < abs(fhi) else hi
    for _ in range(30):
        mid = (lo + hi) / 2
        fm = f(mid)
        if (fm > 0) == (flo > 0):
            lo, flo = mid, fm
        else:
            hi = mid
    return (lo + hi) / 2


VIEWS = {   # camera direction (from the camera toward the body), pitch down in degrees
    "front": (V((0, 1, 0)), 6),
    "three-quarter": (V((-math.sin(deg(38)), math.cos(deg(38)), 0)), 9),       # from the front, on the body's left
    "side": (V((-1, 0, 0)), 5),
    "side-front": (V((-math.cos(deg(28)), math.sin(deg(28)), 0)), 8),         # side, turned a little to the front                                                 # from the body's left side
    "three-quarter-floor": (V((-math.cos(deg(35)), math.sin(deg(35)), 0)), 14),  # from the left, toward the head end
}


def turn_body(arm, view):
    """Turn the body so that this view is seen by a camera looking along +Y (into the cyclorama)."""
    d, _ = VIEWS[view]
    arm.rotation_euler = (0, 0, math.pi / 2 - math.atan2(d.y, d.x))
    bpy.context.view_layer.update()


def place_camera(cam, pts, view, aspect=1.0, margin=0.84):
    _, pitch = VIEWS[view]
    d = V((0, 1, 0))
    p = deg(pitch)
    fwd = V((d.x * math.cos(p), d.y * math.cos(p), -math.sin(p)))
    right = fwd.cross(V((0, 0, 1))).normalized()
    up = right.cross(fwd)
    lo = V((min(q.x for q in pts), min(q.y for q in pts), min(q.z for q in pts)))
    hi = V((max(q.x for q in pts), max(q.y for q in pts), max(q.z for q in pts)))
    c = (lo + hi) / 2
    cd = cam.data
    cd.lens = 60
    cd.sensor_fit = "HORIZONTAL" if aspect >= 1 else "VERTICAL"
    cd.sensor_width = 36
    t = 18 / 60
    th, tv = (t, t / aspect) if aspect >= 1 else (t * aspect, t)
    # centre the picture on the projected extents, then back off until every point fits
    for _ in range(3):
        dist = 0.0
        for q in pts:
            r = q - c
            z = r.dot(fwd)
            dist = max(dist, abs(r.dot(right)) / (th * margin) + z, abs(r.dot(up)) / (tv * margin) + z)
        eye = c - fwd * dist
        xs = [(q - eye).dot(right) / (q - eye).dot(fwd) for q in pts]
        ys = [(q - eye).dot(up) / (q - eye).dot(fwd) for q in pts]
        sx, sy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
        c = c + right * sx * dist + up * sy * dist
    cam.location = eye
    cam.rotation_euler = fwd.to_track_quat("-Z", "Y").to_euler()
    cd.clip_end = 200


def project(points, cam_loc, fwd, right, up):
    out = {}
    for k, q in points.items():
        r = q - cam_loc
        out[k] = (r.dot(right) / r.dot(fwd), r.dot(up) / r.dot(fwd))
    return out


def app_entry(pid, title, J, view):
    """2D keypoints in the app's format: normalised, y down, aspect 1, fitted in 0.05..0.95."""
    d, _ = VIEWS["side" if view.startswith("side") else "front"]
    fwd = d.normalized()
    right = fwd.cross(V((0, 0, 1))).normalized()
    up = V((0, 0, 1))
    pts = {
        "nose": J["centerHead"] + (J["topHead"] - J["centerHead"]) * 0.1 + MQ.frame_from(
            J["topHead"] - J["centerHead"], J["leftShoulder"] - J["rightShoulder"]).col[2] * 0.09,
        "neck": J["centerShoulder"],
    }
    for k in ("leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist", "root",
              "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"):
        pts[k] = J[k]
    xy = {k: (q.dot(right), q.dot(up)) for k, q in pts.items()}
    xs = [v[0] for v in xy.values()]
    ys = [v[1] for v in xy.values()]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    s = 0.86 / span
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    joints = {k: [round(0.5 + (x - cx) * s, 4), round(0.5 - (y - cy) * s, 4)] for k, (x, y) in xy.items()}
    speak, cues = APP_CUES[pid]
    return {"id": pid, "name": title, "speak": speak, "cues": cues, "joints": joints, "aspect": 1.0,
            "view": view, "source": "blender/yoga_poses.py (wooden mannequin, 16.11.2026)"}


def posed_joints(arm):
    """World positions of the 17 joints from the posed armature."""
    M = arm.matrix_world
    pb = arm.pose.bones
    J = {"root": M @ pb["pelvis"].head, "spine": M @ pb["chest"].head, "centerShoulder": M @ pb["neck"].head,
         "centerHead": M @ pb["head"].head, "topHead": M @ pb["head"].tail}
    for S, s in (("L", "left"), ("R", "right")):
        J[s + "Shoulder"] = M @ pb["upperarm." + S].head
        J[s + "Elbow"] = M @ pb["forearm." + S].head
        J[s + "Wrist"] = M @ pb["hand." + S].head
        J[s + "Hip"] = M @ pb["thigh." + S].head
        J[s + "Knee"] = M @ pb["shin." + S].head
        J[s + "Ankle"] = M @ pb["foot." + S].head
    return J


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--size", type=int, default=2048)
    ap.add_argument("--samples", type=int, default=128)
    ap.add_argument("--quality", type=int, default=90)
    ap.add_argument("--json", default="")
    a = ap.parse_args(argv)
    out = os.path.abspath(os.path.expanduser(a.out))
    os.makedirs(out, exist_ok=True)

    bpy.ops.wm.open_mainfile(filepath=os.path.join(HERE, "mannequin.blend"))
    scene = bpy.context.scene
    arm = bpy.data.objects["Skeleton"]
    cam = scene.camera
    rest = RM.rest_from_armature(arm)
    scene.render.resolution_x = scene.render.resolution_y = a.size
    scene.render.resolution_percentage = 100
    scene.eevee.taa_render_samples = a.samples
    scene.eevee.use_raytracing = True
    scene.eevee.shadow_ray_count = 3
    scene.eevee.shadow_step_count = 12
    ims = scene.render.image_settings
    ims.media_type = "IMAGE"
    ims.file_format = "JPEG"
    ims.quality = a.quality

    only = set(x for x in a.only.split(",") if x)
    rendered = {}
    entries = []
    for pid, title, sanskrit, builder, rng, views in POSES:
        if only and pid not in only:
            continue
        x = solve(arm, rest, builder, *rng) if rng else None
        spec = builder(x)
        apply_pose(arm, rest, spec)
        objs = parts()
        dz = -min_z(objs)
        J0 = spec[0]
        J0["root"] = J0["root"] + V((0, 0, dz))
        for k in J0:
            if k != "root":
                J0[k] = J0[k] + V((0, 0, dz))
        apply_pose(arm, rest, spec)
        hands = [o for o in objs if o.name.startswith(("Hand.", "Thumb."))]
        feet = [o for o in objs if o.name.startswith(("Foot.", "Ankle."))]
        print(f"POSE {pid} param={'-' if x is None else round(math.degrees(x), 1)} "
              f"hands_z={min_z(hands):.3f} feet_z={min_z(feet):.3f} lowest={min_z(objs):.3f}", flush=True)
        if pid in APP_CUES:
            entries.append(app_entry(pid, title, posed_joints(arm), views[0]))
        for view in views:
            turn_body(arm, view)
            pts = world_points(objs)
            place_camera(cam, pts, view)
            tag = {"front": "front", "side": "side", "three-quarter": "three-quarter",
                   "three-quarter-floor": "three-quarter", "side-front": "side"}[view]
            path = os.path.join(out, f"_{pid}_{tag}.jpg")
            scene.render.filepath = path
            bpy.ops.render.render(write_still=True)
            rendered[(pid, tag)] = path
            print(f"STILL {path}", flush=True)
        turn_body(arm, "front")

    # final names in Wyoga's order (the same pose may appear twice: copied)
    import shutil
    names = {p[0]: (p[1], p[2]) for p in POSES}
    for num, pid, prefix in SEQUENCE:
        title, sk = names[pid]
        for (rp, tag), src in rendered.items():
            if rp != pid:
                continue
            dst = os.path.join(out, f"{num} {prefix}{title} - {sk} ({tag}).jpg")
            shutil.copyfile(src, dst)
            print(f"FILE {dst}", flush=True)
    for src in rendered.values():
        os.remove(src)

    if a.json and entries:
        jp = os.path.abspath(os.path.expanduser(a.json))
        with open(jp) as f:
            lst = json.load(f)
        have = {e.get("id") for e in lst}
        added = [e for e in entries if e["id"] not in have]
        lst.extend(added)
        with open(jp, "w") as f:
            json.dump(lst, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print(f"JSON appended {[e['id'] for e in added]} to {jp}", flush=True)
    print("DONE " + out, flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"ERROR {type(e).__name__}: {e}", flush=True)
        sys.stdout.flush()
        os._exit(1)
    sys.stdout.flush()
    os._exit(0)
