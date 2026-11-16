#!/usr/bin/env python3
"""export_for_claude: a Skeleton (Mantra) recording as one compact Markdown file Claude can read and clean.

    python3 cleanup/export_for_claude.py rec.skel.json [-o rec.skelclaude.md] [--max-kb 200] [--step N]

The file (format skelclaude/1, docs/claude-cleanup-format.md): header (units, fps, axes, joints and bone hierarchy with
median lengths), the automatic metrics, the flagged problem frames, the output contract (what Claude must send back),
then one CSV table per joint: f,x,y,z in whole millimetres, root-relative. If the full rate does not fit --max-kb,
every N-th frame is written (N stated in the header) plus every flagged frame and its neighbours.
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skelcore as sc  # noqa: E402
import skelanalyze  # noqa: E402
from skelcore import IDX, ROLES, BONES, PARENT  # noqa: E402

FORMAT = "skelclaude/1"
PATCH_FORMAT = "skelclaude-patch/1"


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:16]


def fmt_ranges(rs):
    return ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in rs) or "none"


CONTRACT = f"""## Output contract (what you send back)

Reply with ONE fenced ```json block, nothing else is read by the importer:

```json
{{"format": "{PATCH_FORMAT}", "source_sha": "<the source_sha above>",
 "summary": "one or two sentences: what you changed and why",
 "ops": [ ... operations, applied in order ... ]}}
```

Frames are the ORIGINAL frame numbers (column f). Positions are millimetres, root-relative, same axes as the tables.
"joints" is a list of joint names from the joint table, or "all". Ranges are inclusive.

| op | fields | what the importer does |
|---|---|---|
| pipeline | preset (gentle, standard, strong, yoga-hold, dance), set {{"step.key": value}}, skip [steps], from, to (optional) | runs the local engine skelclean; with from/to only that range changes, blended at the edges |
| smooth | joints, from, to, min_cutoff (Hz, 0.3 strong .. 3 light), beta | zero-phase One Euro filter on the range, blended at the edges |
| interpolate | joints, from, to, method (pchip or linear) | throws away the frames strictly between from and to, rebuilds them from the frames around |
| keys | joints, from, to, keys [frames] | keeps only the listed key frames in the range, regenerates the in-betweens (PCHIP) |
| hold | joints, from, to, blend (frames) | the median pose of the range held perfectly still, blended in and out |
| lock_foot | side (left, right), from, to | that ankle pinned at its median position in the range (two-bone leg IK), blended |
| swap_lr | part (arms, legs, both), from, to | left and right labels exchanged in the range |
| retime | from, to, ease (smoothstep, ease_in, ease_out, min_jerk, linear) | same path between the two frames, new timing along it |
| pose | from, to, pose {{joint: [x, y, z]}}, weight 0..1, blend (frames) | moves the listed joints toward the given positions, blended in and out |
| set | joint, frames [..], xyz [[x, y, z], ..] | the exact positions; with a decimated export the change is spread to the frames between |

Rules the importer enforces (a patch that breaks one is REJECTED, nothing is written):
- every bone keeps its median length (table above) within 10 % or 20 mm; every output frame is checked;
- no joint faster than 15 m/s between two frames; no NaN; frames inside 0..last; joint names from the table;
- the source_sha must match (otherwise it is refused unless the user forces it).
Prefer the computed operations (pipeline, smooth, interpolate, hold, lock_foot, keys) over set: they keep the
bone lengths by themselves. Use set only for a few frames, with positions that keep the bone lengths.
When the prompt asks for analysis only, change nothing and reply with ONE ```json block instead:
{{"format": "skelclaude-analysis/1", "source_sha": "...", "summary": "...", "problems": [
  {{"kind": "jitter|outlier|swap|wrong_bend|bone_length|foot_slide|gap|hold|other", "joint": "<name or all>",
   "frames": [first, last], "from_s": 3.20, "to_s": 4.00, "severity": "low|medium|high",
   "note": "what is wrong, in one sentence", "suggested_op": {{ one operation from the table, or null }}}} ]}}
Instead of a patch you may also return the whole file: the same "### <joint>" CSV tables (f,x,y,z in mm) under a
"## Data" heading; it is checked by the same rules.
"""


def export(path, out=None, max_kb=200, step=None, cleaned_note=None):
    clip = sc.load(path)
    flags = skelanalyze.analyze(clip)
    P, t, T = clip.P, clip.t, clip.T
    joints = [r for r in ROLES if r != "root"]
    # which frames go in the tables
    must = set()
    for key in ("swaps",):
        for s in flags[key]:
            a, b = s["frames"]
            must.update(range(max(0, a - 1), min(T, b + 2)))
    for key in ("outliers", "wrong_bends"):
        for rs in flags[key].values():
            for a, b in rs:
                must.update(range(max(0, a - 1), min(T, b + 2)))
    if len(must) > T // 4:
        must = set()

    def build(st):
        sel = sorted(set(range(0, T, st)) | must | {T - 1})
        parts = []
        parts.append("### time\n```csv\nf,t_ms\n" + "\n".join(f"{i},{int(round(t[i] * 1000))}" for i in sel) + "\n```\n")
        if clip.rw is not None:
            parts.append("### rootWorld (root travel, not part of the joint tables)\n```csv\nf,x,y,z\n" +
                         "\n".join(f"{i},{int(round(clip.rw[i, 0] * 1000))},{int(round(clip.rw[i, 1] * 1000))},"
                                   f"{int(round(clip.rw[i, 2] * 1000))}" for i in sel) + "\n```\n")
        for r in joints:
            rows = []
            for i in sel:
                v = P[i, IDX[r]]
                if np.isnan(v).any():
                    continue
                rows.append(f"{i},{int(round(v[0] * 1000))},{int(round(v[1] * 1000))},{int(round(v[2] * 1000))}")
            parts.append(f"### {r}\n```csv\nf,x,y,z\n" + "\n".join(rows) + "\n```\n")
        return sel, "\n".join(parts)

    if step is None:
        step = 1
        while True:
            sel, data = build(step)
            if len(data.encode()) <= max_kb * 1024 * 0.85 or step >= 10:
                break
            step += 1
    else:
        sel, data = build(step)
    m = flags["metrics"]
    src_sha = sha(path)
    name = os.path.basename(path)
    hdr = [f"# {FORMAT}: {name}", "",
           "A body-motion recording from Skeleton (Mantra) (Apple Vision 3D body pose, 17 joints) prepared for cleanup.",
           "Read the header, the metrics and the flagged problems, then follow the user's prompt and answer by the",
           "output contract at the end of the header.", "",
           "## Header", "",
           f"- format: {FORMAT}",
           f"- source: {name}",
           f"- source_sha: {src_sha}",
           "- units: millimetres, whole numbers; root-relative (the root joint, the hip centre, is always 0,0,0 and is not listed)",
           "- axes: +y up; x and z as Apple Vision gives them (in the synthetic files x = the subject's left, z = toward the camera)",
           f"- fps: {clip.fps:.2f} (real times in the time table, they are not exactly regular)",
           f"- frames: {T} (0..{T - 1}), duration {t[-1] - t[0]:.2f} s" if T else "- frames: 0",
           f"- export_step: {step}" + (" (every frame)" if step == 1 else
                                       f" (every {step}th frame plus flagged frames: {len(sel)} rows per joint; "
                                       "tolerance = the motion between kept frames, at most "
                                       f"{1000 * step / max(clip.fps, 1):.0f} ms)"),
           "- left/right: the subject's own left and right", ""]
    if cleaned_note:
        hdr += [f"- note: {cleaned_note}", ""]
    hdr += ["### Joints and bones (parent -> joint, median length mm)", "", "| joint | parent | length mm |", "|---|---|---|"]
    mb = flags["median_bone_mm"]
    for r in joints:
        hdr.append(f"| {r} | {PARENT[r]} | {mb.get(PARENT[r] + '-' + r, '')} |")
    hdr += ["", "## Metrics (automatic)", "",
            f"- jitter, mean joint acceleration: {m['jitter_mean_ms2']:.2f} m/s^2 (a clean human motion is about 1-5)",
            f"- bone length spread, mean std: {m['bone_std_mean_cm']:.2f} cm (clean = 0)",
            f"- foot sliding during contact: {m.get('foot_slide_total_cm', 0):.1f} cm",
            f"- floor (lowest ankle height; relative to the root unless a rootWorld table is given): {flags['floor_y_mm']} mm", "",
            "| joint | jitter m/s^2 |", "|---|---|"]
    for r, v in m["jitter_per_joint_ms2"].items():
        hdr.append(f"| {r} | {v:.1f} |")
    hdr += ["", "## Flagged problems (frames)", ""]
    hdr.append("- left/right swaps: " + (", ".join(f"{s['part']} {fmt_ranges([s['frames']])}" for s in flags["swaps"]) or "none"))
    for key, title in (("outliers", "outliers (jumps away from the track)"), ("wrong_bends", "knee/elbow bent the wrong way"),
                       ("bone_length_errors", "bone length off by more than 12 % and 3 cm"), ("missing", "missing joints"),
                       ("jitter_spikes", "jitter spikes (acceleration over 4x the joint's median)"),
                       ("foot_slide", "foot sliding while in contact")):
        d = flags[key]
        hdr.append(f"- {title}: " + ("none" if not d else "; ".join(f"{j} {fmt_ranges(rs)}" for j, rs in d.items())))
    hdr.append("- foot contacts: " + "; ".join(f"{s} {fmt_ranges(rs)}" for s, rs in flags["contacts"].items()))
    hdr.append("- holds (still stretches): " + fmt_ranges(flags["holds"]))
    hdr += ["", CONTRACT, "## Data", ""]
    text = "\n".join(hdr) + "\n" + data
    out = out or (path[:-len(".skel.json")] if path.endswith(".skel.json") else path) + ".skelclaude.md"
    with open(out, "w") as fh:
        fh.write(text)
    return out, len(text.encode()), step, flags


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("input")
    ap.add_argument("-o", "--output")
    ap.add_argument("--max-kb", type=float, default=200)
    ap.add_argument("--step", type=int)
    a = ap.parse_args(argv)
    out, size, step, _ = export(a.input, a.output, a.max_kb, a.step)
    print(f"{out}: {size / 1024:.0f} kB, export step {step}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
