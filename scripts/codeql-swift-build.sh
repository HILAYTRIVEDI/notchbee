#!/bin/bash
# Builds the app for CodeQL's Swift extractor. A stub stands in for the engine helper,
# because CodeQL analyzes the engine's TypeScript separately and needs no Bun build.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build/engine"
printf '#!/bin/sh\nexit 1\n' > "$root/build/engine/notchbee-engine"
chmod +x "$root/build/engine/notchbee-engine"
echo "Stub engine for static analysis." > "$root/build/engine/THIRD_PARTY_NOTICES"
cd "$root/Notchpilot"
xcodegen generate
xcodebuild -project Notchpilot.xcodeproj -scheme Notchpilot -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath "$root/build/codeql" \
  CODE_SIGN_IDENTITY=- build
swift build --package-path "$root/NotchpilotCore" --build-tests
