"""The Claude round trip: export -> (Claude's stored answers to prompts 2 and 6) -> import, checked against the truth.

    python3 -m unittest discover -s cleanup/tests -v        (from the repo root)
"""
import json
import os
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import skelcore as sc  # noqa: E402
import synth  # noqa: E402
import export_for_claude as ex  # noqa: E402
import import_from_claude as im  # noqa: E402
from skelcore import IDX  # noqa: E402

DATA = os.path.join(HERE, "data")


def mpjpe_mm(X, P):
    m = ~np.isnan(X).any(-1)
    return float(np.mean(np.linalg.norm((X - P)[m], axis=-1)) * 1000)


def read(name):
    with open(os.path.join(DATA, name)) as fh:
        return fh.read()


class RoundTrip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.t, cls.P, cls.rw, cls.contact, cls.N, cls.truth, cls.paths = synth.make(cls.tmp.name)
        cls.export, cls.size, cls.step, cls.flags = ex.export(cls.paths["noisy"], os.path.join(cls.tmp.name, "n.skelclaude.md"))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_export_contents(self):
        with open(self.export) as fh:
            text = fh.read()
        for s in ("## Header", "source_sha:", "## Output contract", "### leftWrist", "f,x,y,z", "legs 150-154",
                  "rightKnee 30-35"):
            self.assertIn(s, text)
        self.assertLess(self.size, 200 * 1024)

    def test_export_30s_under_200kb(self):
        t, P, rw = self.t, self.P, self.rw
        T = len(t)
        t3 = np.concatenate([t, t + t[-1] + t[1], t + 2 * (t[-1] + t[1])])
        P3 = np.concatenate([self.N, self.N, self.N])
        rw3 = np.concatenate([rw, rw, rw])
        p = os.path.join(self.tmp.name, "long.skel.json")
        sc.save(synth.to_doc(t3, P3, rw3, noise2d=1.0, rng=np.random.default_rng(1)), p)
        out, size, step, _ = ex.export(p, os.path.join(self.tmp.name, "long.skelclaude.md"))
        self.assertEqual(len(t3), 3 * T)
        self.assertLess(size, 200 * 1024)
        self.assertGreaterEqual(step, 2)
        # a decimated export of the clean file, sent back unchanged as tables, changes nothing beyond rounding
        cp = os.path.join(self.tmp.name, "longclean.skel.json")
        sc.save(synth.to_doc(t3, np.concatenate([P, P, P]), rw3), cp)
        out2, _, _, _ = ex.export(cp, os.path.join(self.tmp.name, "lc.skelclaude.md"))
        with open(out2) as fh:
            doc, clip, P0, P1, _ = im.apply_reply(cp, fh.read())
        self.assertLess(np.nanmax(np.abs(P1 - P0)), 0.002)

    def test_prompt2_shaking_only(self):
        doc, clip, P0, P1, rw = im.apply_reply(self.paths["noisy"], read("prompt2_answer.md"), force=True)
        b, a = sc.summary(P0, self.t), sc.summary(P1, self.t)
        self.assertLess(a["jitter_mean_ms2"], 0.25 * b["jitter_mean_ms2"])
        self.assertLess(mpjpe_mm(P1, self.P), 0.6 * mpjpe_mm(self.N, self.P))
        # timing kept: the arm-raise (left wrist height crossing the shoulder) happens at the same frame +-1
        def cross(X):
            h = X[:, IDX["leftWrist"], 1] - X[:, IDX["leftShoulder"], 1]
            return int(np.argmax((h[120:] > 0))) + 120
        self.assertLessEqual(abs(cross(P1) - cross(self.P)), 1)
        self.assertEqual(doc["cleanup"]["claude"]["ops"][0]["op"], "swap_lr")

    def test_prompt6_analysis_changes_nothing(self):
        doc, body, *_ = im.apply_reply(self.paths["noisy"], read("prompt6_answer.md"), force=True)
        self.assertIsNone(doc)
        kinds = {p["kind"] for p in body["problems"]}
        self.assertTrue({"swap", "wrong_bend", "outlier", "gap", "hold", "jitter"} <= kinds)
        # every injected defect is in the list
        frames = [tuple(p["frames"]) for p in body["problems"]]
        self.assertIn((150, 154), frames)
        self.assertIn((30, 35), frames)
        self.assertIn((200, 205), frames)

    def test_prompt6_suggestions_applied(self):
        doc, clip, P0, P1, rw = im.apply_reply(self.paths["noisy"], read("prompt6_answer.md"), force=True,
                                               apply_suggestions=True)
        self.assertLess(mpjpe_mm(P1, self.P), 0.5 * mpjpe_mm(self.N, self.P))
        self.assertLess(sc.summary(P1, self.t)["bone_std_mean_cm"], 0.01)

    def test_broken_patch_rejected(self):
        bad = {"format": im.PATCH_FORMAT, "source_sha": ex.sha(self.paths["noisy"]), "ops": [
            {"op": "set", "joint": "leftWrist", "frames": [50], "xyz": [[900, 900, 900]]}]}
        with self.assertRaises(im.Rejected) as cm:
            im.apply_reply(self.paths["noisy"], "```json\n" + json.dumps(bad) + "\n```")
        self.assertIn("bone lengths", str(cm.exception))
        # --repair restores the bone lengths instead
        doc, clip, P0, P1, _ = im.apply_reply(self.paths["noisy"], json.dumps(bad), repair=True)
        L = np.linalg.norm(P1[50, IDX["leftWrist"]] - P1[50, IDX["leftElbow"]])
        self.assertAlmostEqual(L, sc.median_bone_lengths(P0)[[c for _, c in sc.BONES].index("leftWrist")], places=3)

    def test_wrong_file_rejected(self):
        bad = {"format": im.PATCH_FORMAT, "source_sha": "0000000000000000", "ops": []}
        with self.assertRaises(im.Rejected):
            im.apply_reply(self.paths["noisy"], json.dumps(bad))
        with self.assertRaises(im.Rejected):
            im.apply_reply(self.paths["noisy"], json.dumps({**bad, "source_sha": ex.sha(self.paths["noisy"]),
                                                            "ops": [{"op": "swap_lr", "from": 10, "to": 9999}]}))
        with self.assertRaises(im.Rejected):
            im.apply_reply(self.paths["noisy"], json.dumps({**bad, "source_sha": ex.sha(self.paths["noisy"]),
                                                            "ops": [{"op": "smooth", "joints": ["nose"]}]}))

    def test_other_ops_run(self):
        sha = ex.sha(self.paths["clean"])
        ops = [{"op": "pipeline", "preset": "standard", "from": 10, "to": 60},
               {"op": "keys", "joints": "all", "from": 60, "to": 90, "keys": [70, 80]},
               {"op": "lock_foot", "side": "right", "from": 0, "to": 100},
               {"op": "retime", "from": 150, "to": 180, "ease": "min_jerk"},
               {"op": "hold", "joints": "all", "from": 190, "to": 230},
               {"op": "pose", "from": 190, "to": 230, "weight": 0.5,
                "pose": {"leftWrist": [700, 500, 0], "rightWrist": [-700, 500, 0]}}]
        doc, clip, P0, P1, _ = im.apply_reply(self.paths["clean"], json.dumps(
            {"format": im.PATCH_FORMAT, "source_sha": sha, "ops": ops}))
        self.assertEqual(len(doc["cleanup"]["claude"]["ops"]), len(ops))


if __name__ == "__main__":
    unittest.main()
