#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
zsh scripts/compile-localizations.sh
zsh scripts/build-icon.sh >/dev/null
polish_bin_dir="$(swift build -c release --show-bin-path)"
# SwiftPM's incremental resource copy leaves retired files behind. Rebuild this generated
# bundle so removed templates cannot enter the signed app through an old build cache.
rm -rf "$polish_bin_dir/TextPolish_PolishCore.bundle"
swift build -c release --product TextPolishApp
final_app="$PWD/outputs/Dayi.app"
# Build into a staging bundle and swap directories at the end. Overwriting the executable
# in place invalidates the pages of a running instance and the kernel kills it with
# "Code Signature Invalid"; a renamed directory keeps the old inodes alive until it exits.
polish_app="$PWD/outputs/Dayi.app.staging"
rm -rf "$polish_app"
mkdir -p "$polish_app/Contents/MacOS" "$polish_app/Contents/Resources"
cp "$polish_bin_dir/TextPolishApp" "$polish_app/Contents/MacOS/TextPolishApp"
cp outputs/icon-build/Dayi.icns "$polish_app/Contents/Resources/Dayi.icns"
cp Assets/Dayi.png "$polish_app/Contents/Resources/Dayi.png"
cp THIRD_PARTY_NOTICES.md "$polish_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto docs/licenses "$polish_app/Contents/Resources/Licenses"
python3 - "$polish_app/Contents/Resources/build-receipt.json" <<'PY'
import json, pathlib, subprocess, sys
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
dirty = bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], text=True).strip())
pathlib.Path(sys.argv[1]).write_text(json.dumps({'commit': commit, 'tracked_changes': dirty}, indent=2) + '\n')
PY
# Signed macOS applications keep their resources inside Contents/Resources. GRDB ships a
# privacy manifest as its own bundle; it belongs in the app even though nothing reads it
# at runtime.
ditto "$polish_bin_dir/TextPolish_PolishCore.bundle" "$polish_app/Contents/Resources/TextPolish_PolishCore.bundle"
ditto "$polish_bin_dir/GRDB_GRDB.bundle" "$polish_app/Contents/Resources/GRDB_GRDB.bundle"
cat > "$polish_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.local.dayi</string>
<key>CFBundleName</key><string>Dayi</string>
<key>CFBundleDisplayName</key><string>达意</string>
<key>CFBundleIconFile</key><string>Dayi</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleExecutable</key><string>TextPolishApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.4</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Declare both app languages so AppKit's standard menus use the same language as
# the core resource bundle. A saved app-language override takes effect next launch.
for polish_language in zh-Hans en; do
    mkdir -p "$polish_app/Contents/Resources/$polish_language.lproj"
    cp "Localization/$polish_language.lproj/InfoPlist.strings" "$polish_app/Contents/Resources/$polish_language.lproj/InfoPlist.strings"
done

# TCC records the app's designated requirement when Accessibility is granted. An
# ad-hoc signature pins the cdhash, so every rebuild invalidates the grant; a
# Developer ID signature pins the certificate and survives rebuilds. Override with
# POLISH_SIGN_IDENTITY; ad-hoc remains the fallback where no identity is installed.
sign_identity="${POLISH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$sign_identity" ]]; then
  print -u2 'warning: no Developer ID identity; signing ad-hoc. Accessibility must be re-granted after every build.'
  codesign --force --sign - "$polish_app"
else
  codesign --force --options runtime --timestamp --sign "$sign_identity" "$polish_app"
fi
codesign --verify --strict "$polish_app"
rm -rf "$final_app.previous"
[[ -d "$final_app" ]] && mv "$final_app" "$final_app.previous"
mv "$polish_app" "$final_app"
rm -rf "$final_app.previous"
polish_app="$final_app"
echo "Packaged: $polish_app"
