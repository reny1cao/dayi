# Dayi artwork

The project owner selected the supplied transparent black PNG on 2026-09-11. `Dayi.png` is a byte-for-byte copy of that 1024×1024 attachment. Its visible bounds are x=141…883, y=94…929.

`Dayi-reverse.svg` is the matching previously prepared R6 reverse mark, reused for README dark mode. The PNG is the authoritative app icon input. No AI regeneration or geometry redraw was performed in this release task.

`scripts/build-icon.sh` uses macOS sips/iconutil to resample the PNG into standard 16–1024 iconset entries. The app's idle menu-bar mark is a template image, so macOS chooses its foreground color; warning/running/attention states retain their existing status glyphs. The supplied transparent icon remains transparent; a future app-tile treatment would be a separate design decision.

Brand redistribution terms remain part of the owner's public-release licensing review.
27c4771df256b1e37d1f8c08fcf87b530d4fed7f08200c525fc76318abac4021  Assets/Dayi.png
