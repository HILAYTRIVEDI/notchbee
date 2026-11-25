# Changelog

Notable changes to Notchbee. Versions follow [Semantic Versioning](https://semver.org).

## 1.0.0 — 2026-11-26

First public release.

### Added

- Notch panel with live status for every agent session: running, waiting for you, or finished.
- Full threads with streaming replies, folded work logs, plans, to-dos and diffs.
- New sessions in a scratch space or any project, with provider, model and permission mode chosen up front. **Open folder…** adds any folder as a project.
- Model switching mid-thread and provider `/` commands and skills in the composer.
- Tool approvals in the notch, accepted with ⌘↵.
- Workspace actions: branch status and switching, commit, open a pull request, open in editor.
- Usage page with provider quotas and spend, read locally.
- On-device dictation with Core ML speech models and an Apple Speech fallback, dictation into any app (⌃⌘J) and voice commands (⌃⌥⌘V).
- Providers: Codex, Claude (Agent SDK), Cursor (SDK), OpenCode, and Grok, Antigravity, Kiro, Pi, Muse and fx through the Agent Client Protocol.
- Bundled local engine, a patched fork of T3 Code 0.1.9, listening only on loopback behind a one-time secret.
- Sparkle updates from GitHub Releases.

### Privacy

- No telemetry, analytics or crash reporting. A build-time check blocks reporting code in the engine.
- The Claude and Cursor SDKs are downloaded only after consent, verified against pinned SHA-512 hashes and installed unmodified.

### Known limitations

- Builds are ad-hoc signed and not notarized. macOS asks you to approve the first launch.
- Apple Silicon and macOS 26 or later only.
