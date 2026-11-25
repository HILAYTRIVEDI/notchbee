#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$HOME/Library/Developer/Xcode/DerivedData/Notchbee"
release="$root/build/release"
identity="${NOTCHBEE_SIGN_IDENTITY:--}"
profile="${NOTCHBEE_NOTARY_PROFILE:-}"
if [[ "$identity" == "-" ]]; then
  echo "WARNING: Using ad-hoc signing. Set NOTCHBEE_SIGN_IDENTITY for distribution." >&2
  stamp=--timestamp=none
else
  stamp=--timestamp
fi
if [[ -z "$profile" ]]; then
  echo "WARNING: NOTCHBEE_NOTARY_PROFILE unset. Skipping notarization and stapling." >&2
elif [[ "$identity" == "-" ]]; then
  echo "Notarization requires a Developer ID Application identity." >&2
  exit 1
fi

cd "$root/Notchpilot"
xcodegen generate
settings=()
if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then settings+=("SPARKLE_FEED_URL=$SPARKLE_FEED_URL"); fi
xcodebuild -project Notchpilot.xcodeproj -scheme Notchpilot -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  CODE_SIGN_IDENTITY=- "${settings[@]+"${settings[@]}"}" build
app="$derived/Build/Products/Release/Notchbee.app"
plist="$app/Contents/Info.plist"
sparkle="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
feed="$(plutil -extract SUFeedURL raw "$plist")"
[[ "$feed" == https://* ]] || { echo "Expected an HTTPS feed URL." >&2; exit 1; }
feed_host="${feed#https://}"; feed_host="${feed_host%%/*}"
if [[ "$feed_host" == *.invalid || "$feed_host" == example.* || "$feed_host" == *.example.* ]]; then
  echo "SPARKLE_FEED_URL is still a placeholder ($feed). Set it to the public appcast URL." >&2; exit 1
fi
[[ "$("$sparkle/generate_keys" --account Notchbee -p)" == "$(plutil -extract SUPublicEDKey raw "$plist")" ]] || {
  echo "The Notchbee Sparkle key in the login Keychain must match SUPublicEDKey." >&2; exit 1;
}

sign() { codesign --force --sign "$identity" "$stamp" --options runtime "$@"; }
sign --identifier com.hilaytrivedi.Notchbee.engine --entitlements Engine.entitlements "$app/Contents/Helpers/notchbee-engine"
while IFS= read -r -d '' item; do
  sign --preserve-metadata=identifier,entitlements "$item"
done < <(find "$app/Contents/Frameworks" -depth \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -o -type f \( -name Autoupdate -o -name '*.dylib' \) \) -print0)
app_entitlements="$PWD/Sources/Resources/Notchpilot.entitlements"
if [[ "$identity" == "-" ]]; then
  # Ad-hoc signatures carry no Team ID, so hardened-runtime library validation rejects the embedded
  # Sparkle framework. A Developer ID build shares one Team ID and keeps validation on.
  app_entitlements="$(mktemp "${TMPDIR:-/tmp}/notchbee-entitlements.XXXXXX")"
  cp Sources/Resources/Notchpilot.entitlements "$app_entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$app_entitlements"
fi
sign --entitlements "$app_entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p "$release"
stage="$(mktemp -d "$release/.release.XXXXXX")"
trap 'rm -rf "$stage"; if [[ "$app_entitlements" == "${TMPDIR:-/tmp}"/notchbee-entitlements.* ]]; then rm -f "$app_entitlements"; fi' EXIT
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
  xcrun stapler staple "$2"
  xcrun stapler validate "$2"
}
if [[ -n "$profile" ]]; then
  ditto -c -k --keepParent "$app" "$stage/submit.zip"
  notarize "$stage/submit.zip" "$app"
  rm "$stage/submit.zip"
fi
version="$(plutil -extract CFBundleShortVersionString raw "$plist")"
build="$(plutil -extract CFBundleVersion raw "$plist")"
name="Notchbee-$version-$build.dmg"
uvx --from dmgbuild==1.6.7 dmgbuild -s "$root/scripts/dmg-settings.py" -D "app=$app" Notchbee "$stage/$name"
if [[ "$identity" != "-" ]]; then codesign --sign "$identity" "$stamp" "$stage/$name"; fi
if [[ -n "$profile" ]]; then notarize "$stage/$name" "$stage/$name"; fi
notes="$root/docs/release-notes/$version.md"
appcast_args=()
if [[ -f "$notes" ]]; then
  cp "$notes" "$stage/${name%.dmg}.md"
  appcast_args+=(--embed-release-notes)
else
  echo "WARNING: $notes not found. The update will have no release notes." >&2
fi
"$sparkle/generate_appcast" --account Notchbee --maximum-deltas 0 --download-url-prefix "${feed%/*}/" \
  "${appcast_args[@]+"${appcast_args[@]}"}" "$stage"
grep -q 'sparkle:edSignature=' "$stage/appcast.xml"
mv "$stage/$name" "$release/$name"
mv "$stage/appcast.xml" "$release/appcast.xml"
stat -f '%z bytes %N' "$release/$name"
