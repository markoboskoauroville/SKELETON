"""Render a Skeleton (Mantra) recording (*.skel.json) as the wooden mannequin doing the same movement.

    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P blender/render_mannequin.py -- \
        --in X.skel.json --out ~/Desktop/X_mannequin.mp4 [--res 1280x720] [--samples 16] [--frames N]

Prints "PROGRESS n/N" per rendered frame, "DONE <path>" at the end, "ERROR <reason>" (exit 1) on failure.
How it maps: see TAKEOVER.md (Blender part). In short: Vision 3D (y up) -> Blender (Z up); the body is turned so it
faces the render camera the way it faced the real camera (decided from p2), chirality checked on the knees;
every bone is aimed from its parent joint to its child joint (torso keeps its twist from the hip and shoulder
lines, limbs take the smallest swing), bone lengths stay the mannequin's own, the lowest sole sits on the floor.
"""
import argparse
import json
import math
import os
import shutil
import sys
import tempfile
import time
import traceback

import bpy
from mathutils import Matrix, Quaternion, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mannequin as MQ  # noqa: E402

def fail(msg):
    print("ERROR " + msg, flush=True)
    sys.stdout.flush()
    os._exit(1)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--res", default="1280x720")
    ap.add_argument("--samples", type=int, default=16)
    ap.add_argument("--frames", type=int, default=0, help="render only the first N frames (tests)")
    ap.add_argument("--blend", default="", help="also save the animated scene as this .blend")
    ap.add_argument("--no-render", action="store_true", help="only build the animation (with --blend)")
    return ap.parse_args(argv)


# ------------------------------------------------------------------ reading and cleaning the recording

def load_recording(path):
    with open(path) as f:
        d = json.load(f)
    if not str(d.get("format", "")).startswith("skeleton-mantra/"):
        raise ValueError("not a skeleton-mantra recording: " + path)
    roles3 = d.get("roles3d") or {}
    roles2 = d.get("roles2d") or {}
    fps = float(d.get("fps") or 30.0)
    frames = d.get("frames") or []
    samples = []      # (t, {role: Vector vision})
    p2 = []
    heights = []
    for fr in frames:
        t = float(fr.get("t", 0.0))
        p3 = fr.get("p3")
        if p3:
            J = {}
            for raw, xyz in p3.items():
                role = roles3.get(raw, raw)
                if role in MQ.REST_JOINTS and xyz is not None and len(xyz) >= 3:
                    J[role] = Vector(xyz[:3])
            if len(J) >= 12:
                samples.append((t, J))
        q = fr.get("p2") or {}
        p2.append({roles2.get(k, k): v for k, v in q.items()})
        if fr.get("h"):
            heights.append(float(fr["h"]))
    if not samples:
        raise ValueError("the recording has no 3D skeleton frames (p3)")
    duration = float(d.get("duration") or (frames[-1].get("t", 0.0) if frames else 0.0))
    return d, fps, samples, p2, heights, duration


def vision_to_blender(v):
    # Vision: x = subject's left (sample convention), y up, z toward the camera.
    # Blender: X, Z up, camera on -Y.  (x, y, z) -> (x, -z, y)   (a proper rotation)
    return Vector((v.x, -v.z, v.y))


def resample(samples, fps, duration):
    """Joint positions at every output frame k/fps, interpolated over t; gaps filled, ends held."""
    times = [t for t, _ in samples]
    t0 = times[0]
    tend = max(duration, times[-1])
    n = max(1, int(round((tend - t0) * fps)) + 1)
    out = []
    j = 0
    for k in range(n):
        t = t0 + k / fps
        while j + 1 < len(times) and times[j + 1] < t:
            j += 1
        a_t, A = samples[j]
        if j + 1 < len(samples):
            b_t, B = samples[j + 1]
        else:
            b_t, B = a_t, A
        w = 0.0 if b_t <= a_t else min(1.0, max(0.0, (t - a_t) / (b_t - a_t)))
        J = {}
        for name in MQ.JOINTS:
            pa, pb = A.get(name), B.get(name)
            if pa is not None and pb is not None:
                J[name] = pa.lerp(pb, w)
            elif pa is not None or pb is not None:
                J[name] = (pa if pa is not None else pb).copy()
        out.append(J)
    # joints missing in some frames: take the nearest frame that has them
    for name in MQ.JOINTS:
        have = [i for i, J in enumerate(out) if name in J]
        if not have:
            continue
        for i, J in enumerate(out):
            if name not in J:
                nearest = min(have, key=lambda h: abs(h - i))
                J[name] = out[nearest][name].copy()
    missing = [n for n in MQ.JOINTS if n not in out[0]]
    if missing:
        raise ValueError("joints never seen: " + ", ".join(missing))
    return out


def smooth(seq, radius=1):
    """Moving average over 2*radius+1 frames (3 frames by default)."""
    n = len(seq)
    out = []
    for i in range(n):
        lo, hi = max(0, i - radius), min(n, i + radius + 1)
        J = {}
        for name in MQ.JOINTS:
            acc = Vector((0, 0, 0))
            for k in range(lo, hi):
                acc += seq[k][name]
            J[name] = acc / (hi - lo)
        out.append(J)
    return out


def body_axes(J):
    left = (J["leftHip"] - J["rightHip"]) + (J["leftShoulder"] - J["rightShoulder"])
    up = J["centerShoulder"] - J["root"]
    fwd = left.cross(up)
    return left, up, fwd


def orient(seq, p2):
    """Rotate about Z so the body faces the render camera as it faced the real one; fix chirality."""
    # chirality: knees bend forward. Flip x if the data says they bend backward.
    score = 0.0
    for J in seq:
        _, _, fwd = body_axes(J)
        if fwd.length < 1e-6:
            continue
        fwd = fwd.normalized()
        for s in ("left", "right"):
            mid = (J[s + "Hip"] + J[s + "Ankle"]) / 2
            score += (J[s + "Knee"] - mid).dot(fwd)
    flipped = False
    if score < -0.02 * len(seq):
        flipped = True
        for J in seq:
            for k in J:
                J[k].x = -J[k].x
    # mean facing (horizontal)
    acc = Vector((0, 0, 0))
    for J in seq:
        _, _, fwd = body_axes(J)
        f = Vector((fwd.x, fwd.y, 0))
        if f.length > 1e-6:
            acc += f.normalized()
    facing_camera = True
    votes = 0.0
    for q in p2:
        ls, rs = q.get("leftShoulder"), q.get("rightShoulder")
        lh, rh = q.get("leftHip"), q.get("rightHip")
        for a, b in ((ls, rs), (lh, rh)):
            if a and b and len(a) >= 3 and len(b) >= 3:
                # raw camera image: a person facing the camera has his left on the image right
                votes += (a[0] - b[0]) * min(a[2], b[2])
    if votes < -0.5:
        facing_camera = False
    target = Vector((0, -1, 0)) if facing_camera else Vector((0, 1, 0))
    yaw = 0.0
    if acc.length > 1e-6:
        acc.normalize()
        yaw = math.atan2(target.y, target.x) - math.atan2(acc.y, acc.x)
    R = Matrix.Rotation(yaw, 3, "Z")
    for J in seq:
        for k in J:
            J[k] = R @ J[k]
    return flipped, facing_camera, math.degrees(yaw)


def mirror_seq(seq):
    out = []
    for J in seq:
        M = {}
        for k, v in J.items():
            if k.startswith("left"):
                k2 = "right" + k[4:]
            elif k.startswith("right"):
                k2 = "left" + k[5:]
            else:
                k2 = k
            M[k2] = Vector((-v.x, v.y, v.z))
        out.append(M)
    return out


# ------------------------------------------------------------------ pose maths

def pose_frame(J, rest, ankle_h):
    """Armature-space pose matrices (root at the origin) for one frame of joint positions (rest units)."""
    P = {}
    for name, hj, tj, parent, rule in MQ.BONES:
        Mrest, length = rest[name]
        if parent is None:
            head = Vector((0, 0, 0)) + (J[hj] - J["root"])  # root bone head at the root joint
        else:
            Pp = P[parent]
            head = (Pp @ rest[parent][0].inverted() @ Mrest).translation
        if rule == "torso":
            a, b = MQ.TORSO_XREF[name]
            R = MQ.frame_from(J[tj] - J[hj], J[b] - J[a])
        elif rule == "swing":
            pred = (P[parent].to_3x3() @ rest[parent][0].to_3x3().inverted() @ Mrest.to_3x3())
            y0 = pred.col[1]
            y1 = (J[tj] - J[hj])
            if y1.length < 1e-6:
                R = pred
            else:
                y1.normalize()
                if y0.dot(y1) < -0.999:
                    q = Quaternion(pred.col[0], math.pi)
                else:
                    q = y0.rotation_difference(y1)
                R = q.to_matrix() @ pred
        elif rule == "hand":
            R = P[parent].to_3x3() @ rest[parent][0].to_3x3().inverted() @ Mrest.to_3x3()
        else:  # foot: flat, turned toward the knee / pelvis facing
            side = "left" if name.endswith(".L") else "right"
            pel = P["pelvis"].to_3x3()
            fwd = pel.col[2].copy()
            fwd.z = 0
            mid = (J[side + "Hip"] + J[side + "Ankle"]) / 2
            knee = J[side + "Knee"] - mid
            knee.z = 0
            f = (fwd.normalized() if fwd.length > 1e-6 else Vector((0, -1, 0))) + knee * 6.0
            if f.length < 1e-6:
                f = Vector((0, -1, 0))
            f.normalize()
            yaw = math.atan2(f.y, f.x) - math.atan2(-1.0, 0.0)
            R = Matrix.Rotation(yaw, 3, "Z") @ Mrest.to_3x3()
        M = R.to_4x4()
        M.translation = head
        P[name] = M
    return P


def to_basis(P, rest, root_loc):
    """matrix_basis per bone. pose = parent_pose @ (parent_rest^-1 @ rest) @ basis."""
    B = {}
    T = Matrix.Translation(root_loc)
    for name, hj, tj, parent, rule in MQ.BONES:
        Mrest = rest[name][0]
        if parent is None:
            B[name] = Mrest.inverted() @ (T @ P[name])
        else:
            rel = rest[parent][0].inverted() @ Mrest
            B[name] = rel.inverted() @ P[parent].inverted() @ P[name]
    return B


def rest_from_armature(arm):
    rest = {}
    for name, *_ in MQ.BONES:
        b = arm.data.bones[name]
        rest[name] = (b.matrix_local.copy(), b.length)
    return rest


# ------------------------------------------------------------------ main

def main():
    a = parse_args()
    inp = os.path.abspath(os.path.expanduser(a.inp))
    out = os.path.abspath(os.path.expanduser(a.out))
    try:
        rw, rh = (int(x) for x in a.res.lower().split("x"))
    except Exception:
        fail("bad --res, use WIDTHxHEIGHT")
    if not os.path.isfile(inp):
        fail("no such recording: " + inp)
    try:
        d, fps, samples, p2, heights, duration = load_recording(inp)
    except Exception as e:
        fail(str(e))
    fps_i = max(1, int(round(fps)))

    blend = os.path.join(HERE, "mannequin.blend")
    if os.path.isfile(blend):
        bpy.ops.wm.open_mainfile(filepath=blend)
    else:
        MQ.build(None)
    scene = bpy.context.scene
    arm = bpy.data.objects["Skeleton"]
    cam = scene.camera
    rest = rest_from_armature(arm)

    # positions: Vision -> Blender, resample on the output frame grid, smooth, orient, mirror
    samples = [(t, {k: vision_to_blender(v) for k, v in J.items()}) for t, J in samples]
    seq = resample(samples, fps_i, duration)
    seq = smooth(seq, 1)
    flipped, facing, yaw = orient(seq, p2)
    if d.get("mirror"):
        seq = mirror_seq(seq)
    if a.frames:
        seq = seq[:a.frames]
    n = len(seq)

    # size: Vision's body height, else the median standing height of the data
    if heights:
        heights.sort()
        h = heights[len(heights) // 2]
    else:
        est = sorted((J["topHead"] - J["root"]).length + ((J["leftAnkle"] - J["root"]).length +
                     (J["rightAnkle"] - J["root"]).length) / 2 for J in seq)
        h = est[len(est) // 2] + MQ.ANKLE_HEIGHT
    if not (1.0 < h < 2.3):
        h = MQ.REST_HEIGHT
    s = h / MQ.REST_HEIGHT
    arm.scale = (s, s, s)
    print(f"INFO frames={n} fps={fps_i} height={h:.2f} facing_camera={facing} chirality_flip={flipped} "
          f"yaw={yaw:.0f} mirror={bool(d.get('mirror'))}", flush=True)

    # pose every frame (armature space = rest units; data metres / s)
    poses, root_z = [], []
    for J in seq:
        Jr = {k: v / s for k, v in J.items()}
        P = pose_frame(Jr, rest, MQ.ANKLE_HEIGHT)
        lowest = min(P["foot.L"].translation.z, P["foot.R"].translation.z)
        poses.append(P)
        root_z.append(MQ.REST_JOINTS["root"][2] - (MQ.REST_JOINTS["root"][2] + lowest - MQ.ANKLE_HEIGHT))
    # root z so the lowest ankle stands at ankle height (lowest sole on the floor), lightly smoothed
    rz = [sum(root_z[max(0, i - 1):i + 2]) / len(root_z[max(0, i - 1):i + 2]) for i in range(n)]
    # Root travel: Vision p3 is root-relative, so the body stays at the origin (x, y = 0).

    scene.frame_start = 1
    scene.frame_end = n
    scene.render.fps = fps_i
    scene.render.fps_base = 1.0
    prev_q = {}
    world_pts = []
    for i, P in enumerate(poses):
        f = i + 1
        B = to_basis(P, rest, Vector((0, 0, rz[i])))
        for name, *_ in MQ.BONES:
            pb = arm.pose.bones[name]
            q = B[name].to_quaternion()
            if name in prev_q and prev_q[name].dot(q) < 0:
                q.negate()
            prev_q[name] = q
            pb.rotation_quaternion = q
            pb.keyframe_insert("rotation_quaternion", frame=f)
            if name == "pelvis":
                pb.location = B[name].translation
                pb.keyframe_insert("location", frame=f)
        # world points of this frame for the camera framing (head top, hands, feet)
        pts = []
        for name in ("head", "hand.L", "hand.R", "foot.L", "foot.R", "forearm.L", "forearm.R", "shin.L", "shin.R"):
            M = Matrix.Translation((0, 0, rz[i])) @ P[name]
            ln = rest[name][1]
            pts.append((M @ Vector((0, ln, 0))) * s)
            pts.append(M.translation * s)
        world_pts.append(pts)

    frame_camera(scene, cam, world_pts, rw, rh, fps_i)

    scene.render.resolution_x = rw
    scene.render.resolution_y = rh
    scene.render.resolution_percentage = 100
    scene.eevee.taa_render_samples = max(1, a.samples)
    ims = scene.render.image_settings
    ims.media_type = "VIDEO"
    ims.file_format = "FFMPEG"
    ff = scene.render.ffmpeg
    ff.format = "MPEG4"
    ff.codec = "H264"
    ff.constant_rate_factor = "HIGH"
    ff.ffmpeg_preset = "GOOD"
    ff.audio_codec = "NONE"
    tmpdir = tempfile.mkdtemp(prefix="mannequin_")
    scene.render.filepath = os.path.join(tmpdir, "render_")
    scene.render.use_file_extension = True

    if a.blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(os.path.expanduser(a.blend)), copy=True)
    if a.no_render:
        shutil.rmtree(tmpdir, ignore_errors=True)
        print("DONE " + (a.blend or "(nothing rendered)"), flush=True)
        return

    count = {"n": 0}
    t_start = time.time()

    def on_post(sc, *_):
        count["n"] += 1
        print(f"PROGRESS {count['n']}/{n}", flush=True)

    bpy.app.handlers.render_post.append(on_post)
    bpy.ops.render.render(animation=True)
    made = [os.path.join(tmpdir, x) for x in os.listdir(tmpdir) if x.lower().endswith((".mp4", ".m4v", ".mov"))]
    if not made:
        fail("Blender wrote no movie (looked in %s)" % tmpdir)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    shutil.move(made[0], out)
    shutil.rmtree(tmpdir, ignore_errors=True)
    el = time.time() - t_start
    print(f"INFO render {el:.1f} s for {n} frames ({el / max(1e-6, n / fps_i):.1f} s per second of motion)", flush=True)
    print("DONE " + out, flush=True)


def frame_camera(scene, cam, world_pts, rw, rh, fps):
    """Front camera, slightly above, distance fits the whole movement; follows the body sideways smoothly."""
    xs = [p.x for pts in world_pts for p in pts]
    zs = [p.z for pts in world_pts for p in pts]
    xmin, xmax = min(xs) - 0.15, max(xs) + 0.15
    zmin, zmax = min(0.0, min(zs)) - 0.08, max(zs) + 0.12
    cd = cam.data
    cd.lens = 50
    cd.sensor_width = 36
    cd.sensor_fit = "HORIZONTAL"
    hfov = 2 * math.atan(18 / 50)
    vfov = 2 * math.atan(18 * rh / rw / 50)
    half_h = (zmax - zmin) / 2 * 1.12
    half_w = (xmax - xmin) / 2 * 1.12
    dist = max(half_h / math.tan(vfov / 2), half_w / math.tan(hfov / 2), 3.0)
    cz = (zmax + zmin) / 2
    pitch = math.radians(4.0)
    cx_center = (xmin + xmax) / 2
    cam.rotation_euler = (math.pi / 2 - pitch, 0, 0)
    # the body does not travel (root-relative data) so the camera holds still, centred on the movement
    cam.location = (cx_center, -dist * math.cos(pitch), cz + dist * math.sin(pitch))
    cd.clip_end = 100


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        traceback.print_exc()
        fail(f"{type(e).__name__}: {e}")
    sys.stdout.flush()
    os._exit(0)
