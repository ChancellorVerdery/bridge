#!/usr/bin/env bash
# Build the web bundle, then the app.
#
#   ./build.sh mac     release macOS app -> build/Build/Products/Release/Bridge.app
#   ./build.sh smoke   debug build + headless self-check (no window)
set -euo pipefail
cd "$(dirname "$0")"

# mkdist.sh runs `node mkatlas.js --check`, and node lives under Homebrew. A
# login shell has it on PATH; a non-interactive one (ssh, a CI step, an agent
# running this detached) inherits /usr/bin:/bin and does not — the build then
# dies on "node: command not found", which reads as a broken toolchain rather
# than a broken PATH. Same fix, and the same reason, as Tunnel.swift's PATH
# line for ssh's ProxyCommand.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# The web "build" is a copy into dist/, because Bridge's UI is vanilla JS with no
# bundler. mkdist.sh also runs `node mkatlas.js --check`, which fails the build
# if atlas.css has drifted from a fresh verbatim extraction of Atlas's own
# styles.css — the whole point of that lift being mechanical.
../bridge-ui/mkdist.sh

# Xcode copies dist/ as a FOLDER REFERENCE, and that copy is ADDITIVE: a file
# deleted from dist/ stays inside the previously built .app forever. Atlas found
# this the hard way when a retired public/gym-import.json kept shipping after the
# repo no longer had it, with the bundle serving a file its own manifest did not
# list. Drop the copied dist so every build re-copies it exactly; object files
# are untouched, so this costs nothing.
# ...but the purge must be SCOPED TO THE CONFIGURATION BEING BUILT. Unscoped,
# `build.sh mac` also strips dist/ out of the Debug bundle and `build.sh smoke`
# strips it out of the Release one — and only the config that then gets built
# has it re-copied. The other is left as a .app whose web view has no app to
# load: it renders a completely empty window. Pass 12 hit this by accident and
# guarded the symptom in Smoke.swift; this is the cause.
case "${1:-mac}" in
  mac)   CONFIG=Release ;;
  smoke) CONFIG=Debug ;;
  *)     echo "usage: $0 [mac|smoke]" >&2; exit 2 ;;
esac
find "build/Build/Products/$CONFIG" -type d -path '*/Bridge.app/*' -name dist \
  -prune -exec rm -rf {} + 2>/dev/null || true

case "$CONFIG" in
  Release)
    xcodebuild -project Bridge.xcodeproj -scheme Bridge -configuration Release \
      -destination 'platform=macOS' -derivedDataPath build -quiet build
    echo "built: $(pwd)/build/Build/Products/Release/Bridge.app"
    ;;
  Debug)
    xcodebuild -project Bridge.xcodeproj -scheme Bridge -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build -quiet build
    ./build/Build/Products/Debug/Bridge.app/Contents/MacOS/Bridge --smoke
    ;;
esac
