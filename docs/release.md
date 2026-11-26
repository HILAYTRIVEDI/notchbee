# Releasing Notchbee

When dependencies change, update [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and the files in `licenses/` before publishing an app build.

`scripts/release.sh` builds a Release `Notchbee.app`, signs it inside-out, optionally notarizes and staples it, and writes `build/release/Notchbee-<version>-<build>.dmg` (app plus an `/Applications` link) and a signed Sparkle `appcast.xml`.

```sh
export NOTCHBEE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTCHBEE_NOTARY_PROFILE="notchbee-notary"
# SPARKLE_FEED_URL defaults to the GitHub Releases appcast; export it only to use another host
scripts/release.sh
```

Without `NOTCHBEE_SIGN_IDENTITY` the script signs ad hoc (hardened runtime, no secure timestamp) and warns. Without `NOTCHBEE_NOTARY_PROFILE` it skips notarization and stapling with a warning. Gatekeeper normally blocks quarantined ad-hoc builds. See the [installation instructions](../README.md#install) for local development copies.

Signing order: `Contents/Helpers/notchbee-engine` (identifier `com.hilaytrivedi.Notchbee.engine`, entitlements `allow-jit` and `disable-library-validation` from `Notchpilot/Engine.entitlements`), then the nested frameworks, XPC services and helpers (Sparkle), then the app. All use the hardened runtime.

## Create a Developer ID certificate

Requires a paid Apple Developer Program membership.

1. Xcode → Settings → Accounts → select your team → Manage Certificates → `+` → **Developer ID Application**. (Or create it at developer.apple.com → Certificates and download it into Keychain Access.)
2. Find the identity name: `security find-identity -v -p codesigning`. Use the full `Developer ID Application: … (TEAMID)` string as `NOTCHBEE_SIGN_IDENTITY`.

## Create a notary profile

1. Create an app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords.
2. Store credentials in the login Keychain:
   ```sh
   xcrun notarytool store-credentials notchbee-notary \
     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
   ```
3. Use the profile name as `NOTCHBEE_NOTARY_PROFILE`.

## Sparkle updates

- The EdDSA public key is in `Notchpilot/Sources/Resources/Info.plist` (`SUPublicEDKey`). The private key lives only in the login Keychain (account `Notchbee`, created by Sparkle's `generate_keys --account Notchbee`). Back it up with `generate_keys --account Notchbee -x <file>` and keep that file private. If it is lost, installed copies can never accept an update. `release.sh` refuses to run if the Keychain key does not match `SUPublicEDKey`.
- The feed URL is the `SPARKLE_FEED_URL` build setting: `https://github.com/HILAYTRIVEDI/notchbee/releases/latest/download/appcast.xml`. Installed apps always read the `appcast.xml` attached to the newest GitHub Release, and its download link points at the `.dmg` in that same release. **For each release, create a GitHub Release and attach both `Notchbee-<version>-<build>.dmg` and `appcast.xml`.** The repository must be public for this URL to work.
- `release.sh` runs `generate_appcast`, which signs the `.dmg` and writes `build/release/appcast.xml`. The enclosure URLs are `<feed directory>/<dmg name>`. Upload the `.dmg` and `appcast.xml` to that directory. Bump `CFBundleVersion` (and `CFBundleShortVersionString`) in `Info.plist` before each release; Sparkle compares `CFBundleVersion`.
- Release notes come from `docs/release-notes/<version>.md`. `release.sh` embeds that file in the appcast, and the same text is the GitHub Release description.

## Publish a release

Releases are built and uploaded by hand. CI does not publish them because the Sparkle private key stays in the maintainer's login Keychain.

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Notchpilot/Sources/Resources/Info.plist`, add `docs/release-notes/<version>.md` and a `CHANGELOG.md` entry, and commit.
2. Run `scripts/release.sh` on an Apple Silicon Mac with Xcode, XcodeGen, Bun 1.4.1 and `uv`.
3. Tag the commit and create the release. The extra `Notchbee.dmg` copy keeps the website's Download link (`releases/latest/download/Notchbee.dmg`) pointing at the newest version:
   ```sh
   git tag v<version> && git push origin v<version>
   cp build/release/Notchbee-<version>-<build>.dmg build/release/Notchbee.dmg
   gh release create v<version> --title "Notchbee <version>" \
     --notes-file docs/release-notes/<version>.md \
     build/release/Notchbee-<version>-<build>.dmg build/release/Notchbee.dmg build/release/appcast.xml
   ```
4. Check that `https://github.com/HILAYTRIVEDI/notchbee/releases/latest/download/appcast.xml` serves the new appcast, then update an installed older copy from **Check for Updates…**.
