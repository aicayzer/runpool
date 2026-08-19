#!/usr/bin/env bash
# Generate the icon and its fill-level variants.
#
# The mark is a pool with a waterline. The variants raise that waterline with
# the proportion of runners that are up, so an icon can report state rather
# than just identify the app.
#
# Requires librsvg. ImageMagick cannot render these: its internal renderer
# silently drops the clip path and the outline, leaving a bare wave.
#   brew install librsvg
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
OUT="${1:-.}"

# The wave crest sits off centre on purpose. Centred, the mark reads as a
# symmetrical logo rather than as water, and the eye notices the symmetry
# before it notices what the shape is.
WAVE_START=20

# $1 fill 0..1  $2 disabled 0|1
emit_svg() {
  local fill="$1" disabled="${2:-0}" y water slash=""

  # Waterline across the basin's inner height, 116 (full) to 396 (empty).
  y=$(awk -v f="${fill}" 'BEGIN { printf "%d", 396 - (f * 280) }')

  if awk -v f="${fill}" 'BEGIN { exit !(f > 0.001) }'; then
    water="<g clip-path=\"url(#basin)\"><path d=\"M ${WAVE_START} ${y} q 40 -34 80 0 t 80 0 t 80 0 t 80 0 t 80 0 V 470 H ${WAVE_START} Z\" fill=\"#0a84ff\"/></g>"
  else
    water=""
  fi

  # Disabled reads as a slash through the mark. Drawn in two strokes, the
  # lower one in the background colour, so it cuts a visible gap rather than
  # merging into the blue where it crosses the wall.
  if [ "${disabled}" = "1" ]; then
    slash='<line x1="120" y1="392" x2="392" y2="120" stroke="#0a84ff" stroke-width="40" stroke-linecap="round"/>'
  fi

  cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs>
    <clipPath id="basin"><rect x="86" y="86" width="340" height="340" rx="90"/></clipPath>
  </defs>
  <rect x="76" y="76" width="360" height="360" rx="100" fill="none" stroke="#0a84ff" stroke-width="40"/>
  ${water}
  ${slash}
</svg>
SVG
}

render() {
  local name="$1" fill="$2" disabled="${3:-0}"
  emit_svg "${fill}" "${disabled}" > "/tmp/rp-${name}.svg"
  rsvg-convert -w 512 -h 512 "/tmp/rp-${name}.svg" -o "${OUT}/${name}.png"
  echo "  ${name}.png"
}

echo "rendering:"
# The app icon sits at just over half full: unmistakably a pool with water in
# it, and clearly not a progress bar at either extreme.
render icon 0.55
emit_svg 0.55 0 > "${OUT}/icon.svg"
rsvg-convert -w 1024 -h 1024 "${OUT}/icon.svg" -o "${OUT}/icon@1024.png"
echo "  icon.svg, icon@1024.png"

# State variants, for a menu bar reporting how much of the pool is awake.
render pool-0 0.0
render pool-25 0.25
render pool-50 0.5
render pool-75 0.75
render pool-100 1.0
render pool-off 0.0 1

# Menu bar variants. Same mark, drawn to the edge of the canvas rather than
# inset, because a menu bar renders every icon to one height: padding baked
# into the asset just makes the mark smaller than its neighbours.
for spec in "0 0.0 0" "25 0.25 0" "50 0.5 0" "75 0.75 0" "100 1.0 0" "off 0.0 1"; do
  set -- ${spec}
  emit_svg "$2" "$3" \
    | sed -e 's/viewBox="0 0 512 512"/viewBox="60 60 392 392"/' \
    > "/tmp/rp-bar-$1.svg"
  rsvg-convert -w 512 -h 512 "/tmp/rp-bar-$1.svg" -o "${OUT}/bar-$1.png"
  echo "  bar-$1.png"
done
