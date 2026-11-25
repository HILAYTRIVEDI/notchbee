<div align="center">

# Notchbee

**Your AI coding agents, living in the MacBook notch.**

Start sessions, follow progress, approve tool calls and talk to your agents without leaving the app you're in.

[![License: MIT](https://img.shields.io/badge/license-MIT-3b82f6.svg)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111.svg?logo=apple)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-111111.svg)](#requirements)
[![No telemetry](https://img.shields.io/badge/telemetry-none-22c55e.svg)](PRIVACY.md)

[Download](https://github.com/HILAYTRIVEDI/notchbee/releases/latest) · [Features](#features) · [Privacy](#privacy) · [Build from source](#build-from-source) · [Contributing](CONTRIBUTING.md)

</div>

---

## Why Notchbee

Coding agents work for minutes at a time, and checking on them means switching windows over and over. Notchbee puts them in the one place on your screen that's always visible and never in the way. Hover over the notch to see what every agent is doing, answer an approval, or start the next task, then move the pointer away and carry on.

It runs a bundled local engine, works with the agents you already use, and sends **no telemetry of any kind**.

## Features

### Sessions at a glance
- **Live status in the notch.** See which agents are running, which are waiting for you, and which have finished.
- **Full threads.** Streaming replies, folded work logs (commands run, files read and edited), plans, to-dos and diffs.
- **A clear "thinking" state**, so you always know when the model is working.

### Start work from anywhere
- **New session** in a quick scratch space or any project, with provider, model and permission mode chosen up front.
- **Open folder…** turns any folder on your Mac into a project in one step.
- **Switch models mid-thread**, and use the provider's `/` commands and skills straight from the composer.

### Stay in control
- **Approvals in the notch.** Review each tool request and accept it with <kbd>⌘</kbd> <kbd>↵</kbd> once you've had time to read it.
- **Workspace actions.** Check the branch, switch branches, commit, open a pull request, or open the project in your editor.
- **Usage page.** Provider quotas and spend, read from your own machine.

### Voice, on your Mac
- **On-device dictation** using Core ML speech models, with Apple Speech as a fallback.
- **Live transcription.** Words appear in the input box as you speak. Press <kbd>Return</kbd> to stop and send in one step.
- **Dictation anywhere.** <kbd>⌃</kbd> <kbd>⌘</kbd> <kbd>J</kbd> dictates into any app. Add <kbd>⇧</kbd> to clean up the text, or <kbd>⌥</kbd> for agent-assisted dictation.
- **Voice commands.** Hold <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>V</kbd> to tell an agent what to do.

## Supported agents

| Agent | How it connects |
| --- | --- |
| **Codex** | Your installed Codex CLI |
| **Claude** | Claude Agent SDK, downloaded only after you approve it |
| **Cursor** | Cursor SDK with your API key, downloaded only after you approve it |
| **OpenCode** | Your local OpenCode server |
| **Grok, Antigravity, Kiro, Pi, Muse, fx** | Their CLIs, through the Agent Client Protocol |

You bring your own accounts and subscriptions. Notchbee never sees your provider credentials beyond what each agent's own tooling needs on your Mac.

## Privacy

Notchbee is built on one rule: **your work stays yours.**

- **No telemetry, analytics or crash reporting.** The upstream engine's analytics were removed, and a build-time check stops them from coming back.
- **Local by default.** Chat history, usage summaries and logs are stored only on your Mac.
- **Speech stays on-device.** Dictation models run locally.
- **No bundled proprietary code.** The Claude and Cursor SDKs are downloaded from npm only after you review the vendor's terms, then verified against pinned SHA-512 hashes and installed without running scripts.

Your prompts go only to the provider you choose. Those providers, and their own SDKs, handle data under their own policies. Cursor's SDK, for example, may send usage events to Cursor. Read the full [privacy policy](PRIVACY.md) and the [network inventory](engine/NETWORK.md), which lists every host the engine can contact and why.

## Requirements

- A Mac with Apple Silicon and a notch-style menu bar
- macOS 26 or later
- At least one supported agent, such as the Codex CLI or a Claude or Cursor account

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/HILAYTRIVEDI/notchbee/releases/latest).
2. Drag **Notchbee** to **Applications** and open it.
3. Builds are not yet notarized by Apple. If macOS blocks the first launch, open **System Settings → Privacy & Security** and click **Open Anyway**. See [Apple's guide](https://support.apple.com/en-us/102445).
4. Hover over the notch, open **Settings → Providers**, and connect an agent.

## Build from source

You need **Xcode 26.3+**, **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** and **[Bun](https://bun.sh) 1.4.1**.

```sh
git clone https://github.com/HILAYTRIVEDI/notchbee.git
cd notchbee
xcodegen generate --spec Notchpilot/project.yml
xcodebuild -project Notchpilot/Notchpilot.xcodeproj -scheme Notchpilot \
  -configuration Release -disableAutomaticPackageResolution \
  -derivedDataPath build/xcode build
open build/xcode/Build/Products/Release/Notchbee.app
```

The build bundles the engine automatically. Run the core tests with `swift test --package-path NotchpilotCore`. See [local signing](docs/signing.md) and [release packaging](docs/release.md) for distributable builds.

## How it works

```
┌──────────────────────────┐   WebSocket on 127.0.0.1   ┌──────────────────────────┐
│  Notchbee (Swift, AppKit │ ◀────────────────────────▶ │  Bundled engine (Bun)    │
│  + SwiftUI notch panel)  │   random port + one-time   │  sessions · git · usage  │
└──────────────────────────┘          secret            └────────────┬─────────────┘
                                                                     │
                                          Codex · Claude · Cursor · OpenCode · ACP agents
```

The app starts a private engine process when it launches. The engine listens only on localhost, behind a secret that's passed over a pipe and never written to disk. It normalizes every agent into one event stream for the notch to display.

| Path | Contents |
| --- | --- |
| `Notchpilot/` | The macOS app: notch panel, settings and voice |
| `NotchpilotCore/` | Swift package: state, engine client and supervisor, speech (with tests) |
| `engine/` | The bundled engine, a patched fork of T3 Code, plus its patch series |
| `scripts/` | Engine build, privacy and branding checks, release tooling |
| `docs/` | Protocol notes, QA checklist, signing and release |

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) first. To report a security issue privately, see [SECURITY.md](SECURITY.md).

## License and credits

Notchbee is released under the [MIT License](LICENSE).

The bundled engine is a modified fork of [T3 Code](https://github.com/pingdotgg/t3code) by T3 Tools Inc., used under its [MIT license](engine/LICENSE). Details of the changes are in [engine/UPSTREAM.md](engine/UPSTREAM.md). Speech models and other components are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Notchbee is an independent project and is not affiliated with OpenAI, Anthropic, Anysphere (Cursor) or T3 Tools Inc.
