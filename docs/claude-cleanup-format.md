# skelclaude/1: a recording Claude can clean (and skelclaude-patch/1, what Claude sends back)

Made 16.11.2026 for Marko: "a file format which I can upload to Claude AI and then it can clean up automatically or by
the prompt." The prompts are in [cleanup-prompts.md](cleanup-prompts.md).

## The round trip

```
python3 cleanup/export_for_claude.py rec.skel.json                 -> rec.skelclaude.md   (upload this + a prompt)
python3 cleanup/import_from_claude.py rec.skel.json answer.md -o rec.claude.skel.json   (answer = Claude's reply)
```

## The upload file (`*.skelclaude.md`)

Markdown, one file, under 200 kB (`--max-kb`). In order:

1. **Header**: format, source file name, `source_sha` (first 16 hex of the SHA-256 of the .skel.json: the importer
   refuses an answer made for another file), units (whole millimetres, root-relative: the root is always 0,0,0 and not
   listed), axes (+y up), fps, frame count, `export_step`, left/right meaning.
2. **Joints and bones**: each joint, its parent and the bone's median length in mm (the hierarchy is
   root > spine > centerShoulder > centerHead > topHead; centerShoulder > shoulder > elbow > wrist; root > hip > knee > ankle).
3. **Metrics**: jitter (mean joint acceleration, m/s^2) overall and per joint, bone-length spread (cm), foot sliding
   during contact (cm), floor height.
4. **Flagged problems** with frame ranges: left/right swaps, outliers, wrong knee/elbow bends, bone lengths off by more
   than 12 % and 3 cm, missing joints, jitter spikes (over 4x the joint's median acceleration), foot sliding, foot
   contacts, holds (still stretches). Made by `cleanup/skelanalyze.py`.
5. **Output contract**: the exact JSON Claude must answer with, the operations table, the rules the importer enforces.
6. **Data**: a `### time` table (f, t_ms), then one `### <joint>` table per joint: CSV `f,x,y,z` in mm. A `### rootWorld`
   table appears only when the file carries a root trajectory (`frames[].rw`).

Size: 10 s at 30 fps, every frame = about 80 kB. When the full rate does not fit, every N-th frame is written plus every
frame of a swap, outlier or wrong bend with one neighbour on each side (`export_step: N` in the header; the tolerance
is the motion between kept frames, at most N/fps seconds). A 30 s clip at 30 fps comes out at step 2, under 200 kB.

## What Claude sends back

One fenced ```json block:

```json
{"format": "skelclaude-patch/1", "source_sha": "efa6a8808525bf40",
 "summary": "what was changed and why",
 "ops": [{"op": "swap_lr", "part": "legs", "from": 150, "to": 154},
         {"op": "interpolate", "joints": ["topHead"], "from": 179, "to": 183},
         {"op": "smooth", "joints": "all", "from": 0, "to": 299, "min_cutoff": 1.0, "beta": 4}]}
```

Frames are the original frame numbers; positions are mm, root-relative; ranges inclusive; applied in order.

| op | fields | effect |
|---|---|---|
| pipeline | preset, set {"step.key": v}, skip [..], from/to optional | runs `skelclean` (whole clip, or only the range, blended) |
| smooth | joints, from, to, min_cutoff, beta, blend | zero-phase One Euro on the range |
| interpolate | joints, from, to, method pchip/linear | frames strictly inside rebuilt from the frames around |
| keys | joints, from, to, keys [..] | only the key frames kept, in-betweens regenerated (Cascadeur's idea) |
| hold | joints, from, to, blend | median pose held still, blended in and out |
| lock_foot | side, from, to, blend | ankle pinned at its median position, two-bone leg IK |
| swap_lr | part arms/legs/both, from, to | left/right labels exchanged |
| retime | from, to, ease smoothstep/ease_in/ease_out/min_jerk/linear | same path, new timing |
| pose | from, to, pose {joint: [x,y,z]}, weight, blend | joints moved toward the targets, bone lengths restored root outward |
| set | joint, frames, xyz | exact positions; with a decimated export the change is spread to the frames between (`--spread`, 10) |

Analysis-only answers (prompt 6) use `{"format": "skelclaude-analysis/1", "source_sha", "summary", "problems": [{kind,
joint, frames [a,b], from_s, to_s, severity, note, suggested_op}]}`. The importer prints them as a table and changes
nothing; `--apply-suggestions` applies the suggested operations.

Claude may also return whole `### <joint>` CSV tables under `## Data` (same layout as the upload); they are applied as
positions and checked the same way.

## What the importer checks (`cleanup/import_from_claude.py`)

- the JSON format name, the `source_sha` (refused unless `--force`), joint names, frame ranges, op fields;
- no NaN where the recording had data;
- every CHANGED frame keeps each bone within 10 % or 20 mm of the clip's median length (or no worse than the input was
  at that frame); `--repair` restores the lengths instead of refusing;
- no joint faster than 15 m/s between two frames (unless the input was already that fast there).

A refused answer prints `REJECTED: <reason>` and exit code 2; nothing is written. A good one writes a normal
skeleton-mantra/1 file (the Blender renderer reads it as usual) with `"cleanup": {"claude": {source_sha, summary, ops}}`
added next to any earlier skelclean metadata.

## Additions to skeleton-mantra/1 made by the cleanup tools

These are extra fields; a reader that does not know them ignores them.

- `"cleanup": {"tool", "preset", "steps", "params", "bone_lengths_m", "metrics", "r3_dropped", "claude": {...}}` at the top.
- `frames[].rw`: the estimated root trajectory in metres (x, y in the camera plane from the 2D root track, z from the
  planted feet), written only when it was estimated. `p3` stays root-relative.
- `frames[].r3` (Vision's local matrices) is dropped from cleaned files, because it no longer matches the cleaned `p3`.
