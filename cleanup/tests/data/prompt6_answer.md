Nothing changed. Problems found, in time order:

```json
{"format": "skelclaude-analysis/1", "source_sha": "efa6a8808525bf40",
 "summary": "10 s clip, heavy shaking everywhere (45.9 m/s^2, bone lengths wobble 1.6 cm), one leg swap, one backward knee bend, 6 single-frame jumps, one missing frame and a 6-frame wrist gap. The arms-overhead hold 6.0-8.1 s shakes. Elbow 'wrong bend' flags 173-250 are noise around straight arms, ignored.",
 "problems": [
  {"kind": "wrong_bend", "joint": "rightKnee", "frames": [30, 35], "from_s": 1.00, "to_s": 1.17, "severity": "high",
   "note": "the right shin swings forward past straight (knee bent backwards) for 6 frames; spikes on rightAnkle at 29-30 and 35-36 frame it",
   "suggested_op": {"op": "interpolate", "joints": ["rightAnkle"], "from": 28, "to": 37}},
  {"kind": "outlier", "joint": "leftWrist", "frames": [40, 40], "from_s": 1.33, "to_s": 1.33, "severity": "medium",
   "note": "single-frame jump of the left wrist", "suggested_op": {"op": "interpolate", "joints": ["leftWrist"], "from": 39, "to": 41}},
  {"kind": "outlier", "joint": "rightWrist", "frames": [59, 59], "from_s": 1.97, "to_s": 1.97, "severity": "medium",
   "note": "single-frame jump of the right wrist", "suggested_op": {"op": "interpolate", "joints": ["rightWrist"], "from": 58, "to": 60}},
  {"kind": "outlier", "joint": "rightElbow", "frames": [77, 77], "from_s": 2.57, "to_s": 2.57, "severity": "medium",
   "note": "single-frame jump of the right elbow", "suggested_op": {"op": "interpolate", "joints": ["rightElbow"], "from": 76, "to": 78}},
  {"kind": "gap", "joint": "all", "frames": [100, 100], "from_s": 3.33, "to_s": 3.33, "severity": "low",
   "note": "one frame without any 3D joint", "suggested_op": {"op": "interpolate", "joints": "all", "from": 99, "to": 101}},
  {"kind": "swap", "joint": "all", "frames": [150, 154], "from_s": 5.00, "to_s": 5.13, "severity": "high",
   "note": "left and right legs exchanged for 5 frames (the spikes at 149-155 on every leg joint)",
   "suggested_op": {"op": "swap_lr", "part": "legs", "from": 150, "to": 154}},
  {"kind": "outlier", "joint": "topHead", "frames": [181, 181], "from_s": 6.03, "to_s": 6.03, "severity": "medium",
   "note": "the top of the head jumps 20 cm for one frame", "suggested_op": {"op": "interpolate", "joints": ["topHead"], "from": 180, "to": 182}},
  {"kind": "gap", "joint": "leftWrist", "frames": [200, 205], "from_s": 6.67, "to_s": 6.83, "severity": "low",
   "note": "left wrist missing for 6 frames", "suggested_op": {"op": "interpolate", "joints": ["leftWrist"], "from": 199, "to": 206}},
  {"kind": "hold", "joint": "all", "frames": [184, 239], "from_s": 6.13, "to_s": 7.97, "severity": "medium",
   "note": "arms-overhead hold: the body should be still but every joint shakes by 1-3 cm",
   "suggested_op": {"op": "hold", "joints": "all", "from": 184, "to": 239, "blend": 6}},
  {"kind": "outlier", "joint": "leftAnkle", "frames": [260, 260], "from_s": 8.67, "to_s": 8.67, "severity": "medium",
   "note": "single-frame jump of the left ankle", "suggested_op": {"op": "interpolate", "joints": ["leftAnkle"], "from": 259, "to": 261}},
  {"kind": "jitter", "joint": "all", "frames": [0, 299], "from_s": 0.0, "to_s": 9.97, "severity": "high",
   "note": "shaking on every joint, 45.9 m/s^2 mean acceleration, bone lengths wobble 1.6 cm",
   "suggested_op": {"op": "pipeline", "preset": "standard"}}
 ]}
```
