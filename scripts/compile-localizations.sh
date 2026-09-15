#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# String Catalog is the translation source of truth. The command-line SwiftPM build
# consumes the generated standard .strings resources checked in beside the core assets.
xcrun xcstringstool compile Localization/Localizable.xcstrings --output-directory Sources/PolishCore/Resources/Localization
