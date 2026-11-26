# Building and signing Notchbee

Run these commands from the repository root. XcodeGen preserves the workspace's checked-in `Package.resolved`. The build flag requires Xcode to use those revisions.

```sh
xcodegen generate --spec Notchpilot/project.yml
xcodebuild -project Notchpilot/Notchpilot.xcodeproj -scheme Notchpilot \
  -configuration Release -disableAutomaticPackageResolution \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Notchbee" build
```

List valid signing identities with `security find-identity -v -p codesigning`. If an Apple Development identity is available, put its certificate fingerprint and team ID in the gitignored `Notchpilot/LocalSigning.xcconfig` before building.

```xcconfig
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = YOUR_CERTIFICATE_FINGERPRINT
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

The Release build enables the hardened runtime with the audio-input entitlement. Notchbee starts and authenticates its own helper using an in-memory session. See the release instructions for signing the embedded helper and Sparkle components.

For distribution builds (Developer ID signing, notarization, DMG, Sparkle appcast) see [release.md](release.md).
