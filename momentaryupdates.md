# momentaryupdates (Marko's requests, word for word)

**16.11.2026:** "I want to have one swift app, we call it skeleton, which will just look at my image from any camera I choose and follow me with the skeleton. Please build it!"

**16.11.2026:** "the idea is that AI understands the static image of the real-time image from the person and then draws the skeleton so the actual task of the user is not to match the pose which is on this photo, It needs to align his skeleton with the artificial skeleton which actually doing the pose. And then when they are aligned, the skeleton become green. When they are close, it's yellow and when they are far away, it's red."

**16.11.2026:** "you need to build tolerance in three levels. Beginner yogi, middle yogi and professional yogi. So then you measure alignment with less and less tolerance for professional and more tolerance for beginner. So beginner can just have a kind of approximation of the pose and he can go on. and when he achieved the pose, then new pose is coming and the voice say pose whatever pose is and it says basic cues about the pose and then user is looking at the skeleton on the screen and matches the pose"

**16.11.2026:** "It needs to have record button. So it records the whole movement of the skeleton in one file. And then you need to build in my blender, it's installed here, a mannequin ... after recording I can say there is a command in my app render mannequin and then mannequin is getting animated and rendered on my desktop doing the same movement as I was doing"

**16.11.2026:** "Yes, Sony and phone through Iriun or two phones or any combination."


## 16.11.2026, Manual Camera as the Skeleton camera over USB (Marko, word for word)

"I have much better protocol than IRIUN, it has much better picture quality. And this we need to use our Mantra manual camera for this and it needs to be also compatible with the software for poses. So if I connect via USB my Pixel phone, this app needs to understand how to adjust the phone and the camera to get the best possible picture available on this USB connection. and since my camera is on ADB, my application is to understand ADB and start the camera itself, adjust the settings of this phone and being able to use it for posing."

**Plan:** Manual Camera gets an adb-started SKELETON mode (intent extras: lens, size, fps, bitrate; 50 Hz anti-flicker, stabilisation off, lens intrinsics in a JSON status) that serves H.264 on a TCP port the Mac reaches by adb forward; Skeleton (Mantra) gets the source "Manual Camera (Pixel, USB)" which starts it, decodes with VideoToolbox and feeds the pose pipeline.

**16.11.2026:** "Now I have four cameras connected at the same time. There is FaceTime, there is Sony, there is Pixel and there is Nothing. Some are on wires, some are not on wire. Please wire them in my skeleton, everything."
(Plan: every phone with Manual Camera v221+ is its own source, "Manual Camera (<phone>, USB|Wi-Fi)": USB through adb forward when on a cable, else the stream straight over Wi-Fi/Tailscale (the faster address measured), each with host-clock times for the multi-camera sync.)

**16.11.2026:** "For some reason I am upside down in manual camera nothing over USB. So you need to detect upside down picture and simply rotate them."

**16.11.2026:** "This is my personal application. So it can work with my personal phones. If ADB is there and camera not working, it needs to kick it in automatically. In the settings we can disable automatic kicks in of the cameras through ADB. By default it's enabled. and when I start the app it just scans Wi-Fi, USB, ADB and just automatically configures the phones to be able to record and find the Sony so pictures is coming through these devices I have for now three"


## 16.11.2026, finish all unfinished works (Marko, word for word)

"finish all unfinished works. Now. Everything."

**Skeleton leftovers (v15):** (1) The OBS Virtual Camera shows its placeholder logo, not black: detect static placeholders too (frames that do not change over 2 s and no person ever seen) and list them as text "no picture (static)", checked again by itself. (2) Bundle adjustment across all cameras after the pairwise chained calibration (poses, optionally intrinsics, Levenberg-Marquardt with Accelerate, unit tests on synthetic 3-4 camera rigs with noise). (3) The window opened on the BenQ: open on the MacBook Pro's built-in screen on first launch or when the saved frame is on a missing or non-built-in screen; keep his later choice. (4) The 5 floor poses (down-dog, forward-fold, plank, chaturanga, upward-dog) in the session list and a ready "Wyoga" sequence (Upward Salute, Down Dog, Warrior II, Tree, Sun Salutation steps).
