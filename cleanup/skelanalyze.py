"""skelanalyze: find the problems in a recording, with frame numbers (used by export_for_claude and the prompts).

Problems: jitter spikes, outliers (Hampel), bone-length errors, left/right swaps, knee/elbow wrong bends,
foot sliding during contact, gaps, holds (still stretches). Nothing is changed.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skelcore as sc  # noqa: E402
import skelclean as k  # noqa: E402
from skelcore import IDX, ROLES, BONES  # noqa: E402


def ranges(frames, gap=1):
    """[3,4,5,9] -> [[3,5],[9,9]]"""
    out = []
    for f in sorted(set(int(x) for x in frames)):
        if out and f - out[-1][1] <= gap:
            out[-1][1] = f
        else:
            out.append([f, f])
    return out


def analyze(clip, prm=None):
    prm = prm or k.params_for("standard")
    P, t = clip.P, clip.t
    T = clip.T
    flags = {}
    # gaps
    miss = {r: ranges(np.where(np.isnan(P[:, IDX[r]]).any(-1))[0]) for r in ROLES if r != "root"}
    flags["missing"] = {r: v for r, v in miss.items() if v}
    # swaps (on the raw track)
    _, sw = k.fix_swaps(P, prm["swaps"])
    flags["swaps"] = [{"frames": r, "part": p} for r, p in
                      [(rr, next(pp for f, pp in sw if f == rr[0])) for rr in ranges([f for f, _ in sw])]]
    # outliers
    bad = k.find_outliers(P, t, clip.conf, clip.has2d, {**prm["outliers"], "k": 6.0, "min_dev_m": 0.10,
                                                                 "bone_tol": 0.5})
    flags["outliers"] = {ROLES[j]: ranges(np.where(bad[:, j])[0]) for j in range(len(ROLES)) if bad[:, j].any()}
    # jitter spikes: acceleration over 4x the joint's median
    with np.errstate(all="ignore"):
        if T > 3:
            dt = np.maximum(np.diff(t), 1e-4)
            v = np.diff(P, axis=0) / dt[:, None, None]
            a = np.linalg.norm(np.diff(v, axis=0), axis=-1) / ((dt[1:] + dt[:-1]) / 2)[:, None]
            med = np.nanmedian(a, axis=0)
            sp = {}
            for j in range(1, len(ROLES)):
                f = np.where(a[:, j] > 4 * max(med[j], 1e-6))[0] + 1
                if len(f):
                    sp[ROLES[j]] = ranges(f)
            flags["jitter_spikes"] = sp
        # bone-length errors over 12 % of the median and 3 cm
        L = sc.bone_lengths(P)
        Lm = np.nanmedian(L, axis=0)
        be = {}
        for b, (p_, c) in enumerate(BONES):
            f = np.where(np.abs(L[:, b] - Lm[b]) > max(0.12 * Lm[b], 0.03))[0]
            if len(f):
                be[f"{p_}-{c}"] = ranges(f)
        flags["bone_length_errors"] = be
        flags["median_bone_mm"] = {f"{p_}-{c}": int(round(Lm[b] * 1000)) for b, (p_, c) in enumerate(BONES)}
    # wrong bends, on a lightly filtered track so noise around a straight limb is not counted
    Pf, _ = k.fill_gaps(P, t, np.zeros(P.shape[:2], bool), prm["gaps"])
    Ps = k.one_euro(Pf, t, {**prm["oneeuro"], "min_cutoff": 3.0})
    _, cnt = k.hinge_limits(Ps, prm["limits"])
    flags["wrong_bends"] = {key[:-7]: ranges(v) for key, v in cnt.items() if key.endswith("_frames") and v}
    # foot sliding: contact detected on the filtered track, ankle moving more than 5 mm per frame meanwhile
    Ps = k.one_euro(Pf, t, prm["oneeuro"])
    rw = clip.rw if clip.rw is not None else k.estimate_world_root(clip, Ps)
    if rw is not None:
        rw = k.one_euro(rw[:, None, :], t, prm["oneeuro"])[:, 0]
    contact, floor = k.detect_contacts(Ps, t, rw, {**prm["feet"], "speed_ms": 0.35})
    if rw is not None and clip.rw is None:
        rw[:, 2] = k.root_depth_from_contacts(Ps, contact)
    W = sc.world(Ps, rw)
    slide = {}
    for side in ("left", "right"):
        c = contact[side]
        d = np.zeros(T)
        d[1:] = np.linalg.norm(np.diff(W[:, IDX[side + "Ankle"]][:, [0, 2]], axis=0), axis=-1)
        f = np.where(c & (d > 0.005))[0]
        if len(f):
            slide[side] = [r for r in ranges(f, gap=2) if r[1] - r[0] >= 2]
        flags.setdefault("contacts", {})[side] = ranges(np.where(c)[0])
    flags["foot_slide"] = slide
    flags["floor_y_mm"] = None if floor is None else int(round(floor * 1000))
    # holds
    Ph = k.one_euro(Pf, t, {**prm["oneeuro"], "min_cutoff": 0.4, "beta": 2.0})
    _, holds = k.make_holds(Ph, t, prm["holds"])
    flags["holds"] = [[int(s), int(e - 1)] for s, e in holds]
    flags["metrics"] = sc.summary(P, t, contact, rw)
    return flags
