# The cleanup role model: "BEST Motion Capture CLEAN-UP Workflow (2026)"

Video: https://www.youtube.com/watch?v=3OauN3AiTBw (4 min 12 s). Transcript: [3OauN3AiTBw.md](3OauN3AiTBw.md)
(scribe, Groq whisper-large-v3, audio only, 1.6 MB, 16.11.2026). Marko, 16.11.2026: "we need to have the clean up in
this level of precision ... use the software, same software the guy is using as our role models for clean up."

Times below are the transcript's paragraph stamps (each paragraph covers about 50 s). "Said" = from the video;
"knowledge" = what I know about the tools, not said in the video; check before relying on it.

## The software

| tool | what for | price as said | free part |
|---|---|---|---|
| **QuickMagic** | AI motion capture from ordinary video, outputs FBX | not said | "50 seconds of free mocap every month" (00:00:00) |
| **Cascadeur** (the transcript writes "Cascader") | the cleanup itself: auto rig, AI in-betweening, physics | "$8 a month" for professional use, promo code in his pinned comment (00:03:26) | "try it yourself for free" via his link (00:03:26) |

No version numbers are said. Knowledge: QuickMagic is a web service (quickmagic.ai: the video is uploaded to them);
Cascadeur (cascadeur.com, Nekki) is a desktop app for macOS, Windows and Linux with a free tier and paid tiers; the
exact free-tier limits change, read them on the site.

## His workflow, step by step

1. **Capture** (00:00:00). Any mocap source; he uses QuickMagic. It ends as an FBX file.
2. **Import and auto rig** (00:00:00). FBX into Cascadeur; it asks whether to create a rig automatically: yes, yes. A few
   seconds later the animation sits on "a very powerful rig" (Cascadeur's control rig) that can be edited like any other.
3. **Keep only the key poses** (00:00:51). The old way: delete the frames between the major parts and fix one keyframe at
   a time, footsteps by hand. His way: delete everything except the main poses. "It doesn't matter if the raw mocap data
   is low quality, because Cascadeur only needs poses."
4. **AI in-betweening, the purple button** (00:00:51). Select all keyframes, press it: Cascadeur generates the animation
   between the keyframes ("the most likely animation that would have needed to happen between two keyframes"). "And just
   like that, we have essentially cleaned up the mocap data." Manual adjustments remain possible on top.
5. **Biases** (00:01:42). Right click a stretch and choose a bias (walking here, running there); the generation leans
   toward it.
6. **Physics** (00:01:42). "Simulate physics": a green ghost shows how the character would move with real gravity, weight
   and time. If it looks right, a button bakes the green simulation into the original keyframes; adjust further by hand.
7. **Fix the actor's marks** (00:02:35). Move a key pose (he started too close): Cascadeur regenerates the whole motion to
   cover the new distance, in real time, every time a key moves.
8. **Timing decides the gait** (00:02:35 to 00:03:26). The in-between depends on the time available between two keys:
   the same time over a longer distance turns a walk into a run. If a generation looks weird, first check that there is
   enough time between the two keys for the motion to make sense.
9. His verdict (00:03:26): "it's not perfect, but it's getting better every month", far faster than other 3D software.

## The precision

He gives no number (no millimetres, no error figures). The standard he shows: footsteps placed correctly without
sliding, no shaking (the in-betweens are generated, so the raw noise is gone), motion that obeys gravity and timing
(physics pass), and the poses of the actor kept. That is the bar our engine is measured against, with numbers:
jitter in m/s^2, bone-length spread in cm, foot sliding in cm, error against the truth in mm (TAKEOVER.md, Cleanup).

## How his ideas live in our cleanup (no install needed)

| his step | ours (cleanup/) |
|---|---|
| keep the key poses, regenerate the in-betweens | `rekey` step (preset strong; RDP key-pose selection with a stated tolerance, PCHIP in-betweens) and the `keys` operation in the Claude patch |
| purple button cleans the noise | One Euro filter (speed adaptive), zero phase, plus Savitzky-Golay offline |
| a rig keeps the body a body | constant bone lengths re-projected from the root outward, knee/elbow hinge limits, two-bone leg IK |
| footsteps placed correctly | foot contact detection + foot locking with IK, floor estimate, root travel from the planted feet |
| physics simulation | speed and acceleration limits on the root and the joints (no teleports); a full physics pass is not built |
| biases and "make it a run" | the Claude prompts: a person describes what the move should be (prompts 4, 7, 8) |
| move a key, everything follows | `pose` + `retime` operations |

## Using the real tools here (for Marko to decide; nothing was installed or bought)

- **Cascadeur on this Mac.** It reads FBX (and, knowledge, BVH/DAE). Our files are not FBX yet: the Blender worker's
  mannequin rig could export the cleaned motion as FBX (Blender's own FBX exporter, free, local). Then: Cascadeur free
  tier to try, $8 a month (as said in the video) only if he uses it professionally. Download size is several hundred MB
  over the 4G SIM: one download, via the Download Monitor, only after his yes.
- **QuickMagic.** It would replace Apple Vision as the capture: the video must be uploaded (SIM data: a 30 s 1080p clip
  is tens of MB), 50 s free per month, the rest paid. Our app already captures on the Mac for free, so this is only worth
  it if Vision's quality is the limit.
- Neither is needed for the cleanup built here: `skelclean` runs locally, free, and the Claude file covers the
  "describe what you want" part.
