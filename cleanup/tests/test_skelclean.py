"""Tests for skelclean on a synthetic motion with known truth (cleanup/synth.py).

    python3 -m unittest discover -s cleanup/tests -v        (from the repo root)
"""
import os
import subprocess
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import skelcore as sc  # noqa: E402
import skelclean  # noqa: E402
import synth  # noqa: E402
from skelcore import IDX  # noqa: E402


def mpjpe_mm(X, P):
    m = ~np.isnan(X).any(-1)
    return float(np.mean(np.linalg.norm((X - P)[m], axis=-1)) * 1000)


class SynthCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.t, cls.P, cls.rw, cls.contact, cls.N, cls.truth, cls.paths = synth.make(cls.tmp.name)
        cls.results = {}
        for p in skelclean.PRESETS:
            doc, rep = skelclean.run(cls.paths["noisy"], None, p)
            cls.results[p] = (sc.Clip(doc), rep)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_every_preset_improves_metrics(self):
        for p, (clip, rep) in self.results.items():
            with self.subTest(preset=p):
                b, a = rep["before"], rep["after"]
                self.assertLess(a["jitter_mean_ms2"], 0.35 * b["jitter_mean_ms2"])
                self.assertLess(a["bone_std_mean_cm"], 0.01)
                self.assertGreater(b["bone_std_mean_cm"], 1.0)

    def test_closer_to_truth(self):
        before = mpjpe_mm(self.N, self.P)
        for p, (clip, _) in self.results.items():
            with self.subTest(preset=p):
                self.assertLess(mpjpe_mm(clip.P, self.P), 0.55 * before)

    def test_clean_motion_not_distorted(self):
        for p in skelclean.PRESETS:
            with self.subTest(preset=p):
                doc, _ = skelclean.run(self.paths["clean"], None, p)
                self.assertLess(mpjpe_mm(sc.Clip(doc).P, self.P), 3.0)  # mm

    def test_foot_sliding_removed(self):
        before = sc.foot_slide_cm(self.N, self.contact, self.rw)
        for p, (clip, _) in self.results.items():
            with self.subTest(preset=p):
                after = sc.foot_slide_cm(clip.P, self.contact, clip.rw)
                for side in ("left", "right"):
                    self.assertLess(after[side], 0.05 * before[side])

    def test_swaps_fixed(self):
        sw = self.truth["swap_frames"]
        clip, rep = self.results["standard"]
        e = np.linalg.norm(clip.P[sw][:, IDX["leftAnkle"]] - self.P[sw][:, IDX["leftAnkle"]], axis=-1)
        self.assertLess(e.max(), 0.05)
        fixed = [s for s in rep["steps"] if s["step"] == "swaps"][0]["frames"]
        self.assertEqual(fixed, sw)

    def test_knee_hyperextension_fixed(self):
        hk = self.truth["hyperext_frames"]
        for p, (clip, _) in self.results.items():
            with self.subTest(preset=p):
                e = np.linalg.norm(clip.P[hk][:, IDX["rightAnkle"]] - self.P[hk][:, IDX["rightAnkle"]], axis=-1)
                self.assertLess(e.mean(), 0.03)

    def test_gap_and_missing_frame_filled(self):
        clip, _ = self.results["standard"]
        a, b, j = self.truth["gap"]
        self.assertFalse(np.isnan(clip.P[a:b, IDX[j]]).any())
        self.assertFalse(np.isnan(clip.P[self.truth["drop3d"][0]]).any())

    def test_yoga_hold_is_still(self):
        clip, _ = self.results["yoga-hold"]
        m = (self.t > 6.3) & (self.t < 7.7)
        step = np.linalg.norm(np.diff(clip.P[m], axis=0), axis=-1).max()
        self.assertLess(step, 1e-3)  # under 1 mm per frame anywhere in the hold

    def test_output_format(self):
        clip, _ = self.results["standard"]
        d = clip.doc
        self.assertEqual(d["format"], sc.FORMAT)
        self.assertEqual(d["cleanup"]["preset"], "standard")
        self.assertIn("bones", d["cleanup"]["steps"])
        self.assertEqual(len(d["frames"]), len(self.t))
        for f in d["frames"]:
            self.assertEqual(f["p3"]["root"], [0.0, 0.0, 0.0])
            self.assertNotIn("r3", f)

    def test_cli(self):
        out = os.path.join(self.tmp.name, "cli.skel.json")
        rep = os.path.join(self.tmp.name, "cli.report.md")
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "skelclean.py"), self.paths["noisy"],
                            "-o", out, "--preset", "dance", "--report", rep, "--set", "oneeuro.beta=6"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(out) and os.path.exists(rep))
        with open(rep) as fh:
            self.assertIn("jitter", fh.read())


if __name__ == "__main__":
    unittest.main()
