#!/usr/bin/env bash
# Makes a 24 kHz mono 16-bit PCM WAV test utterance for voice-probe.js, using
# only macOS's built-in `say`/`afconvert` (no extra deps).
set -euo pipefail

if [ "$#" -ge 1 ]; then
  TEXT="$1"
else
  TEXT="Hello, what is today's date, and can you tell me in one sentence what you can do for me?"
fi
AIFF="q.aiff"
WAV="q.wav"
# The system default voice can be an undownloaded premium voice that renders silence.
VOICE="${VOICE:-Samantha}"

say -v "$VOICE" -o "$AIFF" "$TEXT"
afconvert -f WAVE -d LEI16@24000 -c 1 "$AIFF" "$WAV"

echo "$(pwd)/$WAV"
