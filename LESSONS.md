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
