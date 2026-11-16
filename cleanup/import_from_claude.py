#!/usr/bin/env python3
"""import_from_claude: apply Claude's cleanup answer to the recording, after checking it.

    python3 cleanup/import_from_claude.py rec.skel.json reply.md -o rec.claude.skel.json [--repair] [--force] [--report r.md]

reply.md is Claude's answer pasted into a file (or the .json patch alone). Read: the ```json block with
"format": "skelclaude-patch/1" (operations, docs/claude-cleanup-format.md), or else whole "### <joint>" CSV tables.
Checked before anything is written: joint names, frame ranges, NaN, bone lengths (every CHANGED frame keeps each bone
within 10 % or 20 mm of the clip's median, or no worse than it was), speeds (15 m/s), the source_sha.
--repair restores the bone lengths instead of rejecting. Exit code 2 = rejected, nothing written.
"""
import argparse
import copy
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skelcore as sc  # noqa: E402
import skelclean as k  # noqa: E402
from export_for_claude import PATCH_FORMAT, sha  # noqa: E402
from skelcore import IDX, ROLES, BONES, LR_PAIRS  # noqa: E402

BONE_TOL_REL, BONE_TOL_ABS, VMAX = 0.10, 0.020, 15.0


class Rejected(Exception):
    pass


# ------------------------------------------------------------------ parsing

def parse_reply(text):
    """-> ("patch", dict) or ("tables", {joint: {frame: xyz_mm}})"""
    blocks = re.findall(r"```(?:json)?\s*\n(.*?)```", text, re.S)
    for b in blocks + [text]:
        b = b.strip()
        if not b.startswith("{"):
            continue
        try:
            d = json.loads(b)
        except ValueError:
            continue
        if isinstance(d, dict) and "ops" in d:
            return "patch", d
        if isinstance(d, dict) and "problems" in d:
            return "analysis", d
    tables = {}
    data = text.split("## Data", 1)[1] if "## Data" in text else text
    for m in re.finditer(r"###\s+(\w+)[^\n]*\n```(?:csv)?\s*\n(.*?)```", data, re.S):
        name, body = m.group(1), m.group(2)
        if name not in IDX or name == "root":
            continue
        rows = {}
        for line in body.strip().splitlines()[1:]:
            parts = line.strip().split(",")
            if len(parts) >= 4:
                try:
                    rows[int(parts[0])] = [float(x) for x in parts[1:4]]
                except ValueError:
                    raise Rejected(f"table {name}: bad row {line!r}")
        tables[name] = rows
    if tables:
        return "tables", tables
    raise Rejected("no skelclaude-patch/1 JSON block and no joint tables found in the reply")


# ------------------------------------------------------------------ helpers

def joints_of(op):
    j = op.get("joints", "all")
    if j == "all" or j is None:
        return [r for r in ROLES if r != "root"]
    if isinstance(j, str):
        j = [j]
    for r in j:
        if r not in IDX or r == "root":
            raise Rejected(f"unknown joint {r!r}")
    return list(j)


def rng(op, T):
    a, b = int(op.get("from", 0)), int(op.get("to", T - 1))
    if not (0 <= a <= b < T):
        raise Rejected(f"range {a}..{b} outside 0..{T - 1} in {op.get('op')}")
    return a, b


def edge_weights(T, a, b, nb):
    """1 on a..b, smooth ramps over nb frames outside."""
    w = np.zeros(T)
    w[a:b + 1] = 1
    for i in range(1, nb + 1):
        x = 1 - i / (nb + 1)
        x = x * x * (3 - 2 * x)
        if a - i >= 0:
            w[a - i] = x
        if b + i < T:
            w[b + i] = x
    return w


def blend(P, Pn, w, js):
    out = P.copy()
    for r in js:
        j = IDX[r]
        m = ~np.isnan(Pn[:, j]).any(-1) & (w > 0)
        out[m, j] = P[m, j] + w[m, None] * (Pn[m, j] - P[m, j])
    return out


EASE = {"linear": lambda u: u, "smoothstep": lambda u: u * u * (3 - 2 * u), "ease_in": lambda u: u * u,
        "ease_out": lambda u: 1 - (1 - u) ** 2, "min_jerk": lambda u: 10 * u ** 3 - 15 * u ** 4 + 6 * u ** 5}


# ------------------------------------------------------------------ operations

def op_pipeline(clip, P, rw, op, T):
    c2 = copy.copy(clip)
    c2.P = P.copy()
    c2.rw = rw
    sets = [f"{kk}={json.dumps(v)}" for kk, v in (op.get("set") or {}).items()]
    prm = k.params_for(op.get("preset", "standard"), sets, op.get("skip") or [])
    Pn, rwn, _, log, _ = k.clean(c2, prm)
    if "from" in op or "to" in op:
        a, b = rng(op, T)
        return blend(P, Pn, edge_weights(T, a, b, 4), joints_of({})), rw, log
    return Pn, rwn, log


def op_smooth(clip, P, op, T):
    a, b = rng(op, T)
    js = joints_of(op)
    lo, hi = max(0, a - 15), min(T, b + 16)
    o = {"min_cutoff": float(op.get("min_cutoff", 1.0)), "beta": float(op.get("beta", 4.0)), "d_cutoff": 1.0,
         "zero_phase": True}
    Pn = np.full_like(P, np.nan)
    Pn[lo:hi] = k.one_euro(P[lo:hi], clip.t[lo:hi], o)
    return blend(P, Pn, edge_weights(T, a, b, int(op.get("blend", 3))), js)


def _rebuild(P, t, js, drop, method="pchip"):
    out = P.copy()
    for r in js:
        j = IDX[r]
        valid = ~drop & ~np.isnan(P[:, j]).any(-1)
        for d in range(3):
            out[:, j, d] = sc.interp_1d(t, np.where(valid, P[:, j, d], np.nan), valid, method)
    return out


def op_interpolate(clip, P, op, T):
    a, b = rng(op, T)
    drop = np.zeros(T, bool)
    drop[a + 1:b] = True
    return _rebuild(P, clip.t, joints_of(op), drop, op.get("method", "pchip"))


def op_keys(clip, P, op, T):
    a, b = rng(op, T)
    keys = set(int(x) for x in op.get("keys", []))
    if any(not (a <= x <= b) for x in keys):
        raise Rejected("keys outside their range")
    drop = np.zeros(T, bool)
    drop[a:b + 1] = True
    for x in keys | {a, b}:
        drop[x] = False
    return _rebuild(P, clip.t, joints_of(op), drop)


def op_hold(clip, P, op, T):
    a, b = rng(op, T)
    js = joints_of(op)
    pose = np.nanmedian(P[a:b + 1], axis=0)
    Pn = np.repeat(pose[None], T, axis=0)
    nb = int(op.get("blend", 6))
    w = np.zeros(T)
    for i in range(a, b + 1):
        x = min(1.0, (i - a + 1) / (nb + 1), (b - i + 1) / (nb + 1)) if nb else 1.0
        w[i] = x * x * (3 - 2 * x)
    return blend(P, Pn, w, js)


def op_lock_foot(clip, P, rw, op, T, L):
    side = op.get("side")
    if side not in ("left", "right"):
        raise Rejected("lock_foot needs side left or right")
    a, b = rng(op, T)
    R = np.zeros((T, 3)) if rw is None else rw
    W = P[:, IDX[side + "Ankle"]] + R
    target = np.nanmedian(W[a:b + 1], axis=0)
    w = edge_weights(T, a, b, int(op.get("blend", 4)))
    m = w > 0
    cur = P[:, IDX[side + "Ankle"]]
    goal = cur[m] + w[m, None] * ((target - R[m]) - cur[m])
    names = [c for _, c in BONES]
    Kn, An = k.two_bone_ik(P[m, IDX[side + "Hip"]], P[m, IDX[side + "Knee"]], goal,
                           L[names.index(side + "Knee")], L[names.index(side + "Ankle")])
    P = P.copy()
    P[m, IDX[side + "Knee"]], P[m, IDX[side + "Ankle"]] = Kn, An
    return P


def op_swap(P, op, T):
    a, b = rng(op, T)
    part = op.get("part", "both")
    pairs = LR_PAIRS["arms"] + LR_PAIRS["legs"] if part == "both" else LR_PAIRS.get(part)
    if pairs is None:
        raise Rejected("swap_lr part must be arms, legs or both")
    P = P.copy()
    for x, y in pairs:
        P[a:b + 1, [IDX[x], IDX[y]]] = P[a:b + 1, [IDX[y], IDX[x]]]
    return P


def op_retime(clip, P, op, T):
    a, b = rng(op, T)
    f = EASE.get(op.get("ease", "smoothstep"))
    if f is None:
        raise Rejected(f"retime ease must be one of {', '.join(EASE)}")
    t = clip.t
    P = P.copy()
    src = P.copy()
    for i in range(a + 1, b):
        u = (t[i] - t[a]) / max(t[b] - t[a], 1e-6)
        tau = t[a] + f(u) * (t[b] - t[a])
        for j in range(P.shape[1]):
            for d in range(3):
                P[i, j, d] = np.interp(tau, t[a:b + 1], src[a:b + 1, j, d])
    return P


def op_pose(clip, P, op, T, L):
    a, b = rng(op, T)
    pose = op.get("pose") or {}
    for r in pose:
        if r not in IDX or r == "root":
            raise Rejected(f"unknown joint {r!r} in pose")
    wgt = float(op.get("weight", 1.0))
    Pn = P.copy()
    for r, xyz in pose.items():
        Pn[:, IDX[r]] = np.array(xyz, float) / 1000.0
    w = edge_weights(T, a, b, int(op.get("blend", 6))) * wgt
    out = blend(P, Pn, w, list(pose))
    m = w > 0
    out[m] = k.enforce_bones(out[m], L)  # directions kept, lengths restored root outward
    return out


def op_set(P, op, T, spread):
    j = op.get("joint")
    if j not in IDX or j == "root":
        raise Rejected(f"set: unknown joint {j!r}")
    frames, xyz = op.get("frames") or [], op.get("xyz") or []
    if len(frames) != len(xyz):
        raise Rejected("set: frames and xyz differ in length")
    return set_positions(P, {j: dict(zip([int(f) for f in frames], xyz))}, T, spread)


def set_positions(P, tables, T, spread):
    P = P.copy()
    for r, rows in tables.items():
        j = IDX[r]
        fr = sorted(rows)
        for f in fr:
            if not (0 <= f < T):
                raise Rejected(f"{r}: frame {f} outside 0..{T - 1}")
        delta = {f: np.array(rows[f], float) / 1000.0 - P[f, j] for f in fr}
        for f in fr:
            P[f, j] = np.array(rows[f], float) / 1000.0
        # the change spread to frames between two given frames (decimated export)
        for f0, f1 in zip(fr[:-1], fr[1:]):
            if 1 < f1 - f0 <= spread and np.isfinite(delta[f0]).all() and np.isfinite(delta[f1]).all():
                for f in range(f0 + 1, f1):
                    u = (f - f0) / (f1 - f0)
                    P[f, j] = P[f, j] + (1 - u) * delta[f0] + u * delta[f1]
    return P


# ------------------------------------------------------------------ validation

def validate(P0, P, t, L, repair=False):
    problems = []
    had = ~np.isnan(P0).any(-1)
    if np.isnan(P[had]).any():
        problems.append("NaN where the recording had data")
    changed = np.nanmax(np.abs(np.nan_to_num(P - P0, nan=1.0)), axis=(1, 2)) > 0.0005
    L0 = sc.bone_lengths(P0)
    L1 = sc.bone_lengths(P)
    tol = np.maximum(BONE_TOL_REL * L, BONE_TOL_ABS)
    dev1 = np.abs(L1 - L)
    dev0 = np.abs(L0 - L)
    bad = changed[:, None] & (dev1 > tol) & ~(dev1 <= dev0 + 0.002)
    if bad.any():
        if repair:
            P = P.copy()
            P[changed] = k.enforce_bones(P[changed], L)
        else:
            fr, bo = np.where(bad)
            sample = ", ".join(f"frame {f} {BONES[b][0]}-{BONES[b][1]} {L1[f, b] * 1000:.0f} mm (median {L[b] * 1000:.0f})"
                               for f, b in list(zip(fr, bo))[:6])
            problems.append(f"bone lengths broken in {len(set(fr))} frames: {sample}")
    if len(t) > 1:
        v = np.linalg.norm(np.diff(P, axis=0), axis=-1) / np.maximum(np.diff(t), 1e-4)[:, None]
        v0 = np.linalg.norm(np.diff(P0, axis=0), axis=-1) / np.maximum(np.diff(t), 1e-4)[:, None]
        fast = (v > VMAX) & ~(v <= np.nan_to_num(v0, nan=0) + 0.01)
        if fast.any():
            fr, jo = np.where(fast)
            problems.append(f"joints faster than {VMAX:.0f} m/s: " +
                            ", ".join(f"{ROLES[j]} at frame {f + 1}" for f, j in list(zip(fr, jo))[:6]))
    return P, problems


# ------------------------------------------------------------------ main

def analysis_table(body):
    rows = ["| from s | to s | frames | joint | problem | severity | suggested op |", "|---|---|---|---|---|---|---|"]
    for p in body.get("problems", []):
        fr = p.get("frames", ["", ""])
        rows.append(f"| {p.get('from_s', '')} | {p.get('to_s', '')} | {fr[0]}-{fr[-1]} | {p.get('joint', '')} | "
                    f"{p.get('kind', '')} | {p.get('severity', '')} | {(p.get('suggested_op') or {}).get('op', '')} |")
    return "\n".join(rows)


def apply_reply(src_path, text, force=False, repair=False, spread=10, apply_suggestions=False):
    clip = sc.load(src_path)
    T = clip.T
    kind, body = parse_reply(text)
    if kind == "analysis":
        if not apply_suggestions:
            return None, body, None, None, None
        body = {"format": PATCH_FORMAT, "source_sha": body.get("source_sha"), "summary": "suggested ops of an analysis",
                "ops": [p["suggested_op"] for p in body.get("problems", []) if p.get("suggested_op")]}
        kind = "patch"
    P0 = clip.P.copy()
    P = clip.P.copy()
    rw = clip.rw
    L = sc.median_bone_lengths(P0)
    log = []
    summary = ""
    if kind == "patch":
        if body.get("format") != PATCH_FORMAT:
            raise Rejected(f"format must be {PATCH_FORMAT}")
        if body.get("source_sha") != sha(src_path) and not force:
            raise Rejected(f"source_sha {body.get('source_sha')} does not match this recording ({sha(src_path)}); "
                           "use --force if it is the right file")
        summary = body.get("summary", "")
        for n, op in enumerate(body["ops"]):
            name = op.get("op")
            try:
                if name == "pipeline":
                    P, rw, plog = op_pipeline(clip, P, rw, op, T)
                    L = sc.median_bone_lengths(P) if not ("from" in op or "to" in op) else L
                elif name == "smooth":
                    P = op_smooth(clip, P, op, T)
                elif name == "interpolate":
                    P = op_interpolate(clip, P, op, T)
                elif name == "keys":
                    P = op_keys(clip, P, op, T)
                elif name == "hold":
                    P = op_hold(clip, P, op, T)
                elif name == "lock_foot":
                    P = op_lock_foot(clip, P, rw, op, T, L)
                elif name == "swap_lr":
                    P = op_swap(P, op, T)
                elif name == "retime":
                    P = op_retime(clip, P, op, T)
                elif name == "pose":
                    P = op_pose(clip, P, op, T, L)
                elif name == "set":
                    P = op_set(P, op, T, spread)
                else:
                    raise Rejected(f"unknown op {name!r}")
            except Rejected as e:
                raise Rejected(f"op {n + 1} ({name}): {e}")
            log.append({k_: v for k_, v in op.items() if k_ not in ("xyz", "pose")})
    else:
        P = set_positions(P, body, T, spread)
        log.append({"op": "tables", "joints": len(body)})
    # bone lengths are judged against the clip's own median (after a whole-clip pipeline, the new one)
    P, problems = validate(P0, P, clip.t, L, repair)
    if problems:
        raise Rejected("; ".join(problems))
    P[~np.isnan(P).all(axis=(1, 2)), IDX["root"]] = 0.0
    prev = clip.doc.get("cleanup")
    meta = {"cleanup": {**(prev or {}), "claude": {"source_sha": sha(src_path), "summary": summary, "ops": log,
                                                   "repair": repair}}}
    doc = clip.to_doc(P, rw=rw, extra=meta)
    return doc, clip, P0, P, rw


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source", help="the .skel.json that was exported")
    ap.add_argument("reply", help="Claude's answer saved as a file (.md or .json)")
    ap.add_argument("-o", "--output")
    ap.add_argument("--force", action="store_true", help="accept a source_sha mismatch")
    ap.add_argument("--repair", action="store_true", help="restore bone lengths instead of rejecting")
    ap.add_argument("--spread", type=int, default=10, help="frames a 'set' change is spread over (decimated export)")
    ap.add_argument("--report", help="write a before/after metrics file (.md)")
    ap.add_argument("--apply-suggestions", action="store_true",
                    help="an analysis-only answer (prompt 6): apply its suggested ops")
    a = ap.parse_args(argv)
    with open(a.reply) as fh:
        text = fh.read()
    try:
        doc, clip, P0, P, rw = apply_reply(a.source, text, a.force, a.repair, a.spread, a.apply_suggestions)
    except Rejected as e:
        print(f"REJECTED: {e}", file=sys.stderr)
        return 2
    if doc is None:
        print("analysis only, nothing changed (add --apply-suggestions to apply the suggested ops):")
        print(analysis_table(clip))
        return 0
    out = a.output or (a.source[:-len(".skel.json")] if a.source.endswith(".skel.json") else a.source) + ".claude.skel.json"
    sc.save(doc, out)
    c, _ = k.detect_contacts(P, clip.t, rw, k.BASE["feet"])
    b, f = sc.summary(P0, clip.t, c, clip.rw), sc.summary(P, clip.t, c, rw)
    line = (f"jitter {b['jitter_mean_ms2']:.2f} -> {f['jitter_mean_ms2']:.2f} m/s^2, bone std "
            f"{b['bone_std_mean_cm']:.2f} -> {f['bone_std_mean_cm']:.2f} cm, foot slide "
            f"{b['foot_slide_total_cm']:.1f} -> {f['foot_slide_total_cm']:.1f} cm")
    print(f"applied: {out}\n  {line}")
    if a.report:
        with open(a.report, "w") as fh:
            fh.write(f"# Claude patch applied: {os.path.basename(a.source)}\n\n{doc['cleanup']['claude']['summary']}\n\n"
                     f"{line}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
