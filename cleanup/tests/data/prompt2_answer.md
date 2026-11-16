Removed the shaking only. First the isolated jumps flagged as outliers / jitter spikes were rebuilt from the frames
around them (1 frame margin; the two right-ankle spikes at 29-30 and 35-36 enclose the wrong right-knee bend 30-35,
so they are rebuilt as one stretch 28-37), then the whole clip was smoothed with a zero-phase One Euro filter
(jitter 45.9 m/s^2 is far above 10, so min_cutoff 1.0, beta 4). The spikes at 149-155 on all leg joints are the
left/right leg swap listed for frames 150-154: a label error, fixed first with swap_lr as the prompt says.

```json
{"format": "skelclaude-patch/1", "source_sha": "efa6a8808525bf40",
 "summary": "Shaking removed: 7 jump/spike stretches rebuilt, whole clip smoothed (One Euro, min_cutoff 1.0, beta 4). Timing, poses and feet unchanged. Leg labels swapped back at frames 150-154.",
 "ops": [
  {"op": "swap_lr", "part": "legs", "from": 150, "to": 154},
  {"op": "interpolate", "joints": ["topHead"], "from": 179, "to": 183},
  {"op": "interpolate", "joints": ["rightElbow"], "from": 75, "to": 78},
  {"op": "interpolate", "joints": ["leftWrist"], "from": 39, "to": 42},
  {"op": "interpolate", "joints": ["leftWrist", "rightWrist"], "from": 58, "to": 60},
  {"op": "interpolate", "joints": ["rightWrist"], "from": 221, "to": 223},
  {"op": "interpolate", "joints": ["leftAnkle"], "from": 258, "to": 262},
  {"op": "interpolate", "joints": ["rightAnkle"], "from": 28, "to": 37},
  {"op": "smooth", "joints": "all", "from": 0, "to": 299, "min_cutoff": 1.0, "beta": 4}
 ]}
```
