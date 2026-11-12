#!/usr/bin/env bash
# Requires ImageMagick. Keep launcher artwork inside Android's 66dp safe circle.
set -euo pipefail
app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icons="$app_dir/src-tauri/icons"
res="$app_dir/src-tauri/gen/android/app/src/main/res"
sed '/  <g /i\  <rect width="256" height="256" fill="#D6F279" />' \
  "$icons/filesync-mark.svg" > "$icons/filesync-icon.svg"
cp "$icons/filesync-icon.svg" "$app_dir/public/favicon.svg"
cp "$icons/filesync-icon.svg" "$app_dir/public/logos/filesync.svg"
cp "$icons/filesync-icon.svg" "$app_dir/../homepage/public/logos/filesync.svg"
magick -background none "$icons/filesync-icon.svg" -resize 512x512 -depth 8 "PNG32:$icons/icon.png"
for spec in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r density size canvas <<< "$spec"
  directory="$res/mipmap-$density"
  # The central 72dp of a 108dp adaptive canvas is visible. A 76% source
  # canvas puts this mark within the central 66dp safe circle, without a tile.
  artwork=$(( (canvas * 76 + 50) / 100 ))
  magick -background none "$icons/filesync-mark.svg" -resize "${artwork}x${artwork}" \
    -gravity center -extent "${canvas}x${canvas}" -depth 8 "PNG32:$directory/ic_launcher_foreground.png"
  cp "$directory/ic_launcher_foreground.png" "$directory/ic_launcher_monochrome.png"
  magick "$icons/icon.png" -resize "${size}x${size}" -depth 8 "PNG32:$directory/ic_launcher.png"
  magick "$directory/ic_launcher.png" \
    \( +clone -alpha extract -fill black -colorize 100 -fill white \
       -draw "circle $((size / 2)),$((size / 2)) $((size / 2)),0" \) \
    -alpha off -compose CopyOpacity -composite -depth 8 "PNG32:$directory/ic_launcher_round.png"
done
