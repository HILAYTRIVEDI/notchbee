#!/bin/bash
set -euo pipefail

root="$(cd "$SRCROOT/.." && pwd)"
output="$root/build/engine"
binary="$output/notchbee-engine"
notices="$output/THIRD_PARTY_NOTICES"
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ ! -x "$binary" || ! -s "$notices" ]] ||
    [[ -n "$(find "$root/engine" "$root/scripts" -type d \( -name node_modules -o -name .git \) -prune -o -type f -newer "$binary" -print -quit)" ]]; then
  "$root/scripts/build-engine.sh"
fi

bun "$root/scripts/check-engine-privacy.ts" "$binary"

helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$helpers" "$resources"
install -m 755 "$binary" "$helpers/notchbee-engine"
install -m 644 "$root/LICENSE" "$resources/LICENSE"
install -m 644 "$root/licenses/engine-speech-models.md" "$resources/engine-speech-models.md"
{
  cat "$root/THIRD_PARTY_NOTICES.md"
  printf '\n'
  cat "$notices"
  printf '\n'
  cat "$root/licenses/engine-dependencies.txt"
  printf '\n'
  cat "$root/licenses/native-binaries.md"
  printf '\n--- JavaScriptCore LGPL ---\n\n'
  cat "$root/licenses/javascriptcore-lgpl.txt"
} > "$resources/THIRD_PARTY_NOTICES"

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=()
if [[ "$identity" == "-" ]]; then timestamp=(--timestamp=none); fi
/usr/bin/codesign --force --sign "$identity" --identifier com.hilaytrivedi.Notchbee.engine --options runtime "${timestamp[@]}" \
  --entitlements "$SRCROOT/Engine.entitlements" "$helpers/notchbee-engine"
