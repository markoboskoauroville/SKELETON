"""skelcore: shared pieces of the Skeleton (Mantra) cleanup tools.

Loads a skeleton-mantra/1 recording (*.skel.json, docs/skel-format.md) into numpy arrays by ROLE, writes it back,
holds the bone hierarchy, and measures the quality metrics (jitter, bone-length spread, foot sliding).

Arrays: P[T, J, 3] metres, root-relative (Vision p3), NaN where a joint or a whole frame is missing; t[T] seconds.
Pure numpy; scipy is used when present (PCHIP, Savitzky-Golay) with numpy fallbacks.
"""
import copy
import json

import numpy as np

try:
    from scipy.interpolate import PchipInterpolator
    from scipy.signal import savgol_filter
    HAVE_SCIPY = True
except Exception:  # pragma: no cover - fallback path
    HAVE_SCIPY = False

FORMAT = "skeleton-mantra/1"

# The 17 3D roles, fixed order (the contract in docs/skel-format.md).
ROLES = ["root", "spine", "centerShoulder", "centerHead", "topHead",
         "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
         "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
IDX = {r: i for i, r in enumerate(ROLES)}

# parent of each role (root has none). Order of BONES = root outward (parents before children).
PARENT = {
    "spine": "root", "centerShoulder": "spine", "centerHead": "centerShoulder", "topHead": "centerHead",
    "leftShoulder": "centerShoulder", "leftElbow": "leftShoulder", "leftWrist": "leftElbow",
    "rightShoulder": "centerShoulder", "rightElbow": "rightShoulder", "rightWrist": "rightElbow",
    "leftHip": "root", "leftKnee": "leftHip", "leftAnkle": "leftKnee",
    "rightHip": "root", "rightKnee": "rightHip", "rightAnkle": "rightKnee",
}
BONES = [(PARENT[c], c) for c in ["spine", "centerShoulder", "centerHead", "topHead",
                                  "leftShoulder", "leftElbow", "leftWrist",
                                  "rightShoulder", "rightElbow", "rightWrist",
                                  "leftHip", "leftKnee", "leftAnkle",
                                  "rightHip", "rightKnee", "rightAnkle"]]
LR_PAIRS = {
    "arms": [("leftShoulder", "rightShoulder"), ("leftElbow", "rightElbow"), ("leftWrist", "rightWrist")],
    "legs": [("leftHip", "rightHip"), ("leftKnee", "rightKnee"), ("leftAnkle", "rightAnkle")],
}
# 3D role -> 2D role whose confidence speaks for it (Vision 2D has no spine/topHead)
CONF_FROM_2D = {r: r for r in ["leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
                               "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "root"]}
CONF_FROM_2D.update({"centerShoulder": "neck", "centerHead": "nose"})
UP = 1  # +y is up (docs/skel-format.md)


class Clip:
    """One recording: the parsed JSON plus arrays by role."""

    def __init__(self, doc):
        self.doc = doc
        frames = doc.get("frames", [])
        self.T = len(frames)
        self.t = np.array([float(f.get("t", i / float(doc.get("fps", 30.0)))) for i, f in enumerate(frames)])
        r3 = doc.get("roles3d") or {}
        r2 = doc.get("roles2d") or {}
        self.raw3 = {}  # role -> raw name
        for raw in doc.get("joints3d", []):
            self.raw3[r3.get(raw, raw)] = raw
        for r in ROLES:
            self.raw3.setdefault(r, r)
        self.P = np.full((self.T, len(ROLES), 3), np.nan)
        self.conf = np.full((self.T, len(ROLES)), np.nan)  # 2D confidence, NaN = unknown
        self.has2d = np.zeros(self.T, bool)
        self.p2 = np.full((self.T, len(ROLES), 2), np.nan)
        inv3 = {v: k for k, v in self.raw3.items()}
        for i, f in enumerate(frames):
            for raw, xyz in (f.get("p3") or {}).items():
                role = r3.get(raw, inv3.get(raw, raw))
                if role in IDX and xyz is not None and len(xyz) >= 3:
                    self.P[i, IDX[role]] = xyz[:3]
            q = {r2.get(k, k): v for k, v in (f.get("p2") or {}).items()}
            if q:
                self.has2d[i] = True
                for role3, role2 in CONF_FROM_2D.items():
                    v = q.get(role2)
                    self.conf[i, IDX[role3]] = float(v[2]) if v is not None and len(v) >= 3 else 0.0
                    if v is not None:
                        self.p2[i, IDX[role3]] = v[:2]
            if f.get("rw") is not None:
                pass
        self.rw = None
        if frames and all(f.get("rw") is not None for f in frames):
            self.rw = np.array([f["rw"] for f in frames], float)

    @property
    def fps(self):
        if self.T > 1:
            d = np.diff(self.t)
            d = d[d > 0]
            if len(d):
                return float(1.0 / np.median(d))
        return float(self.doc.get("fps", 30.0))

    def to_doc(self, P=None, rw=None, extra=None, drop_r3=True):
        """A new document with p3 replaced by P (NaN joints omitted, all-NaN frames keep no p3)."""
        P = self.P if P is None else P
        out = copy.deepcopy(self.doc)
        for i, f in enumerate(out.get("frames", [])):
            row = P[i]
            if np.all(np.isnan(row)):
                f.pop("p3", None)
            else:
                f["p3"] = {self.raw3[r]: [round(float(v), 4) for v in row[IDX[r]]]
                           for r in ROLES if not np.any(np.isnan(row[IDX[r]]))}
                if "root" in IDX:
                    f["p3"][self.raw3["root"]] = [0.0, 0.0, 0.0]
            if drop_r3:
                f.pop("r3", None)
            if rw is not None:
                f["rw"] = [round(float(v), 4) for v in rw[i]]
        if extra:
            out.update(extra)
        return out


def load(path):
    with open(path) as fh:
        return Clip(json.load(fh))


def save(doc, path):
    with open(path, "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))


# ------------------------------------------------------------------ geometry helpers

def bone_lengths(P):
    """[T, nBones] lengths (NaN where missing)."""
    return np.stack([np.linalg.norm(P[:, IDX[c]] - P[:, IDX[p]], axis=-1) for p, c in BONES], axis=1)


def median_bone_lengths(P, symmetric=True):
    L = np.nanmedian(bone_lengths(P), axis=0)
    if symmetric:
        names = [c for _, c in BONES]
        for k, c in enumerate(names):
            if c.startswith("left"):
                j = names.index("right" + c[4:])
                m = np.nanmean([L[k], L[j]])
                L[k] = L[j] = m
    return L


def unit(v, axis=-1):
    n = np.linalg.norm(v, axis=axis, keepdims=True)
    return v / np.where(n < 1e-12, 1.0, n)


def interp_1d(t, y, valid, method="pchip"):
    """Fill y where not valid from the valid samples (no extrapolation: edges hold the nearest value)."""
    out = y.copy()
    if valid.sum() < 2 or valid.all():
        if valid.sum() == 1:
            out[~valid] = y[valid][0]
        return out
    tv, yv = t[valid], y[valid]
    q = t[~valid]
    if method == "pchip" and HAVE_SCIPY and valid.sum() >= 3:
        f = PchipInterpolator(tv, yv, extrapolate=False)
        val = f(q)
    else:
        val = np.interp(q, tv, yv)
    nanm = np.isnan(val)
    if nanm.any():
        val[nanm] = np.interp(q[nanm], tv, yv)
    out[~valid] = val
    return out


def runs(mask):
    """[(start, end_exclusive)] of True runs."""
    m = np.concatenate([[False], np.asarray(mask, bool), [False]])
    d = np.diff(m.astype(int))
    return list(zip(np.where(d == 1)[0], np.where(d == -1)[0]))


def savgol(y, window, poly):
    if HAVE_SCIPY:
        return savgol_filter(y, window, poly, axis=0, mode="interp")
    # numpy fallback: least-squares polynomial smoothing per window
    half = window // 2
    out = y.copy()
    x = np.arange(-half, half + 1)
    A = np.vander(x, poly + 1)
    c = np.linalg.pinv(A)[-1]
    for i in range(half, len(y) - half):
        out[i] = np.tensordot(c, y[i - half:i + half + 1], axes=(0, 0))
    return out


# ------------------------------------------------------------------ metrics

def jitter(P, t):
    """Mean |acceleration| per joint (m/s^2) from second differences over the real times; root excluded."""
    if len(t) < 3:
        return {}
    dt = np.diff(t)
    v = np.diff(P, axis=0) / dt[:, None, None]
    a = np.diff(v, axis=0) / ((dt[1:] + dt[:-1]) / 2)[:, None, None]
    mag = np.linalg.norm(a, axis=-1)
    return {r: float(np.nanmean(mag[:, IDX[r]])) for r in ROLES if r != "root" and np.isfinite(mag[:, IDX[r]]).any()}


def bone_spread(P):
    """Std of each bone's length over the clip, in cm."""
    L = bone_lengths(P)
    return {f"{p}-{c}": float(np.nanstd(L[:, k]) * 100) for k, (p, c) in enumerate(BONES)}


def world(P, rw):
    return P if rw is None else P + rw[:, None, :]


def foot_slide_cm(P, contact, rw=None):
    """Total horizontal (x,z) travel of each ankle during its contact frames, cm. contact: dict side -> bool[T]."""
    W = world(P, rw)
    res = {}
    for side in ("left", "right"):
        a = W[:, IDX[side + "Ankle"]][:, [0, 2]]
        c = contact.get(side)
        if c is None:
            continue
        both = c[1:] & c[:-1]
        d = np.linalg.norm(np.diff(a, axis=0), axis=-1)
        res[side] = float(np.nansum(d[both]) * 100)
    return res


def summary(P, t, contact=None, rw=None):
    j = jitter(P, t)
    b = bone_spread(P)
    s = {"jitter_mean_ms2": float(np.mean(list(j.values()))) if j else None,
         "jitter_per_joint_ms2": j,
         "bone_std_mean_cm": float(np.nanmean(list(b.values()))) if b else None,
         "bone_std_cm": b}
    if contact is not None:
        fs = foot_slide_cm(P, contact, rw)
        s["foot_slide_cm"] = fs
        s["foot_slide_total_cm"] = float(sum(fs.values()))
    return s
