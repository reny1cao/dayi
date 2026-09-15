#!/bin/zsh
# Preserve the supplied artwork; only resample it to Apple's iconset sizes.
set -euo pipefail
cd "${0:A:h:h}"
icon_root="$PWD/outputs/icon-build"
iconset="$icon_root/Dayi.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/Dayi.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/Dayi.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$icon_root/Dayi.icns"
echo "$icon_root/Dayi.icns"
