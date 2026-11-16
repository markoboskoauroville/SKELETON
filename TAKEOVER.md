# TAKEOVER: Skeleton (Mantra)

What it is (public repo, not promoted: no README, no description; repo-privacy.md). A Mac Swift app, bundle id
community.auroville.skeleton, repo markoboskoauroville/SKELETON, built only by GitHub Actions (.github/workflows/build.yml),
release vN Latest, signed "Mantra Apps" on the Mac after `gh release download`. Whole-number versions (`let VERSION` in app/App.swift).

Marko, 16.11.2026: one app that looks at the image of any camera he chooses and follows him with a skeleton.
Apple's Vision (VNDetectHumanBodyPoseRequest), all on the Mac. Camera picker (built-in, USB like the Sony ILCE-7M5, Continuity,
virtual), picture aspect-fit and never cropped, skeleton per person, light smoothing, joints under 0.3 hidden. Switches (before
their titles): MIRROR (on for the FaceTime camera by default), SHOW ANGLES, SKELETON ONLY, SOUND, VOICE. Space = full screen,
controls fade after 3 s, the window X quits, amber PERMISSIONS (top right) while camera access is missing.

Pose matching (his idea, 16.11.2026): a TARGET pose (photo or drop, FREEZE MY POSE, or the starter set in data/poses.json) is drawn
as a white ghost stood on the user's hip centre and scaled by his torso; each limb is compared by angle; bones go green / yellow / red
(Level table in app/Model.swift: Beginner 20/40 deg hold 2 s, Middle 12/25 deg 3 s, Professional 6/14 deg 5 s); score 0-100 in a ring.
Green held for the level's time = achieved (Glass chime if SOUND). SESSION: five starter poses (Mountain, Upward Salute, Warrior II,
Tree, Triangle) plus saved poses; at each pose the voice says its name and cues (POST http://127.0.0.1:8837/speak; if it does not
answer, the best installed Mac voice via AVSpeechSynthesizer; SETTINGS shows which). Saved poses: ~/Library/Application Support/Skeleton (Mantra)/poses/*.json (+ .jpg).

Files: app/Model.swift (joints, limbs, levels, compare), Camera.swift (capture + Vision), Stage.swift (drawing), MainView.swift
(controls, session), Voice.swift, Store.swift, Updater.swift (kits/mac-updater, asks at start), App.swift, main.swift.
Command line: `open -a "Skeleton (Mantra)" --args --camera ILCE-7M5` (at launch only; quit it first to switch from outside).

## Blender part: Render Mannequin (blender/, 16.11.2026)

Marko, 16.11.2026: "build in my blender ... a mannequin. Classic mannequin ... and also build the skeleton inside of him and then
after recording ... render mannequin and then mannequin is getting animated and rendered on my desktop doing the same movement."

Files:
- `blender/mannequin.py` builds `blender/mannequin.blend` (committed, ~190 KB): a classic artist's wooden mannequin (egg head, neck,
  egg chest, waist piece, pelvis block, ball joints at shoulders/elbows/wrists/hips/knees/ankles, tapered limb segments, mitten
  hands with a thumb, rounded feet; light beech wood: wave rings + bump + thin coat) with the armature "Skeleton" inside on Apple's
  17 3D joints (pelvis, chest, neck, head, clavicle/upperarm/forearm/hand, hip/thigh/shin/foot, .L/.R). Every wooden part is
  rigidly parented to one bone (no weights). Also a light grey cyclorama, three soft area lights (key, fill, high rim) and the camera.
  Rest = T-pose, 1.75 m, faces -Y, its left is +X, soles on Z 0. Rebuild:
  `/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P blender/mannequin.py`
- `blender/render_mannequin.py` (what the app's RENDER MANNEQUIN runs):
  `Blender -b --factory-startup -P blender/render_mannequin.py -- --in X.skel.json --out ~/Desktop/X_mannequin.mp4 [--res 1280x720] [--samples 16] [--frames N] [--blend out.blend --no-render]`
  Prints `INFO ...`, `PROGRESS n/N` per frame, `DONE <path>`; on failure `ERROR <reason>` and exit 1.
- `blender/make_synthetic.py` writes `blender/synthetic.skel.json` (T-pose, arms up, squat, Warrior II, jitter, a 3D gap) for tests.
- Example stills: docs/mannequin_tpose.jpg, mannequin_armsup.jpg, mannequin_squat.jpg, mannequin_squat_side.jpg, mannequin_warrior2.jpg.

How the movement maps (format: docs/skel-format.md, roles3d used, never the raw names):
1. p3 (Vision, y up, x subject's left, z toward camera) -> Blender (x, -z, y). Frames resampled at k/fps from `t`; frames without
   p3 and joints missing are interpolated / held; 3-frame moving average against jitter.
2. Chirality check: knees bend forward; if the data says backward on average, x is flipped (protects against a different Vision axis sign).
3. Facing: p2 decides whether the subject faced the camera (his left shoulder/hip on the image right in the raw picture); the body is
   turned about Z so the mannequin faces the render camera the same way (back to it if he had his back to the camera). `mirror` true
   = the render is mirrored (x flipped, left/right swapped), like the app's picture.
4. Size: the median `h` (Vision body height) scales the armature; without h it is estimated from the joints.
5. Bones (rules in mannequin.py BONES): torso bones (pelvis, chest, neck, head) aim from joint to joint and take their twist from the
   hip line (pelvis) or shoulder line (chest, neck, head); limbs take the smallest swing from where the parent carries them (no twist
   flips); hands continue the forearm; feet stay flat, turned toward the knee and the pelvis facing. Bone LENGTHS stay the
   mannequin's (only directions come from the data), so nothing detaches. Quaternions keyed per frame.
6. Floor: per frame the root goes up/down so the lowest ankle is at ankle height (lowest sole on the floor), smoothed over 3 frames.
   p3 is root-relative, so the body does not travel; the camera is fixed, in front, slightly above, framing the whole movement.
7. EEVEE (`BLENDER_EEVEE` in 5.x), 16 samples, H.264 MP4 (CRF high, preset good), at the recording fps. Blender writes into a temp
   folder (it adds a frame range to the name), then the file is moved to --out.

Speed (MacBook Pro M1 Pro, nice 10, 1280x720, 16 samples): ~0.37 s per frame = ~11 s of rendering per second of motion at 30 fps.
The app runs it with nice -n 19.

Note on blender/sample.skel.json (16.11.2026): its p2 puts the subject's left on the image LEFT while its p3 says he faces the
camera, so the renderer reads it as "back to the camera" and shows the mannequin from behind (still the same arm on the same side
of the picture). Real recordings from the camera are consistent; synthetic.skel.json is the reference test.

## Cleanup (cleanup/, 16.11.2026)

Marko, 16.11.2026: "develop a model for cleaning up the movement, so there are no shaking. They need to follow kinetic
algorithms ... and also a file format which I can upload to Claude AI and then it can clean up automatically or by the
prompt." Role model: the video 3OauN3AiTBw (QuickMagic capture + Cascadeur cleanup), docs/reference/cleanup-role-model.md.

Local engine, Python 3 + numpy (scipy used when present; both were already installed: numpy 1.24.3, scipy 1.11.4; no venv,
nothing pip-installed). `cleanup/skelclean in.skel.json -o out.skel.json --preset gentle|standard|strong|yoga-hold|dance --report`
(`--skip step`, `--only step`, `--set step.key=value`, `--print-params`). Steps in the order they run:
swaps (left/right label swaps by continuity, FIRST because the filter would smear them) > outliers (Hampel, bone-length
outliers, impossible speeds, optional 2D confidence) > gaps (PCHIP up to 15 frames; longer gaps keep the data) > limits on the
raw track (a short wrong knee/elbow bend is rebuilt before the filter smears it) > One Euro (vector, speed adaptive, forward +
backward = no lag) > Savitzky-Golay (optional) > bones (median length per bone, left/right averaged, children re-projected
root outward) > limits again (knee/elbow hinge: no hyperextension past 8/12 deg, no over-flexion; hinge axis from the frames
clearly bent) > holds (yoga-hold: still stretches frozen, blended) > rekey (strong: key poses by RDP, in-betweens regenerated,
the Cascadeur idea) > feet (floor, contacts = ankle low + still N frames, lock with two-bone leg IK, blended; with a 2D track
the root travel is estimated: x/y from p2 in metres, z from the planted feet; frames[].rw is written) > root (speed and
acceleration limits, no teleports) > bones again. Output: same format, plus "cleanup" metadata; r3 is dropped (no longer
matches). Files: skelcore.py (load/save, hierarchy, metrics), skelclean.py, skelanalyze.py, synth.py (test motion with truth).

Measured on the synthetic test (cleanup/synth.py: 10 s, 30 fps, squat, step, arm wave, arms-overhead hold; noise 1.2 cm +
1 % scale wobble, 6 spikes of 25 cm, a 6-frame wrist gap, a frame without 3D, a 5-frame leg swap, a knee bent 20 deg
backwards). Error vs truth (mean joint error), jitter (mean joint acceleration; the true motion has 0.87 m/s^2), bone
length spread, foot sliding during the true contacts, and the error the preset adds to the CLEAN motion:

| | error mm | jitter m/s^2 | bone std cm | foot slide cm | clean motion distorted mm |
|---|---|---|---|---|---|
| noisy input | 20.5 | 45.9 | 1.60 | 1330 | |
| gentle | 9.6 | 13.1 | 0.00 | 29.4 | 1.2 |
| standard | 7.3 | 7.8 | 0.00 | 6.7 | 1.6 |
| strong | 5.7 | 0.9 | 0.00 | 3.0 | 2.6 |
| yoga-hold | 5.4 | 3.7 | 0.00 | 5.6 | 2.4 (hold: under 1 mm/frame) |
| dance | 8.9 | 11.4 | 0.00 | 18.7 | 1.3 |
| Claude, prompt 2 (shaking only) | 7.4 | 8.3 | 0.61 | (feet not in scope) | |
| Claude, prompt 6 + its suggested ops | 6.7 | 6.6 | 0.00 | | |

Every preset: the swap fixed (all 5 frames), the backward knee rebuilt (ankle within 3 cm of the truth), the gap and the
empty frame filled. Tests: `python3 -m unittest discover -s cleanup/tests` (18 tests, about 6 s).

Claude round trip: `cleanup/export_for_claude.py rec.skel.json` > rec.skelclaude.md (header, bone table, metrics, flagged
frames, output contract, CSV per joint in mm; 10 s = 80 kB; a 30 s clip goes to every 2nd frame + flagged frames, under 200
kB) > upload with a prompt from docs/cleanup-prompts.md > save the answer > `cleanup/import_from_claude.py rec.skel.json answer.md
-o rec.claude.skel.json` (checks fingerprint, joints, ranges, bone lengths, speeds; REJECTED = exit 2, nothing written;
`--repair`, `--force`, `--apply-suggestions` for analysis answers). Format: docs/claude-cleanup-format.md. Prompts 2 and 6
were acted out by Claude on the synthetic clip; the answers are cleanup/tests/data/ and replayed by the tests. The first
answer to prompt 2 smoothed across the leg swap and the importer REJECTED it (hips pulled to 3 cm): prompt 2 now fixes
listed swaps first.

App hook (for the app worker, not built into the app by this worker): a CLEAN button before RENDER MANNEQUIN runs
`/usr/bin/python3 <repo>/cleanup/skelclean.py <rec>.skel.json -o <rec>.clean.skel.json --preset <preset> --report`
(exit 0 = ok; stdout has a one-line summary; the report is <rec>.clean.report.md) and then renders <rec>.clean.skel.json.
Presets for a picker: gentle, standard (default), strong, yoga-hold, dance. Runs in about 1.3 s for a 30 s clip (M1 Pro).
