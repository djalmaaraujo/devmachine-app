#!/bin/bash
# Renders the website's short loops of the app: runs the demo walk
# DEVMACHINE_DEMO_WALK=site off screen, then turns each scene's frames into
# <scene>.webm (VP9), <scene>.mp4 (H.264) and <scene>-poster.webp.
#
#   scripts/site_demo_videos.sh <output-dir>
#
# SITE_DEMO_FRAMES=<dir> reuses frames a previous walk wrote there.
# SITE_DEMO_SCENES="context home" renders and encodes only those scenes.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 1 ]; then
  echo "usage: $0 <output-dir>" >&2
  exit 2
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg is missing: brew install ffmpeg" >&2; exit 1; }

OUT="$1"
mkdir -p "$OUT"
WIDTH=2520
HEIGHT=1620
SCENES="${SITE_DEMO_SCENES:-operator sessions cli context publish scheduled share home}"

if [ -n "${SITE_DEMO_FRAMES:-}" ]; then
  FRAMES="$SITE_DEMO_FRAMES"
else
  FRAMES="$(mktemp -d)/frames"
  trap 'rm -rf "$(dirname "$FRAMES")"' EXIT
  swift build
  DEVMACHINE_DEMO=1 DEVMACHINE_DEMO_HIDDEN=1 DEVMACHINE_DEMO_WALK=site \
    DEVMACHINE_DEMO_SCENES="$(echo "$SCENES" | tr ' ' ',')" \
    DEVMACHINE_DEMO_SNAPSHOTS="$FRAMES" .build/debug/DevmachineApp
fi

SCALE="scale=${WIDTH}:${HEIGHT}:flags=lanczos,fps=30,format=yuv420p"
for scene in $SCENES; do
  list="$FRAMES/$scene/frames.ffconcat"
  [ -f "$list" ] || { echo "no frames for $scene in $FRAMES" >&2; exit 1; }
  # The fps filter holds the last frame as long as the gap before it, so
  # the scene is cut at the sum of its holds.
  seconds="$(awk '/^duration/ { total += $2 } END { print total }' "$list")"
  # The screen is mostly still, so a keyframe every 10 s and slower presets
  # shrink the files at the same crf, which is what sets the quality.
  vp9=(-c:v libvpx-vp9 -b:v 0 -crf 32 -g 300 -row-mt 1 -tile-columns 2 -deadline good -cpu-used 0
    -passlogfile "$OUT/$scene-vp9")
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$list" -vf "$SCALE" -t "$seconds" \
    "${vp9[@]}" -pass 1 -an -f null /dev/null
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$list" -vf "$SCALE" -t "$seconds" \
    "${vp9[@]}" -pass 2 -an "$OUT/$scene.webm"
  rm -f "$OUT/$scene-vp9"-*.log
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$list" -vf "$SCALE" -t "$seconds" \
    -c:v libx264 -preset veryslow -crf 22 -tune stillimage -g 300 -pix_fmt yuv420p -movflags +faststart \
    -an "$OUT/$scene.mp4"
  last="$(ls "$FRAMES/$scene"/*.png | sort | tail -n 1)"
  ffmpeg -loglevel error -y -i "$last" -vf "scale=${WIDTH}:${HEIGHT}:flags=lanczos" -quality 82 "$OUT/$scene-poster.webp"
done

for scene in $SCENES; do
  seconds="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$scene.mp4")"
  printf '%-9s %5.1fs  webm %4d KB  mp4 %4d KB\n' "$scene" "$seconds" \
    "$(( $(stat -f %z "$OUT/$scene.webm") / 1024 ))" "$(( $(stat -f %z "$OUT/$scene.mp4") / 1024 ))"
done
