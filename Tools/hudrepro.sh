#!/bin/bash
# HITL repro loop for the missing-pill bug.
#
# Run me, then dictate normally. Every time the pill is missing, SAY OUT LOUD
# "pill missing" into the mic — the transcript timestamp in the log marks the
# moment. Press Ctrl-C when done and share the output file.
#
# Output: /tmp/murmur-hud-repro.log — interleaved window-server witness
# (hudwatch: is the pill actually composited, where, at what alpha) and the
# app's own log (state transitions, HUD present/dismiss, audio config changes).

set -u
OUT=/tmp/murmur-hud-repro.log
: > "$OUT"

echo "Watching for 10 minutes. Dictate; say 'pill missing' whenever it's gone."
echo "Logging to $OUT — Ctrl-C to stop early."

{
  swift "$(dirname "$0")/hudwatch.swift" 600
} >> "$OUT" 2>&1 &
WATCH_PID=$!

log stream --style compact \
  --predicate 'subsystem == "ai.pivotstudio.murmur-youtube"' \
  --level info >> "$OUT" 2>&1 &
LOG_PID=$!

trap 'kill $WATCH_PID $LOG_PID 2>/dev/null' EXIT
wait $LOG_PID
