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
