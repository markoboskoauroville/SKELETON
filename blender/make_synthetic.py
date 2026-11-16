"""Write blender/synthetic.skel.json: T-pose -> arms up -> squat -> Warrior II.

Vision axes as in docs/skel-format.md: x = subject's left, y up, z toward the camera, root at the origin.
p2 is a raw (unmirrored) camera image of a subject facing the camera: his left is on the image right.
Run: python3 blender/make_synthetic.py
"""
import json
import os
import random

RAW = {"root": "root", "spine": "spine_7_joint", "centerShoulder": "center_shoulder", "centerHead": "center_head_joint",
       "topHead": "top_head_joint", "leftShoulder": "left_shoulder_1_joint", "rightShoulder": "right_shoulder_1_joint",
       "leftElbow": "left_forearm_joint", "rightElbow": "right_forearm_joint", "leftWrist": "left_hand_joint",
       "rightWrist": "right_hand_joint", "leftHip": "left_upLeg_joint", "rightHip": "right_upLeg_joint",
       "leftKnee": "left_leg_joint", "rightKnee": "right_leg_joint", "leftAnkle": "left_foot_joint", "rightAnkle": "right_foot_joint"}


def sym(d):
    """Right side = left side mirrored in x, unless given."""
    out = dict(d)
    for k, v in d.items():
        if k.startswith("left"):
            r = "right" + k[4:]
            if r not in out:
                out[r] = (-v[0], v[1], v[2])
    return out


CENTRE = {"root": (0, 0, 0), "spine": (0, .20, 0), "centerShoulder": (0, .47, 0), "centerHead": (0, .62, 0), "topHead": (0, .77, 0)}
LEGS = {"leftHip": (.10, -.03, 0), "leftKnee": (.10, -.46, 0), "leftAnkle": (.10, -.89, 0)}
T = sym({**CENTRE, **LEGS, "leftShoulder": (.19, .45, 0), "leftElbow": (.47, .45, 0), "leftWrist": (.72, .45, 0)})
UP = sym({**CENTRE, **LEGS, "leftShoulder": (.19, .47, 0), "leftElbow": (.24, .75, 0), "leftWrist": (.26, 1.0, 0)})
SQUAT = sym({"root": (0, 0, 0), "spine": (0, .19, .07), "centerShoulder": (0, .44, .19), "centerHead": (0, .58, .25),
             "topHead": (0, .70, .30), "leftShoulder": (.19, .42, .19), "leftElbow": (.19, .42, .47),
             "leftWrist": (.18, .42, .72), "leftHip": (.10, -.03, 0), "leftKnee": (.15, -.10, .42),
             "leftAnkle": (.15, -.48, .20)})
W2 = {**CENTRE, "leftShoulder": (.19, .45, 0), "leftElbow": (.47, .45, 0), "leftWrist": (.72, .45, 0),
      "rightShoulder": (-.19, .45, 0), "rightElbow": (-.47, .45, 0), "rightWrist": (-.72, .45, 0),
      "leftHip": (.10, -.03, 0), "leftKnee": (.45, -.25, .02), "leftAnkle": (.47, -.69, 0),
      "rightHip": (-.10, -.03, 0), "rightKnee": (-.38, -.36, 0), "rightAnkle": (-.667, -.69, 0)}

KEYS = [(0.0, T), (0.8, T), (1.8, UP), (2.4, UP), (3.2, T), (4.2, SQUAT), (4.9, SQUAT), (5.8, T), (6.8, W2), (8.0, W2)]
FPS = 30.0


def pose_at(t):
    for (t0, a), (t1, b) in zip(KEYS, KEYS[1:]):
        if t <= t1:
            w = 0 if t1 == t0 else max(0.0, (t - t0) / (t1 - t0))
            w = w * w * (3 - 2 * w)
            return {k: tuple(a[k][i] + (b[k][i] - a[k][i]) * w for i in range(3)) for k in a}
    return KEYS[-1][1]


def main():
    random.seed(7)
    frames = []
    n = int(KEYS[-1][0] * FPS) + 1
    p2 = {}
    for i in range(n):
        t = round(i / FPS + random.uniform(-0.004, 0.004), 4) if i else 0.0
        P = pose_at(t)
        p3 = {RAW[k]: [round(v[j] + (random.gauss(0, .006) if k != "root" else 0), 4) for j in range(3)]
              for k, v in P.items()}
        p2 = {}
        for k in ("leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist", "root",
                  "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"):
            x, y, _ = P[k]
            p2[RAW[k]] = [round(.5 + x / 2.4, 4), round(.52 - y / 2.4, 4), 0.9]
        fr = {"t": t, "p2": p2, "h": 1.75}
        if not (95 <= i < 104):  # a 3D gap to test the interpolation
            fr["p3"] = p3
        frames.append(fr)
    roles3 = {v: k for k, v in RAW.items()}
    doc = {"format": "skeleton-mantra/1", "fps": FPS, "camera": "synthetic", "width": 1920, "height": 1080,
           "mirror": False, "duration": frames[-1]["t"], "joints3d": list(RAW.values()), "joints2d": list(p2),
           "roles3d": roles3, "roles2d": {r: roles3[r] for r in p2}, "frames": frames}
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "synthetic.skel.json")
    with open(out, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    print(out, n, "frames")


if __name__ == "__main__":
    main()
