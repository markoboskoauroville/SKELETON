#!/usr/bin/env python3
"""skelclean: kinematic cleanup of a Skeleton (Mantra) recording (*.skel.json, skeleton-mantra/1).

    skelclean in.skel.json -o out.skel.json --preset gentle|standard|strong|yoga-hold|dance [--report [r.md|r.json]]
    skelclean in.skel.json -o out.skel.json --preset standard --skip feet --set oneeuro.min_cutoff=0.8

Pipeline (each step switchable with --skip / --only, parameters with --set step.key=value):
  swaps     g) left/right label swaps (arms, legs) fixed by temporal continuity. Runs FIRST: a swap smeared by
               the filter cannot be undone afterwards.
  outliers  a) confidence + outlier rejection (Hampel on the 3D track, bone-length outliers, impossible speeds)
  gaps      a) gap filling, PCHIP (no overshoot) up to max_gap frames; longer gaps keep the original data
  oneeuro   b) One Euro filter, speed adaptive, run forward and backward (zero phase, no lag)
  savgol    b) optional Savitzky-Golay offline smoothing
  bones     c) constant bone lengths: robust median length per bone (left/right averaged), children re-projected
               from the root outward along their measured direction
  limits    d) knee and elbow hinge limits: no hyperextension, no over-flexion, minimal rotation of the lower limb
  holds        (yoga-hold) still holds made perfectly still, transitions blended
  rekey        (strong) key poses kept, in-betweens regenerated (the Cascadeur idea, tolerance stated)
  feet      e) floor estimate, foot contact detection (low + still for N frames), foot locking with two-bone IK;
               with a 2D track the root's travel is estimated (camera plane from p2, depth from the planted feet)
  root      f) root trajectory smoothing and speed/acceleration limits (world root only), joint speed limits
  bones again at the end so every output frame has exactly the clip's bone lengths.
"""
import argparse
import copy
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skelcore as sc  # noqa: E402
from skelcore import IDX, ROLES, BONES, LR_PAIRS  # noqa: E402

VERSION = 1

BASE = {
    "swaps": {"on": True, "ratio": 0.5, "min_cost_m": 0.06},
    "outliers": {"on": True, "window": 7, "k": 4.0, "min_dev_m": 0.06, "bone_tol": 0.25, "conf_min": 0.0,
                 "vmax_ms": 12.0},
    "gaps": {"on": True, "max_gap": 15, "method": "pchip"},
    "oneeuro": {"on": True, "min_cutoff": 1.0, "beta": 4.0, "d_cutoff": 1.0, "zero_phase": True},
    "savgol": {"on": False, "window": 9, "poly": 3},
    "bones": {"on": True, "symmetric": True},
    "limits": {"on": True, "knee_hyper_deg": 8.0, "knee_max_deg": 160.0, "elbow_hyper_deg": 12.0,
               "elbow_max_deg": 155.0, "ref_bend_deg": 25.0, "reinterp_frames": 8},
    "feet": {"on": True, "world": "auto", "height_m": 0.06, "speed_ms": 0.25, "min_frames": 5, "blend": 4,
             "max_drift_rel_m": 0.05, "max_drift_world_m": 0.25, "root_share": 1.0, "lock_axes": None},
    "root": {"on": True, "vmax_ms": 6.0, "amax_ms2": 40.0, "joint_vmax_ms": 10.0},
    "holds": {"on": False, "speed_ms": 0.08, "min_s": 0.8, "blend": 6, "strength": 1.0},
    "rekey": {"on": False, "tol_m": 0.02},
}
PRESETS = {
    "gentle": {"oneeuro": {"min_cutoff": 2.5, "beta": 6.0}, "outliers": {"k": 6.0}},
    "standard": {},
    "strong": {"oneeuro": {"min_cutoff": 0.5, "beta": 2.0}, "savgol": {"on": True},
               "rekey": {"on": True, "tol_m": 0.015}},
    "yoga-hold": {"oneeuro": {"min_cutoff": 0.4, "beta": 2.0}, "holds": {"on": True},
                  "feet": {"speed_ms": 0.15}},
    "dance": {"oneeuro": {"min_cutoff": 1.5, "beta": 8.0}, "root": {"vmax_ms": 9.0, "amax_ms2": 80.0,
                                                                     "joint_vmax_ms": 16.0},
              "outliers": {"vmax_ms": 16.0, "k": 5.0}, "feet": {"min_frames": 4, "blend": 3}},
}
ORDER = ["swaps", "outliers", "gaps", "oneeuro", "savgol", "bones", "limits", "holds", "rekey", "feet", "root"]


def params_for(preset, sets=(), skip=(), only=None):
    if preset not in PRESETS:
        raise SystemExit(f"unknown preset {preset!r}; one of {', '.join(PRESETS)}")
    p = copy.deepcopy(BASE)
    for step, kv in PRESETS[preset].items():
        p[step].update(kv)
    for s in sets:
        key, _, val = s.partition("=")
        step, _, k = key.partition(".")
        if step not in p or not k:
            raise SystemExit(f"--set {s}: use step.key=value, steps: {', '.join(p)}")
        try:
            v = json.loads(val)
        except ValueError:
            v = val
        p[step][k] = v
    for s in skip:
        p[s]["on"] = False
    if only:
        for s in p:
            p[s]["on"] = s in only
    return p


# ------------------------------------------------------------------ g) swaps

def fix_swaps(P, prm):
    P = P.copy()
    T = len(P)
    fixed = []
    groups = {"arms": LR_PAIRS["arms"], "legs": LR_PAIRS["legs"], "both": LR_PAIRS["arms"] + LR_PAIRS["legs"]}
    prev = None
    prev2 = None
    for i in range(T):
        cur = P[i]
        if np.isnan(cur).all():
            continue
        if prev is None:
            prev = cur.copy()
            continue
        pred = prev if prev2 is None else prev + 0.5 * (prev - prev2)  # damped constant velocity

        def cost(X, pairs):
            idx = [IDX[a] for pr in pairs for a in pr]
            d = np.linalg.norm(X[idx] - pred[idx], axis=-1)
            return np.nansum(d)

        best, best_name = None, None
        for name, pairs in groups.items():
            base = cost(cur, pairs)
            sw = cur.copy()
            for a, b in pairs:
                sw[[IDX[a], IDX[b]]] = cur[[IDX[b], IDX[a]]]
            c = cost(sw, pairs)
            if base > prm["min_cost_m"] * len(pairs) and c < prm["ratio"] * base:
                gain = base - c
                if best is None or gain > best:
                    best, best_name = gain, (name, sw)
        if best_name:
            P[i] = best_name[1]
            fixed.append((i, best_name[0]))
        prev2, prev = prev, P[i].copy()
    return P, fixed


# ------------------------------------------------------------------ a) outliers + gaps

def rolling_median(X, w):
    T = len(X)
    h = w // 2
    out = np.empty_like(X)
    for i in range(T):
        out[i] = np.nanmedian(X[max(0, i - h):i + h + 1], axis=0)
    return out


def find_outliers(P, t, conf, has2d, prm):
    T, J, _ = P.shape
    bad = np.zeros((T, J), bool)
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        med = rolling_median(P, prm["window"])
        dev = np.linalg.norm(P - med, axis=-1)  # [T,J]
        mad = rolling_median(dev[:, :, None], max(prm["window"] * 3, 15))[:, :, 0]
        thr = np.maximum(prm["min_dev_m"], prm["k"] * 1.4826 * mad)
        bad |= dev > thr
        # bone-length outliers: the child of a bone far from its median length
        L = sc.bone_lengths(P)
        Lm = np.nanmedian(L, axis=0)
        for k, (p, c) in enumerate(BONES):
            bad[:, IDX[c]] |= np.abs(L[:, k] - Lm[k]) > prm["bone_tol"] * Lm[k]
        # impossible speeds in both directions around a frame = a spike
        if T > 2:
            dt = np.maximum(np.diff(t), 1e-4)
            v = np.linalg.norm(np.diff(P, axis=0), axis=-1) / dt[:, None]
            spike = np.zeros((T, J), bool)
            spike[1:-1] = (v[:-1] > prm["vmax_ms"]) & (v[1:] > prm["vmax_ms"])
            bad |= spike
        if prm.get("conf_min", 0) > 0:
            low = has2d[:, None] & (np.nan_to_num(conf, nan=1.0) < prm["conf_min"])
            bad |= low
    bad[:, IDX["root"]] = False
    bad &= ~np.isnan(P).any(-1)
    return bad


def fill_gaps(P, t, bad, prm):
    """Bad and missing samples refilled when the gap is <= max_gap; longer gaps keep the original value."""
    P0 = P.copy()
    P = P.copy()
    T, J, _ = P.shape
    filled = 0
    for j in range(J):
        if ROLES[j] == "root":
            continue
        miss = np.isnan(P[:, j]).any(-1) | bad[:, j]
        if not miss.any() or (~miss).sum() < 2:
            continue
        valid = ~miss
        for d in range(3):
            P[:, j, d] = sc.interp_1d(t, np.where(valid, P[:, j, d], np.nan), valid, prm["method"])
        for a, b in sc.runs(miss):
            edge = a == 0 or b == T
            if (b - a) > prm["max_gap"] or edge:
                P[a:b, j] = P0[a:b, j]  # too long (or at the clip edge): keep what was recorded (or missing)
            else:
                filled += b - a
    # frames with no 3D at all stay root-relative: root at origin where anything exists
    anyj = ~np.isnan(P[:, 1:]).all(axis=(1, 2))
    P[anyj, IDX["root"]] = 0.0
    return P, filled


# ------------------------------------------------------------------ b) One Euro + Savitzky-Golay

def _alpha(fc, dt):
    tau = 1.0 / (2 * math.pi * fc)
    return 1.0 / (1.0 + tau / dt)


def one_euro_pass(X, t, mincut, beta, dcut):
    """Vector One Euro (Casiez 2012) per joint; X[T,J,D]; NaN samples reset the joint's state."""
    T = len(X)
    out = np.full_like(X, np.nan)
    xh = np.full(X.shape[1:], np.nan)
    dxh = np.zeros(X.shape[1:])
    for i in range(T):
        x = X[i]
        valid = ~np.isnan(x).any(-1)
        fresh = valid & np.isnan(xh).any(-1)
        xh[fresh] = x[fresh]
        dxh[fresh] = 0
        if i > 0:
            dt = max(t[i] - t[i - 1], 1e-4)
            run = valid & ~fresh
            ad = _alpha(dcut, dt)
            dx = (x - xh) / dt
            dxh[run] = ad * dx[run] + (1 - ad) * dxh[run]
            speed = np.linalg.norm(dxh, axis=-1)
            fc = mincut + beta * speed
            a = 1.0 / (1.0 + (1.0 / (2 * math.pi * fc)) / dt)
            xh[run] = a[run, None] * x[run] + (1 - a[run, None]) * xh[run]
        xh[~valid] = np.nan
        out[i] = xh
    return out


def one_euro(P, t, prm):
    f = one_euro_pass(P, t, prm["min_cutoff"], prm["beta"], prm["d_cutoff"])
    if not prm.get("zero_phase", True):
        return f
    tb = t[-1] - t[::-1]
    b = one_euro_pass(P[::-1], tb, prm["min_cutoff"], prm["beta"], prm["d_cutoff"])[::-1]
    return 0.5 * (f + b)


def savgol_step(P, prm):
    out = P.copy()
    T = len(P)
    w = int(prm["window"]) | 1
    if T < w + 2:
        return out
    for j in range(P.shape[1]):
        col = P[:, j]
        ok = ~np.isnan(col).any(-1)
        for a, b in sc.runs(ok):
            if b - a >= w:
                out[a:b, j] = sc.savgol(col[a:b], w, int(prm["poly"]))
    return out


# ------------------------------------------------------------------ c) bones

def enforce_bones(P, L):
    """Re-project every child along its measured direction at its fixed length, root outward."""
    out = P.copy()
    for k, (p, c) in enumerate(BONES):
        d = sc.unit(P[:, IDX[c]] - P[:, IDX[p]])
        out[:, IDX[c]] = out[:, IDX[p]] + L[k] * d
    return out


# ------------------------------------------------------------------ d) hinge limits

def _rotate(v, axis, ang):
    """Rodrigues: rotate v[N,3] about unit axis[N,3] by ang[N]."""
    c, s = np.cos(ang)[:, None], np.sin(ang)[:, None]
    return v * c + np.cross(axis, v) * s + axis * np.sum(axis * v, -1, keepdims=True) * (1 - c)


def hinge_limits(P, prm):
    P = P.copy()
    T = len(P)
    counts = {}
    lat = sc.unit(P[:, IDX["leftHip"]] - P[:, IDX["rightHip"]])
    limbs = [("left", "Hip", "Knee", "Ankle", "knee"), ("right", "Hip", "Knee", "Ankle", "knee"),
             ("left", "Shoulder", "Elbow", "Wrist", "elbow"), ("right", "Shoulder", "Elbow", "Wrist", "elbow")]
    for side, a, b, c, kind in limbs:
        A, B, C = (IDX[side + a], IDX[side + b], IDX[side + c])
        u = P[:, B] - P[:, A]
        v = P[:, C] - P[:, B]
        ok = ~(np.isnan(u).any(-1) | np.isnan(v).any(-1))
        if ok.sum() < 3:
            continue
        cosb = np.sum(sc.unit(u) * sc.unit(v), -1)
        bend = np.degrees(np.arccos(np.clip(cosb, -1, 1)))
        n = sc.unit(np.cross(u, v))
        refm = ok & (bend > prm["ref_bend_deg"])
        if kind == "knee" and refm.any():
            sgn = np.sign(np.sum(n * lat, -1))
            major = np.sign(np.nansum(sgn[refm])) or 1.0
            refm &= sgn == major
        if refm.sum() < 2:
            continue
        nref = np.empty_like(n)
        for d in range(3):
            nref[:, d] = sc.interp_1d(np.arange(T, dtype=float), np.where(refm, n[:, d], np.nan), refm, "linear")
        nref = sc.unit(nref)
        # signed angle of the lower limb about the reference hinge axis, in the plane normal to it
        up_ = u - nref * np.sum(u * nref, -1, keepdims=True)
        vp_ = v - nref * np.sum(v * nref, -1, keepdims=True)
        planar = (np.linalg.norm(up_, axis=-1) > 0.5 * np.linalg.norm(u, axis=-1)) & \
                 (np.linalg.norm(vp_, axis=-1) > 0.5 * np.linalg.norm(v, axis=-1))
        ang = np.degrees(np.arctan2(np.sum(nref * np.cross(up_, vp_), -1), np.sum(up_ * vp_, -1)))
        hyper, mx = prm[kind + "_hyper_deg"], prm[kind + "_max_deg"]
        viol = ok & planar & ((ang < -hyper) | (ang > mx))
        # a short run of wrong bends is a tracking error: rebuild the lower limb from the frames around it
        nre = 0
        for s_, e_ in sc.runs(viol):
            if e_ - s_ <= prm.get("reinterp_frames", 8) and s_ > 0 and e_ < T:
                good = ok & ~viol
                tt = np.arange(T, dtype=float)
                lv = np.linalg.norm(v[s_:e_], axis=-1, keepdims=True)
                vi = np.stack([sc.interp_1d(tt, np.where(good, v[:, d], np.nan), good, "pchip")[s_:e_]
                               for d in range(3)], -1)
                v[s_:e_] = sc.unit(vi) * lv
                P[s_:e_, C] = P[s_:e_, B] + v[s_:e_]
                nre += e_ - s_
        if nre:
            vp_ = v - nref * np.sum(v * nref, -1, keepdims=True)
            ang = np.degrees(np.arctan2(np.sum(nref * np.cross(up_, vp_), -1), np.sum(up_ * vp_, -1)))
        target = np.clip(ang, -hyper, mx)
        fix = ok & planar & (np.abs(target - ang) > 1e-6)
        counts[side + b + "_rebuilt"] = nre
        counts[side + b + "_frames"] = [int(i) for i in np.where(viol)[0]][:200]
        if fix.any():
            delta = np.radians(target[fix] - ang[fix])
            v2 = _rotate(v[fix], nref[fix], delta)
            P[fix, C] = P[fix, B] + v2
        counts[side + b] = int(fix.sum())
    counts = {k: v for k, v in counts.items() if v}
    return P, counts


# ------------------------------------------------------------------ e) world root, contacts, foot lock

def estimate_world_root(clip, P):
    """Root travel in metres from the 2D root track (camera plane only; depth unknown = 0)."""
    if clip.has2d.mean() < 0.5:
        return None
    W, H = float(clip.doc.get("width", 1920)), float(clip.doc.get("height", 1080))
    px = clip.p2[..., 0] * W
    py = clip.p2[..., 1] * H
    # metres per pixel and axis signs from segments seen in both 2D and 3D
    segs = [("leftShoulder", "rightShoulder"), ("leftHip", "rightHip"), ("leftHip", "leftAnkle"),
            ("rightHip", "rightAnkle"), ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip")]
    ratios, sx, sy = [], [], []
    for a, b in segs:
        d2x = px[:, IDX[a]] - px[:, IDX[b]]
        d2y = py[:, IDX[a]] - py[:, IDX[b]]
        d3 = P[:, IDX[a]] - P[:, IDX[b]]
        l2 = np.hypot(d2x, d2y)
        l3 = np.linalg.norm(d3[:, :2], axis=-1)
        m = np.isfinite(l2) & np.isfinite(l3) & (l2 > 5)
        ratios += list(l3[m] / l2[m])
        sx += list(np.sign(d2x[m] * d3[m, 0]))
        sy += list(np.sign(d2y[m] * d3[m, 1]))
    if len(ratios) < 10:
        return None
    s = float(np.median(ratios))
    signx = 1.0 if np.mean(sx) >= 0 else -1.0
    signy = 1.0 if np.mean(sy) >= 0 else -1.0
    rx, ry = px[:, IDX["root"]], py[:, IDX["root"]]
    ok = np.isfinite(rx) & np.isfinite(ry)
    if ok.sum() < 3:
        return None
    t = clip.t
    rx = sc.interp_1d(t, rx, ok, "linear")
    ry = sc.interp_1d(t, ry, ok, "linear")
    rw = np.zeros((clip.T, 3))
    rw[:, 0] = signx * (rx - rx[ok][0]) * s
    rw[:, 1] = signy * (ry - ry[ok][0]) * s
    return rw


def detect_contacts(P, t, rw, prm):
    W = sc.world(P, rw)
    res, floor = {}, None
    hs = np.concatenate([W[:, IDX["leftAnkle"], sc.UP], W[:, IDX["rightAnkle"], sc.UP]])
    hs = hs[np.isfinite(hs)]
    if not len(hs):
        return {"left": np.zeros(len(P), bool), "right": np.zeros(len(P), bool)}, None
    floor = float(np.percentile(hs, 2))
    dt = np.maximum(np.gradient(t), 1e-4)
    for side in ("left", "right"):
        a = W[:, IDX[side + "Ankle"]]
        v = np.linalg.norm(np.gradient(a, axis=0), axis=-1) / dt
        c = (a[:, sc.UP] - floor < prm["height_m"]) & (v < prm["speed_ms"])
        c = np.nan_to_num(c, nan=0).astype(bool)
        for s, e in sc.runs(~c):  # close holes of 1-2 frames
            if 0 < s and e < len(c) and e - s <= 2:
                c[s:e] = True
        for s, e in sc.runs(c):
            if e - s < prm["min_frames"]:
                c[s:e] = False
        res[side] = c
    return res, floor


def root_depth_from_contacts(P, contact, decay=0.9):
    T = len(P)
    z = np.zeros(T)
    vel = 0.0
    for i in range(1, T):
        d = [-(P[i, IDX[s + "Ankle"], 2] - P[i - 1, IDX[s + "Ankle"], 2]) for s in ("left", "right")
             if contact[s][i] and contact[s][i - 1] and np.isfinite(P[i, IDX[s + "Ankle"], 2])
             and np.isfinite(P[i - 1, IDX[s + "Ankle"], 2])]
        vel = float(np.mean(d)) if d else vel * decay
        z[i] = z[i - 1] + vel
    return z


def two_bone_ik(H, K, A_target, l1, l2):
    """Knee and ankle for hips H[N,3], knee hints K[N,3], ankle targets; lengths fixed."""
    d = A_target - H
    dist = np.linalg.norm(d, axis=-1)
    dist_c = np.clip(dist, abs(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
    e = sc.unit(d)
    A = H + e * dist_c[:, None]
    pole = K - H
    pole = pole - e * np.sum(pole * e, -1, keepdims=True)
    pole = sc.unit(pole)
    cosa = np.clip((l1 ** 2 + dist_c ** 2 - l2 ** 2) / (2 * l1 * dist_c), -1, 1)
    sina = np.sqrt(1 - cosa ** 2)
    Kn = H + l1 * (e * cosa[:, None] + pole * sina[:, None])
    return Kn, A


def lock_feet(P, t, rw, L, prm, world_mode):
    P = P.copy()
    rw = None if rw is None else rw.copy()
    contact, floor = detect_contacts(P, t, rw, prm)
    T = len(P)
    if world_mode and rw is not None and not np.any(rw[:, 2]):
        # depth is invisible in 2D: the root's z travel is taken from the planted feet (a planted foot does not
        # move in the world, so the root moves opposite to it in root-relative space)
        rw[:, 2] = root_depth_from_contacts(P, contact)
        contact, floor = detect_contacts(P, t, rw, prm)
    drift_max = prm["max_drift_world_m"] if world_mode else prm["max_drift_rel_m"]
    W = sc.world(P, rw)
    # the 2D track gives the root's travel in the camera plane only: depth (z) is not locked in world mode
    # (unless the depth was rebuilt from the contacts just above)
    depth_ok = rw is None or np.any(rw[:, 2])
    axes = np.array(prm.get("lock_axes") or ([0, 1, 2] if depth_ok else [0, 1]))
    weights, targets = {}, {}
    for side in ("left", "right"):
        a = W[:, IDX[side + "Ankle"]]
        w = np.zeros(T)
        tgt = np.full((T, 3), np.nan)
        keep = np.zeros(T, bool)
        for s, e in sc.runs(contact[side]):
            seg = a[s:e]
            med = np.nanmedian(seg, axis=0)
            if np.nanmax(np.linalg.norm((seg - med)[:, axes], axis=-1)) > drift_max:
                continue  # the foot really travels (or the root does): not a plant
            keep[s:e] = True
            nb = prm["blend"]
            lo, hi = max(0, s - nb), min(T, e + nb)
            for i in range(lo, hi):
                if i < s:
                    x = (i - lo + 1) / (s - lo + 1)
                elif i >= e:
                    x = (hi - i) / (hi - e + 1)
                else:
                    x = 1.0
                x = x * x * (3 - 2 * x)
                if x > w[i]:
                    w[i] = x
                    tgt[i] = med
        contact[side] = keep
        weights[side], targets[side] = w, tgt
    # both feet planted and drifting the same way: that is root drift, move the (world) root
    if rw is not None and prm["root_share"] > 0:
        both = (weights["left"] > 0.99) & (weights["right"] > 0.99)
        if both.any():
            dl = targets["left"] - W[:, IDX["leftAnkle"]]
            dr = targets["right"] - W[:, IDX["rightAnkle"]]
            shift = prm["root_share"] * 0.5 * (dl + dr)
            sel = np.zeros(3, bool)
            sel[axes] = True
            shift[:, ~sel] = 0
            rw[both] += shift[both]
    locked = 0
    names = [c for _, c in BONES]
    for side in ("left", "right"):
        w = weights[side]
        m = w > 0
        if not m.any():
            continue
        Hh, Kk, Aa = IDX[side + "Hip"], IDX[side + "Knee"], IDX[side + "Ankle"]
        R = np.zeros((T, 3)) if rw is None else rw
        cur = P[:, Aa]
        want_rel = targets[side] - R
        free = np.setdiff1d(np.arange(3), axes)
        want_rel[:, free] = cur[:, free]
        goal = cur.copy()
        goal[m] = cur[m] + w[m, None] * (want_rel[m] - cur[m])
        l1 = L[names.index(side + "Knee")]
        l2 = L[names.index(side + "Ankle")]
        Kn, An = two_bone_ik(P[m, Hh], P[m, Kk], goal[m], l1, l2)
        P[m, Kk], P[m, Aa] = Kn, An
        locked += int((w > 0.99).sum())
    return P, rw, contact, floor, locked


# ------------------------------------------------------------------ f) root + speed limits

def limit_speeds(X, t, vmax, amax=None, protect=None):
    """Samples moving faster than vmax (or accelerating beyond amax) are removed and refilled (PCHIP)."""
    X = X.copy()
    T = len(X)
    if T < 4:
        return X, 0
    dt = np.maximum(np.diff(t), 1e-4)
    single = X.ndim == 2
    Y = X[:, None, :] if single else X
    n = 0
    for j in range(Y.shape[1]):
        if protect is not None and j in protect:
            continue
        col = Y[:, j]
        v = np.linalg.norm(np.diff(col, axis=0), axis=-1) / dt
        bad = np.zeros(T, bool)
        bad[1:] |= v > vmax
        if amax is not None:
            vv = np.diff(col, axis=0) / dt[:, None]
            acc = np.linalg.norm(np.diff(vv, axis=0), axis=-1) / dt[1:]
            bad[1:-1] |= acc > amax
        bad &= ~np.isnan(col).any(-1)
        if bad.any() and (~bad).sum() >= 3:
            for d in range(col.shape[1]):
                col[:, d] = sc.interp_1d(t, np.where(bad, np.nan, col[:, d]), ~bad & ~np.isnan(col[:, d]), "pchip")
            n += int(bad.sum())
        Y[:, j] = col
    return (Y[:, 0] if single else Y), n


# ------------------------------------------------------------------ holds + rekey

def make_holds(P, t, prm):
    P = P.copy()
    T = len(P)
    dt = np.maximum(np.gradient(t), 1e-4)
    sp = np.nanmean(np.linalg.norm(np.gradient(P, axis=0), axis=-1), axis=1) / dt
    sp = np.convolve(np.nan_to_num(sp, nan=9), np.ones(5) / 5, mode="same")
    holds = []
    for s, e in sc.runs(sp < prm["speed_ms"]):
        if t[e - 1] - t[s] < prm["min_s"]:
            continue
        pose = np.nanmedian(P[s:e], axis=0)
        nb = min(int(prm["blend"]), (e - s) // 3)
        for i in range(s, e):
            x = min(1.0, (i - s + 1) / (nb + 1), (e - i) / (nb + 1)) if nb > 0 else 1.0
            x = x * x * (3 - 2 * x) * prm["strength"]
            P[i] = P[i] + x * (pose - P[i])
        holds.append((int(s), int(e)))
    return P, holds


def rdp_keys(X, tol):
    """Ramer-Douglas-Peucker on a pose trajectory X[T,D]: indices whose removal would exceed tol (per joint)."""
    T = len(X)
    J = X.shape[1] // 3
    keep = np.zeros(T, bool)
    keep[0] = keep[-1] = True
    stack = [(0, T - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        s = (np.arange(a + 1, b) - a) / (b - a)
        lin = X[a] + s[:, None] * (X[b] - X[a])
        err = np.linalg.norm((X[a + 1:b] - lin).reshape(-1, J, 3), axis=-1).max(axis=1)
        k = int(np.argmax(err))
        if err[k] > tol:
            m = a + 1 + k
            keep[m] = True
            stack += [(a, m), (m, b)]
    return np.where(keep)[0]


def rekey(P, t, prm):
    ok = ~np.isnan(P).any(axis=(1, 2))
    if ok.sum() < 4:
        return P, []
    idx = np.where(ok)[0]
    X = P[idx].reshape(len(idx), -1)
    keys = idx[rdp_keys(X, prm["tol_m"])]
    out = P.copy()
    valid = np.zeros(len(P), bool)
    valid[keys] = True
    for j in range(P.shape[1]):
        for d in range(3):
            col = sc.interp_1d(t, np.where(valid, P[:, j, d], np.nan), valid, "pchip")
            out[ok, j, d] = col[ok]
    return out, [int(k) for k in keys]


# ------------------------------------------------------------------ the pipeline

def clean(clip, prm):
    t = clip.t
    P = clip.P.copy()
    log = []
    info = {}
    if prm["swaps"]["on"]:
        P, fx = fix_swaps(P, prm["swaps"])
        log.append({"step": "swaps", "frames_fixed": len(fx), "frames": [f for f, _ in fx][:200]})
    if prm["outliers"]["on"]:
        bad = find_outliers(P, t, clip.conf, clip.has2d, prm["outliers"])
        log.append({"step": "outliers", "samples_rejected": int(bad.sum())})
    else:
        bad = np.zeros(P.shape[:2], bool)
    if prm["gaps"]["on"] or bad.any():
        g = dict(prm["gaps"])
        if not prm["gaps"]["on"]:
            g["max_gap"] = 0
        P, nfill = fill_gaps(P, t, bad, g)
        log.append({"step": "gaps", "samples_filled": nfill, "max_gap": g["max_gap"]})
    if prm["limits"]["on"]:
        # first pass on the unfiltered track: a wrong bend is rebuilt before the filter can smear it
        P, cnt0 = hinge_limits(P, prm["limits"])
        log.append({"step": "limits-raw", "frames_clamped": cnt0})
    if prm["oneeuro"]["on"]:
        P = one_euro(P, t, prm["oneeuro"])
        P[:, IDX["root"]] = np.where(np.isnan(P[:, IDX["root"]]), np.nan, 0.0)
        log.append({"step": "oneeuro", **{k: v for k, v in prm["oneeuro"].items() if k != "on"}})
    if prm["savgol"]["on"]:
        P = savgol_step(P, prm["savgol"])
        log.append({"step": "savgol", "window": prm["savgol"]["window"], "poly": prm["savgol"]["poly"]})
    L = sc.median_bone_lengths(P, prm["bones"].get("symmetric", True))
    info["bone_lengths_m"] = {f"{p}-{c}": round(float(L[k]), 4) for k, (p, c) in enumerate(BONES)}
    if prm["bones"]["on"]:
        P = enforce_bones(P, L)
        log.append({"step": "bones"})
    if prm["limits"]["on"]:
        P, cnt = hinge_limits(P, prm["limits"])
        log.append({"step": "limits", "frames_clamped": cnt})
    if prm["holds"]["on"]:
        P, holds = make_holds(P, t, prm["holds"])
        log.append({"step": "holds", "holds": [[float(t[s]), float(t[e - 1])] for s, e in holds]})
    if prm["rekey"]["on"]:
        P, keys = rekey(P, t, prm["rekey"])
        log.append({"step": "rekey", "tol_m": prm["rekey"]["tol_m"], "keys": len(keys)})
    rw = clip.rw
    world_mode = False
    if prm["feet"]["on"] or prm["root"]["on"]:
        wm = prm["feet"]["world"]
        if rw is None and wm in ("auto", "p2"):
            rw = estimate_world_root(clip, P)
        if wm == "none":
            rw = None
        world_mode = rw is not None
        if rw is not None and prm["oneeuro"]["on"]:
            o = prm["oneeuro"]
            rw = one_euro(rw[:, None, :], t, {**o, "min_cutoff": o["min_cutoff"] * 0.7})[:, 0]
    contact = None
    if prm["feet"]["on"]:
        P, rw, contact, floor, nl = lock_feet(P, t, rw, L, prm["feet"], world_mode)
        info["floor_y_m"] = None if floor is None else round(floor, 4)
        log.append({"step": "feet", "world": "p2-estimate" if world_mode else "root-relative",
                    "frames_locked": nl,
                    "contact_frames": {s: int(c.sum()) for s, c in contact.items()}})
    if prm["root"]["on"]:
        n_root = 0
        if rw is not None:
            rw, n_root = limit_speeds(rw, t, prm["root"]["vmax_ms"], prm["root"]["amax_ms2"])
        P, n_j = limit_speeds(P, t, prm["root"]["joint_vmax_ms"], protect={IDX["root"]})
        log.append({"step": "root", "root_samples_fixed": n_root, "joint_samples_fixed": n_j})
    if prm["bones"]["on"]:
        P = enforce_bones(P, L)
    return P, rw, contact, log, info


def report_md(rep):
    b, a = rep["before"], rep["after"]
    lines = [f"# Cleanup report: {rep['input']}", "",
             f"Preset **{rep['preset']}**, {rep['frames']} frames, {rep['fps']:.1f} fps, skelclean v{VERSION}.", "",
             "| metric | before | after |", "|---|---|---|",
             f"| jitter, mean joint acceleration (m/s^2) | {b['jitter_mean_ms2']:.2f} | {a['jitter_mean_ms2']:.2f} |",
             f"| bone length spread, mean std (cm) | {b['bone_std_mean_cm']:.2f} | {a['bone_std_mean_cm']:.2f} |"]
    if "foot_slide_total_cm" in b:
        lines.append(f"| foot sliding during contact (cm) | {b['foot_slide_total_cm']:.1f} | {a['foot_slide_total_cm']:.1f} |")
    lines += ["", "## Steps", ""]
    for s in rep["steps"]:
        lines.append("- " + ", ".join(f"{k}: {v}" for k, v in s.items() if k != "frames"))
    lines += ["", "## Jitter per joint (m/s^2)", "", "| joint | before | after |", "|---|---|---|"]
    for j, v in b["jitter_per_joint_ms2"].items():
        lines.append(f"| {j} | {v:.2f} | {a['jitter_per_joint_ms2'].get(j, float('nan')):.2f} |")
    return "\n".join(lines) + "\n"


def run(inp, out, preset="standard", sets=(), skip=(), only=None, report=None):
    clip = sc.load(inp)
    prm = params_for(preset, sets, skip, only)
    P, rw, contact, log, info = clean(clip, prm)
    if contact is None:
        contact, _ = detect_contacts(P, clip.t, rw, BASE["feet"])
    rw_before = clip.rw if clip.rw is not None else (estimate_world_root(clip, clip.P) if rw is not None else None)
    rep = {"input": os.path.basename(inp), "preset": preset, "frames": clip.T, "fps": clip.fps,
           "before": sc.summary(clip.P, clip.t, contact, rw_before),
           "after": sc.summary(P, clip.t, contact, rw), "steps": log, **info}
    meta = {"cleanup": {"tool": f"skelclean v{VERSION}", "preset": preset,
                        "steps": [s["step"] for s in log],
                        "params": {k: v for k, v in prm.items() if v.get("on")},
                        "bone_lengths_m": info.get("bone_lengths_m"),
                        "rw": "frames[].rw = estimated world root (m, camera plane)" if rw is not None else None,
                        "r3_dropped": True,
                        "metrics": {"jitter_ms2": [rep["before"]["jitter_mean_ms2"], rep["after"]["jitter_mean_ms2"]],
                                    "bone_std_cm": [rep["before"]["bone_std_mean_cm"], rep["after"]["bone_std_mean_cm"]],
                                    "foot_slide_cm": [rep["before"].get("foot_slide_total_cm"),
                                                      rep["after"].get("foot_slide_total_cm")]}}}
    doc = clip.to_doc(P, rw=rw, extra=meta)
    if out:
        sc.save(doc, out)
    if report:
        if report.endswith(".json"):
            with open(report, "w") as fh:
                json.dump(rep, fh, indent=1)
        else:
            with open(report, "w") as fh:
                fh.write(report_md(rep))
    return doc, rep


def main(argv=None):
    ap = argparse.ArgumentParser(prog="skelclean", description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("input")
    ap.add_argument("-o", "--output", help="cleaned file (default: <input>.clean.skel.json)")
    ap.add_argument("--preset", default="standard", choices=list(PRESETS))
    ap.add_argument("--set", action="append", default=[], metavar="STEP.KEY=VALUE")
    ap.add_argument("--skip", action="append", default=[], choices=ORDER)
    ap.add_argument("--only", action="append", choices=ORDER)
    ap.add_argument("--report", nargs="?", const="", default=None,
                    help="write a report (.md or .json); no value = <output>.report.md")
    ap.add_argument("--print-params", action="store_true")
    a = ap.parse_args(argv)
    if a.print_params:
        print(json.dumps(params_for(a.preset, a.set, a.skip, a.only), indent=1))
        return 0
    out = a.output or (a.input[:-len(".skel.json")] if a.input.endswith(".skel.json") else a.input) + ".clean.skel.json"
    rep_path = a.report
    if rep_path == "":
        rep_path = (out[:-len(".skel.json")] if out.endswith(".skel.json") else out) + ".report.md"
    _, rep = run(a.input, out, a.preset, a.set, a.skip, a.only, rep_path)
    b, f = rep["before"], rep["after"]
    print(f"skelclean {a.preset}: {rep['frames']} frames -> {out}")
    print(f"  jitter {b['jitter_mean_ms2']:.2f} -> {f['jitter_mean_ms2']:.2f} m/s^2, "
          f"bone std {b['bone_std_mean_cm']:.2f} -> {f['bone_std_mean_cm']:.2f} cm, "
          f"foot slide {b.get('foot_slide_total_cm', 0):.1f} -> {f.get('foot_slide_total_cm', 0):.1f} cm")
    if rep_path:
        print(f"  report {rep_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
