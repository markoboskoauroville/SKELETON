#!/usr/bin/env python3
"""synth: a clean synthetic Skeleton (Mantra) motion with known truth, and a Vision-like noisy copy of it.

    python3 cleanup/synth.py out_dir      -> clean.skel.json, noisy.skel.json, truth.json (what was injected)

10 s at 30 fps, subject facing the camera (x = subject's left, y up, z toward the camera), world floor y = 0:
  0-2 s  standing, arms waving          2-4 s  squat, both feet planted
  4-6 s  left foot steps 30 cm forward   6-8 s  arms overhead, perfectly still (a yoga hold)
  8-10 s arms come down, small sway
Bone lengths are exactly constant in the clean motion (legs by two-bone IK, arms by forward kinematics).
Noise: 1.2 cm Gaussian per joint, 1 % per-frame scale wobble, 6 spikes of 25 cm, a 6-frame wrist gap, one frame
without 3D, legs left/right swapped for 5 frames, the right knee bent 20 deg backwards for 6 frames.
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skelcore as sc  # noqa: E402
from skelcore import IDX, ROLES  # noqa: E402

FPS = 30.0
THIGH, SHIN = 0.43, 0.42
UPPER, FORE = 0.29, 0.26
HIPW, SHW = 0.10, 0.19
ANKLE_Y = 0.08


def smooth01(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def _ik(H, A, pole):
    d = A - H
    dist = min(np.linalg.norm(d), THIGH + SHIN - 1e-4)
    e = d / np.linalg.norm(d)
    A = H + e * dist
    p = pole - e * np.dot(pole, e)
    p /= np.linalg.norm(p)
    ca = (THIGH ** 2 + dist ** 2 - SHIN ** 2) / (2 * THIGH * dist)
    K = H + THIGH * (e * ca + p * math.sqrt(max(0, 1 - ca * ca)))
    return K, A


def _arm(S, side, abd, flex, elbow):
    """Shoulder S, abduction (0 = down, pi/2 = sideways, pi = overhead), forward flexion, elbow bend."""
    sx = 1.0 if side == "left" else -1.0
    up = np.array([math.sin(abd) * sx, -math.cos(abd), 0.0])
    fwd = np.array([0.0, 0.0, 1.0])
    d1 = up * math.cos(flex) + fwd * math.sin(flex)
    d1 /= np.linalg.norm(d1)
    E = S + UPPER * d1
    axis = np.cross(d1, fwd if abs(np.dot(d1, fwd)) < 0.9 else np.array([1.0, 0, 0]))
    axis /= np.linalg.norm(axis)
    c, s = math.cos(elbow), math.sin(elbow)
    d2 = d1 * c + np.cross(axis, d1) * s + axis * np.dot(axis, d1) * (1 - c)
    W = E + FORE * d2
    return E, W


def clean_motion():
    T = int(10 * FPS)
    t = np.arange(T) / FPS
    Pw = np.zeros((T, len(ROLES), 3))
    for i, ti in enumerate(t):
        squat = 0.25 * math.sin(math.pi * np.clip((ti - 2) / 2, 0, 1)) ** 2
        step = smooth01((ti - 4.2) / 1.0)
        root_z = 0.15 * smooth01((ti - 4) / 2)
        sway = 0.02 * math.sin(2 * math.pi * 0.5 * ti) * smooth01((ti - 8) / 0.5)
        R = np.array([sway, ANKLE_Y + 0.82 - squat, root_z])
        lA = np.array([HIPW, ANKLE_Y, 0.0 + 0.30 * step])
        lA[1] += 0.10 * math.sin(math.pi * step)
        rA = np.array([-HIPW, ANKLE_Y, 0.0])
        lH, rH = R + [HIPW, 0, 0], R + [-HIPW, 0, 0]
        lK, lA = _ik(lH, lA, np.array([0, 0, 1.0]))
        rK, rA = _ik(rH, rA, np.array([0, 0, 1.0]))
        spine = R + [0, 0.22, 0]
        cs = spine + [0, 0.28, 0]
        ch = cs + [0, 0.18, 0]
        th = ch + [0, 0.12, 0]
        lS, rS = cs + [SHW, 0, 0], cs + [-SHW, 0, 0]
        if ti < 2:
            abd, el = 0.6 + 0.5 * math.sin(2 * math.pi * 1.0 * ti), 0.3
        elif ti < 4:
            abd, el = 0.2, 0.4 + 0.3 * squat / 0.25
        elif ti < 6:
            abd, el = 0.2 + 2.7 * smooth01((ti - 5) / 1), 0.4 - 0.3 * smooth01((ti - 5) / 1)
        elif ti < 8:
            abd, el = 2.9, 0.1
        else:
            abd, el = 2.9 - 2.7 * smooth01((ti - 8) / 1.5), 0.1 + 0.2 * smooth01((ti - 8) / 1.5)
        flex = 0.4 * squat / 0.25
        lE, lW = _arm(lS, "left", abd, flex, el)
        rE, rW = _arm(rS, "right", abd, flex, el)
        pos = {"root": R, "spine": spine, "centerShoulder": cs, "centerHead": ch, "topHead": th,
               "leftShoulder": lS, "rightShoulder": rS, "leftElbow": lE, "rightElbow": rE, "leftWrist": lW,
               "rightWrist": rW, "leftHip": lH, "rightHip": rH, "leftKnee": lK, "rightKnee": rK,
               "leftAnkle": lA, "rightAnkle": rA}
        for r, p in pos.items():
            Pw[i, IDX[r]] = p
    rw = Pw[:, IDX["root"]].copy()
    P = Pw - rw[:, None, :]
    contact = {"left": (t < 4.15) | (t > 5.3), "right": np.ones(T, bool)}
    return t, P, rw, contact


PX_PER_M = 450.0
W_IMG, H_IMG = 1920, 1080
MAP2 = {r: r for r in ["leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
                       "root", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]}


def to_doc(t, P, rw, noise2d=0.0, rng=None, drop3d=()):
    frames = []
    for i in range(len(t)):
        f = {"t": round(float(t[i]), 4)}
        if i not in drop3d:
            f["p3"] = {r: [round(float(v), 4) for v in P[i, IDX[r]]] for r in ROLES
                       if not np.isnan(P[i, IDX[r]]).any()}
        p2 = {}
        Wd = P[i] + rw[i]
        for r2, r3 in list(MAP2.items()) + [("neck", "centerShoulder"), ("nose", "centerHead")]:
            x, y = Wd[IDX[r3], 0], Wd[IDX[r3], 1]
            if np.isnan(x):
                continue
            n = rng.normal(0, noise2d, 2) if rng is not None else (0, 0)
            p2[r2] = [round(0.5 + (x * PX_PER_M + n[0]) / W_IMG, 5), round(0.9 - (y * PX_PER_M + n[1]) / H_IMG, 5), 0.9]
        f["p2"] = p2
        f["h"] = 1.62
        frames.append(f)
    return {"format": sc.FORMAT, "fps": FPS, "camera": "synthetic", "width": W_IMG, "height": H_IMG, "mirror": False,
            "joints3d": ROLES, "joints2d": ["nose", "neck"] + list(MAP2), "roles3d": {r: r for r in ROLES},
            "roles2d": {r: r for r in ["nose", "neck"] + list(MAP2)}, "duration": float(t[-1]), "frames": frames}


def noisy_copy(P, t, seed=7):
    rng = np.random.default_rng(seed)
    T = len(P)
    N = P.copy()
    truth = {}
    # right knee hyperextended 20 deg for 6 frames while standing straight (frames 30..35)
    hk = list(range(30, 36))
    for i in hk:
        H, K, A = N[i, IDX["rightHip"]], N[i, IDX["rightKnee"]], N[i, IDX["rightAnkle"]]
        v = A - K
        ax = np.array([1.0, 0, 0])
        u = K - H
        bend = math.atan2(np.dot(ax, np.cross(u, v)), np.dot(u, v))  # signed flexion about +x
        ang = -bend - math.copysign(math.radians(20), bend)  # 20 deg past straight, the wrong way
        c, s = math.cos(ang), math.sin(ang)
        v2 = v * c + np.cross(ax, v) * s + ax * np.dot(ax, v) * (1 - c)
        N[i, IDX["rightAnkle"]] = K + v2
    truth["hyperext_frames"] = hk
    N *= (1 + rng.normal(0, 0.01, (T, 1, 1)))
    N += rng.normal(0, 0.012, N.shape)
    spikes = [(40, "leftWrist"), (77, "rightElbow"), (120, "leftKnee"), (181, "topHead"), (222, "rightWrist"),
              (260, "leftAnkle")]
    for f, r in spikes:
        N[f, IDX[r]] += rng.normal(0, 1, 3) / np.sqrt(3) * 0.25 + np.array([0.15, 0, 0])
    truth["spikes"] = spikes
    N[200:206, IDX["leftWrist"]] = np.nan
    truth["gap"] = [200, 206, "leftWrist"]
    sw = list(range(150, 155))
    for i in sw:
        for a, b in sc.LR_PAIRS["legs"]:
            N[i, [IDX[a], IDX[b]]] = N[i, [IDX[b], IDX[a]]]
    truth["swap_frames"] = sw
    N[:, IDX["root"]] = 0.0
    truth["drop3d"] = [100]
    return N, truth


def make(out_dir, seed=7):
    os.makedirs(out_dir, exist_ok=True)
    t, P, rw, contact = clean_motion()
    N, truth = noisy_copy(P, t, seed)
    rng = np.random.default_rng(seed + 1)
    clean_doc = to_doc(t, P, rw)
    noisy_doc = to_doc(t, N, rw, noise2d=2.0, rng=rng, drop3d=set(truth["drop3d"]))
    paths = {k: os.path.join(out_dir, k + ".skel.json") for k in ("clean", "noisy")}
    sc.save(clean_doc, paths["clean"])
    sc.save(noisy_doc, paths["noisy"])
    with open(os.path.join(out_dir, "truth.json"), "w") as fh:
        json.dump({**truth, "contact": {k: v.tolist() for k, v in contact.items()}}, fh)
    return t, P, rw, contact, N, truth, paths


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "synthetic"
    make(out)
    print("written", out)
