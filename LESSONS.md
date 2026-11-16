# LESSONS: Skeleton (Mantra)

1. 16.11.2026: Nothing compiles on the Mac; GitHub Actions is the compiler, so every Swift line is written carefully and the run is the check.
2. All joint maths is done in "height units" (x times aspect, y from the top): angles are then true angles at any picture shape.
3. Mirror is a display flip only; comparison runs in camera space so right limb matches right limb whichever way the picture is shown.
4. 16.11.2026: NSView already has a method `zone()`; a global function of the same name breaks the build (renamed zoneOf). Circled digits (1 2 3 in circles) do not draw in the monospaced system font: use plain digits.
5. 16.11.2026: Vision body pose needs a body in view: a face alone (FaceTime close up) gives "NO PERSON SEEN", which is right. The Sony ILCE-7M5 delivers a wide fisheye picture; the whole circle is shown, nothing cropped.
6. 16.11.2026 (Blender 5.2.1): the engine id is `BLENDER_EEVEE` (no EEVEE_NEXT any more). Video output needs
   `image_settings.media_type = "VIDEO"` before `file_format = "FFMPEG"`; a still needs media_type "IMAGE" back. Materials have a
   node tree from creation (`use_nodes` is deprecated, removed in 6.0). Movies get a frame range appended to the file name: render
   into a temp folder and move the file. `preferences.filepaths.save_version = 0` stops the .blend1 backup.
7. Bone parenting: set parent, parent_type BONE, parent_bone, then `view_layer.update()` and put matrix_world back; otherwise the
   part jumps to the bone's tail. Set pose by matrix_basis computed as (parent_rest^-1 rest)^-1 parent_pose^-1 pose, all in Python:
   no depsgraph update per bone, 241 frames x 24 bones key in a few seconds.
8. Area lights light only their front side: their plane draws a hard diagonal on the cyclorama. Keep each light's plane outside the
   frame (the rim light sits high, 5.5 m).
9. Only bone directions come from Vision; lengths stay the mannequin's. Limbs: smallest swing from the parent-carried rest
   (no twist flips); torso: twist from the hip and shoulder lines.
10. 16.11.2026 (cleanup): Vision p3 is root-relative and 2D shows no depth. Foot locking in the world needs the root's travel:
    x/y come from the 2D root track (metres per pixel from segments seen in both), z only from the planted feet. Locking z
    without it pinned a planted foot against a root that really moved and bent the legs (6.6 mm added error on clean data).
11. Order matters: swaps before any filter (a smeared swap pulls the hips into the root), wrong bends rebuilt on the raw
    track before the filter (smoothed, a 6-frame backward knee becomes a long wrong stretch), holds and rekey before the
    foot lock (anything after the lock breaks the plants).
12. A Claude answer that smoothed across a left/right swap was rejected by the importer's bone check: the check is what
    makes the LLM route safe. Prompts must tell Claude to fix listed swaps first.
13. scribe `--out` takes a FOLDER (it wrote docs/reference/<id>.md/<id>.md and another worker's commit picked it up);
    give it a directory and rename afterwards.
10. 16.11.2026: a cyclorama is finite: turn the body to the view, keep the camera looking into the curve, or the side views show its edge.
    Forward Fold reads only from the side turned a little to the front; from the pure side the near arm hides the hanging torso.
11. 16.11.2026: a BiDi helper that dies without `session.end` blocks Marko's Firefox ("Maximum number of active sessions") until
    Firefox restarts. Every BiDi script ends the session in `finally`, also on an error.
12. 16.11.2026: this folder is shared by two sessions at once; the other one commits everything (`git add -A`), so a half-done
    edit of yours can be released in its version. Commit your own files at once, pull --rebase before every push.
13. 16.11.2026: a phone's address that answers curl from Terminal may not answer the app: Little Snitch holds a newly signed
    app's connections (its prompt times out to Deny). 127.0.0.1 (adb forward) is not held, so adb's tunnel is the last route.
14. 16.11.2026: never toggle USB tethering on the Nothing (it carries the Mac's internet); switching it re-enumerates USB and the
    adb transport changes: the source must find its phone again by hardware serial, never by the adb transport.
