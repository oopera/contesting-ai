#!/usr/bin/env bash
# Render the animated dashed lines in contestation-diagram.svg to GIF + MP4.
#
# The SVG animates `stroke-dashoffset` on .flow paths (dash period = 8 user units).
# CSS/SMIL animation can't be exported directly, so we rasterize one static frame
# per offset step and stitch the frames into a seamless loop.
#
# Usage: ./render-animation.sh [input.svg] [basename]
#   defaults: contestation-diagram.svg  ->  contestation-diagram.gif / .mp4
set -euo pipefail

SRC="${1:-contestation-diagram.svg}"
OUT="${2:-${SRC%.svg}}"

SCALE=2          # 2x supersampling for crisp output
FRAMES=32        # frames in one loop
PERIOD=8         # dash period (stroke-dasharray "4 4" => 8); must match the SVG
FPS=30           # playback fps  (loop length = FRAMES/FPS seconds)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Output pixel size = SVG width/height * SCALE (read from the root <svg> tag).
read -r W H < <(awk -v s="$SCALE" '
  match($0, /<svg[^>]*/) {
    t=substr($0,RSTART,RLENGTH)
    match(t,/width="[0-9.]+"/);  w=substr(t,RSTART+7,RLENGTH-8)
    match(t,/height="[0-9.]+"/); h=substr(t,RSTART+8,RLENGTH-9)
    printf "%d %d\n", w*s, h*s; exit
  }' "$SRC")

echo "Rendering $FRAMES frames from $SRC ..."
for ((i=0; i<FRAMES; i++)); do
  # offset moves dashes along the path direction (toward the arrowheads)
  off=$(awk -v i="$i" -v n="$FRAMES" -v p="$PERIOD" 'BEGIN{printf "%.5f", -p*i/n}')
  # Strip the CSS animation and pin a fixed stroke-dashoffset for this frame.
  sed -e 's/<style>[^<]*<\/style>//' \
      -e "s/class=\"flow\"/class=\"flow\" stroke-dashoffset=\"$off\"/g" \
      "$SRC" > "$TMP/frame.svg"
  rsvg-convert -z "$SCALE" -b white "$TMP/frame.svg" -o "$(printf "%s/f%03d.png" "$TMP" "$i")"
done

# Flatten every frame onto solid white so there is never a transparent/black bg.
WHITE="color=white:s=${W}x${H}"

echo "Encoding MP4 -> $OUT.mp4"
ffmpeg -y -loglevel error -f lavfi -i "$WHITE" -framerate "$FPS" -i "$TMP/f%03d.png" \
  -filter_complex "[0:v][1:v]overlay=shortest=1,format=yuv420p,pad=ceil(iw/2)*2:ceil(ih/2)*2:color=white" \
  -c:v libx264 -movflags +faststart "$OUT.mp4"

echo "Encoding GIF -> $OUT.gif"
palette="$TMP/palette.png"
ffmpeg -y -loglevel error -f lavfi -i "$WHITE" -framerate "$FPS" -i "$TMP/f%03d.png" \
  -filter_complex "[0:v][1:v]overlay=shortest=1,palettegen=stats_mode=diff" "$palette"
ffmpeg -y -loglevel error -f lavfi -i "$WHITE" -framerate "$FPS" -i "$TMP/f%03d.png" -i "$palette" \
  -filter_complex "[0:v][1:v]overlay=shortest=1[bg];[bg][2:v]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0 "$OUT.gif"

echo "Done:"
ls -lh "$OUT.gif" "$OUT.mp4"
