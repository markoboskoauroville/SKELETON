# skeleton-mantra/1: the recording file (*.skel.json)

Written by Skeleton (Mantra) to `~/Movies/Skeleton/YYYY-MM-DD_HH-MM-SS.skel.json`. One file per recording, skeleton only, no video.
Read by `blender/render_mannequin.py`. Numbers rounded to 4 decimals. UTF-8 JSON, one object.

```
{
 "format": "skeleton-mantra/1",
 "fps": 29.7,                         // measured average over the recording
 "camera": "ILCE-7M5",
 "width": 1920, "height": 1080,       // camera picture size in pixels
 "mirror": false,                     // the app's MIRROR switch while recording (data below is NEVER mirrored: raw camera space)
 "joints3d": ["root", "..."],         // ordered raw names, VNHumanBodyPose3DObservation.JointName rawValue.rawValue
 "joints2d": ["root", "..."],         // ordered raw names, VNHumanBodyPoseObservation.JointName rawValue.rawValue
 "roles3d": {"<raw name>": "<role>"}, // raw 3D name -> stable role (use the roles, not the raw names)
 "roles2d": {"<raw name>": "<role>"},
 "frames": [
  {"t": 0.0333,                       // seconds from the first frame
   "p3": {"<raw3d>": [x, y, z], ...}, // root-relative METRES (translation of recognizedPoint(...).position), includes "root" = [0,0,0]
   "r3": {"<raw3d>": [16 numbers]},   // OPTIONAL: localPosition (parent-relative 4x4), row-major; omitted when unavailable
   "p2": {"<raw2d>": [x, y, conf]},   // normalised 0..1, ORIGIN TOP-LEFT (x right, y down), confidence 0..1 (joints under 0.3 are omitted)
   "h": 1.74                          // Vision's bodyHeight estimate in metres, or null
  }
 ]
}
```

## Roles (stable names; the roles are the contract)

3D roles (VNHumanBodyPose3DObservation, 17 joints): `root` (hip centre), `spine`, `centerShoulder`, `centerHead`, `topHead`,
`leftShoulder`, `rightShoulder`, `leftElbow`, `rightElbow`, `leftWrist`, `rightWrist`, `leftHip`, `rightHip`, `leftKnee`, `rightKnee`,
`leftAnkle`, `rightAnkle`.

2D roles (VNHumanBodyPoseObservation): `nose`, `neck`, `leftShoulder`, `rightShoulder`, `leftElbow`, `rightElbow`, `leftWrist`,
`rightWrist`, `root`, `leftHip`, `rightHip`, `leftKnee`, `rightKnee`, `leftAnkle`, `rightAnkle` (eyes and ears are not recorded).

"left" and "right" are the SUBJECT's own left and right, as Vision labels them.

## Notes for the Blender side

- `p3` is Vision's model space unconverted: metres, root at the origin. Treat +y as up. The sign of x/z follows Vision; the sample
  file `blender/sample.skel.json` is synthetic and uses: x positive = the subject's left, y up, z positive toward the camera.
  Because the real axes may differ, derive limb directions from `p3` differences and, if in doubt, check against `p2`
  (image space, y down) for the facing side.
- A frame where the 3D request failed has `p2` only (no `p3`, no `r3`): hold the last pose or interpolate.
- Times `t` are not exactly 1/fps apart: use `t`, not the index.
- No person in a frame: the frame is still written with empty `p2` and no `p3`.
- With several people, p2 is the one with the longest torso; p3 is the first person Vision returns. The header also has "duration" (seconds).

## Version 4 additions (16.11.2026): several cameras, triangulated 3D

Backward compatible: every field above is unchanged; readers that ignore unknown keys keep working.

Header, new keys:
- `"source"`: `"vision3d"` (one camera, Vision's own 3D) or `"triangulated"` (2 or 3 calibrated cameras; the frames' `p3` is triangulated from the 2D joints).
- `"cameras"`: list, camera 1 first. Each: `name`, `uid`, `width`, `height`, `offsetMs` (how much later this camera shows the same moment than camera 1),
  and when calibrated `model` ("fisheye-kb4"), `fx`, `fy`, `cx`, `cy`, `k` (4 coefficients), `R` (9 numbers, row-major) and `t` (3 numbers, metres) = the pose
  of that camera relative to camera 1 (camera 1: identity and zero), `reprojectionPx` (calibration error). `width`/`height` at the top are camera 1's.
  A point X in camera 1's frame is seen by camera n at R X + t. The camera frame is x right, y down, z forward, units metres.

Per frame, new keys:
- `"s"`: `"tri"` (this frame's `p3` is triangulated) or `"vision3d"` (Vision's own 3D, used when triangulation was not possible for this frame).
- `"q"`: tracking quality 0...100 (only with `"s":"tri"`): joints found in at least two views and their reprojection error.

`p3` in a triangulated frame uses the same joint names as before (`roles3d`), root-relative, y up, x = the subject's left when he faces camera 1, z toward
camera 1 (same convention as the sample file). `centerShoulder` is the 2D neck, `centerHead` the nose, `spine` the half way point, `topHead` an estimate above the nose;
there is no `r3` in a triangulated frame. `p2` stays camera 1's raw (unmirrored) 2D joints.
