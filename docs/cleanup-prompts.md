# Cleanup prompts for Claude (paste one with the uploaded .skelclaude.md)

How it goes (16.11.2026):

1. `python3 cleanup/export_for_claude.py ~/Movies/Skeleton/<rec>.skel.json` writes `<rec>.skelclaude.md` next to it
   (under 200 kB; a 30 s clip at 30 fps is written every 2nd frame plus every flagged frame, the header says so).
2. Upload that file to Claude (claude.ai, any model; Opus or Sonnet for the full cleanups) and paste ONE prompt below.
3. Save Claude's answer as a file (copy the whole answer, or only its ```json block) and run
   `python3 cleanup/import_from_claude.py <rec>.skel.json answer.md -o <rec>.claude.skel.json`.
   The importer checks the bone lengths, speeds, frames and the file's fingerprint (source_sha); a broken answer is
   REJECTED and nothing is written. Then render the mannequin from `<rec>.claude.skel.json`.

Every prompt ends with the same contract line, so Claude always answers in a form the importer reads. The full contract
(all operations and their fields) is inside the uploaded file itself, under "Output contract".

---

## 1. Automatic full cleanup

```
You are a motion-capture cleanup artist. The attached file is a body-motion recording (skelclaude/1).
Do a complete, professional cleanup like a mocap editor would (the Cascadeur way: clean poses, natural in-betweens,
physically plausible motion):
- fix every left/right swap listed under Flagged problems (swap_lr);
- remove outliers and wrong knee/elbow bends (interpolate over the flagged frames, 1 frame margin each side);
- remove the shaking everywhere while keeping fast moves sharp (pipeline preset standard, or strong for a slow clip);
- plant the feet where they are in contact (the pipeline does it; add lock_foot for any contact it misses);
- keep the timing and the poses: do not invent motion.
Order the operations so fixes of single frames come first and the whole-clip pipeline last.
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary.
```

## 2. Remove shaking only, keep timing

```
The attached file is a body-motion recording (skelclaude/1). Remove ONLY the shaking (jitter): the person must make
exactly the same moves at exactly the same times. Do not change poses, holds, foot placement or timing.
Use smooth over the whole clip (joints all, min_cutoff 1.0, beta 4; lighter, min_cutoff 2, if the jitter in Metrics is
under 10 m/s^2) and interpolate over the frames listed as outliers or jitter spikes (1 frame margin each side), the
spikes before the smoothing. A left/right swap listed under Flagged problems is a label error, not a move: fix it
first with swap_lr (smoothing across a swap pulls the hips together and the importer rejects the answer).
Nothing else.
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary.
```

## 3. Fix foot sliding and floor contact

```
The attached file is a body-motion recording (skelclaude/1). Fix the feet: while a foot is on the floor it must not
slide or sink. Use the foot contacts and the foot sliding lines under Flagged problems: for each contact stretch of
each foot, one lock_foot with that side and range (blend 4). If two contact stretches of the same foot are separated
by fewer than 4 frames and the foot does not lift, join them into one. Do not touch the arms, head or timing.
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary.
```

## 4. Fix a specific time range

```
The attached file is a body-motion recording (skelclaude/1). Problem: from 3.2 s to 4.0 s the left arm jumps.
Find the frames of that time in the time table. Look at leftShoulder, leftElbow and leftWrist there and decide what
is wrong (a jump away from the track, a swap with the right arm, a wrong elbow bend, plain shaking). Fix only that,
only in that range plus up to 3 frames each side: interpolate for jumps, swap_lr for a swap, smooth for shaking.
Leave everything else exactly as it is.
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary that
says what you found.
```
(Replace the times and the limb with what you see. "the right leg", "the head", "both arms" work the same way.)

## 5. Yoga holds: perfectly still holds, natural transitions

```
The attached file is a yoga session recording (skelclaude/1). In yoga the held asanas must be perfectly still and the
transitions between them smooth and natural.
- Find every hold: the "holds" line under Flagged problems, plus any stretch over 0.8 s where the body barely moves.
- For each hold: hold with joints all over the still part (start 3 frames after the body comes to rest, end 3 frames
  before it starts moving), blend 6.
- Between holds: smooth (min_cutoff 0.6, beta 3) so transitions flow without shaking; do not change their timing.
- Both feet stay planted during a standing hold (lock_foot for each foot on the floor).
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary listing the
holds (start and end in seconds).
```

## 6. Analysis only: list the problems, change nothing

```
The attached file is a body-motion recording (skelclaude/1). Do NOT change anything. Read the metrics, the flagged
problems and the joint tables, and list every real problem a mocap editor would fix: swaps, jumps, wrong bends, bone
length errors, foot sliding, gaps, shaking worse than the rest of the clip, holds that drift. Group neighbouring frames
into one problem, give the time in seconds (from the time table), the joint, how bad it is, a one-sentence note, and
the one operation that would fix it. Ignore flags that are only noise (a few mm).
Answer ONLY with the skelclaude-analysis/1 JSON block described in the Output contract in the file.
```
(The importer prints it as a table; `--apply-suggestions` applies the suggested operations.)

## 7. Retime or smooth a transition

```
The attached file is a body-motion recording (skelclaude/1). The transition from about 4.0 s to 6.0 s (the arms
rising overhead) looks mechanical. Make it look like a human move: find the frame where the move starts and the frame
where it ends, then retime between them with ease min_jerk (slow start, slow end), and smooth the same range lightly
(min_cutoff 1.5). The poses before and after the transition stay exactly as they are.
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary.
```

## 8. Make it look like the reference pose

```
The attached file is a yoga recording (skelclaude/1). From 6.0 s to 8.0 s the person holds Warrior II (Virabhadrasana
II). Make the hold match a correct Warrior II while keeping this person's own body (bone lengths in the joint table):
front knee bent about 90 degrees over the ankle, back leg straight, arms level at shoulder height, pointing along the
legs, torso upright over the hips, head turned toward the front hand.
Compute the target positions in millimetres, root-relative, axes as in the file, for the joints that must change, and
use ONE pose operation over that range (weight 0.8, blend 8), then hold over the same range. Keep every bone length
of the joint table. Do not change frames outside the range.
Answer ONLY with the skelclaude-patch/1 JSON block of the Output contract in the file, with a short summary of what
moved and by how much.
```
(Replace the asana and times. The app's own pose list, data/poses.json, holds the angles it compares against.)

---

## Tested (16.11.2026)

Prompts 2 and 6 were followed by Claude (Opus 5.5, acting exactly as the prompt says) on the synthetic test clip
(`cleanup/synth.py`, 10 s, 1.2 cm noise, spikes, a swap, a wrong knee bend). The answers are stored in
`cleanup/tests/data/` and replayed by `cleanup/tests/test_claude_roundtrip.py`. Results are in TAKEOVER.md, "Cleanup".
