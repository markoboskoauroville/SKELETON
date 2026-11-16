#!/bin/bash
# GUARD "one title only" (MANTRA_MANIFEST modules/one-title-only.md). Run first in the workflow.
cd "$(dirname "$0")/app" || exit 1
fail=0
for f in $(grep -l "NSWindow(\|NSPanel(" *.swift); do
  grep -q "titleVisibility = .hidden" "$f" || { echo "FAIL $f creates a window without titleVisibility = .hidden"; fail=1; }
done
grep -q "func enforceOneTitle" *.swift || { echo "FAIL enforceOneTitle() is missing"; fail=1; }
for h in windowDidBecomeKey windowDidResize windowDidEnterFullScreen windowDidExitFullScreen; do
  grep -q "func $h" *.swift || { echo "FAIL $h is missing"; fail=1; }
done
grep -q "titleVisibility = .visible" *.swift && { echo "FAIL titleVisibility = .visible found"; fail=1; }
[ $fail = 0 ] && echo "one title only: OK"
exit $fail
