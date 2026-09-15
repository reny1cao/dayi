#!/bin/zsh
# Add one prepared release to the Sparkle appcast served from site/appcast.xml.
# Usage: zsh scripts/update-appcast.sh v0.2.4-preview.3
# Needs the EdDSA private key in the login keychain (generate_keys) and the release
# directory produced by scripts/prepare-release.py. The archive directory under outputs/
# accumulates every published zip so generate_appcast can keep older entries.
set -euo pipefail
cd "${0:A:h:h}"
tag="${1:?release tag, e.g. v0.2.4-preview.3}"
sparkle_version="2.10.0"
sparkle_sha256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
tools="outputs/sparkle-tools/$sparkle_version"
if [[ ! -x "$tools/bin/generate_appcast" ]]; then
  mkdir -p "$tools"
  curl -fsSL -o "$tools/Sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
  echo "$sparkle_sha256  $tools/Sparkle.tar.xz" | shasum -a 256 -c -
  tar -xJf "$tools/Sparkle.tar.xz" -C "$tools"
fi
release_dir="outputs/releases/$tag"
archive=$(ls "$release_dir"/Dayi-*-macos-arm64.zip)
archives="outputs/releases/appcast"
mkdir -p "$archives"
cp "$archive" "$archives/"
[[ -f site/appcast.xml ]] && cp site/appcast.xml "$archives/appcast.xml"
"$tools/bin/generate_appcast" \
  --download-url-prefix "https://github.com/reny1cao/dayi/releases/download/$tag/" \
  --link "https://github.com/reny1cao/dayi/releases/tag/$tag" \
  "$archives"
cp "$archives/appcast.xml" site/appcast.xml
echo "site/appcast.xml updated for $tag"
