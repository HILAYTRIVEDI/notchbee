# Third-party notices

Notchbee's original code is MIT licensed. Bundled components and downloaded assets retain the terms below. In the app, the notice is available in **Settings → Engine & About → Open-source licenses** and in `Contents/Resources/THIRD_PARTY_NOTICES`.

## Built-in engine

- **T3 Code v0.1.9** — Copyright (c) 2026 T3 Tools Inc., MIT. The engine is a [modified fork](engine/UPSTREAM.md). The [upstream license](engine/LICENSE) accompanies the engine in source and binary distributions.
- **Bun 1.4.1** — MIT with third-party runtime libraries. Bun statically links JavaScriptCore/WebKit under the GNU Lesser General Public License. See the [corresponding Bun source at 4661e494f052c83c80dade1318e5710238340be6](https://github.com/oven-sh/bun/tree/4661e494f052c83c80dade1318e5710238340be6), [patched WebKit source at 6119947592b6e1c1faef02a4c2e03174cf05d062](https://github.com/oven-sh/WebKit/tree/6119947592b6e1c1faef02a4c2e03174cf05d062), [JavaScriptCore LGPL text](licenses/javascriptcore-lgpl.txt) and [Bun’s versioned license inventory](https://github.com/oven-sh/bun/blob/4661e494f052c83c80dade1318e5710238340be6/LICENSE.md). The Bun inventory also lists TinyCC under LGPL 2.1.
- **Bundled npm modules** — The build emits names, versions, declared licenses and available license files for modules in the executable or its native archive. Supplemental notices for package texts are in [licenses/engine-dependencies.txt](licenses/engine-dependencies.txt).
- **Staged native packages** — The archive contains the Apple Silicon packages and helpers for `node-pty`, `ffi-rs` and FFF workspace search (all MIT). Their prebuilt binaries embed Rust crates and C libraries, including libgit2 (GPL-2.0 with the linking exception), LMDB (OpenLDAP Public License) and libffi. The full inventory and license texts are in [licenses/native-binaries.md](licenses/native-binaries.md). See also the [native staging script](scripts/stage-engine-natives.ts).

### Rebuild with a modified runtime

You may modify the LGPL libraries and reverse engineer the linked engine for debugging those modifications. Use the corresponding source and Bun’s versioned build instructions to compile Bun with your modified WebKit. On Apple Silicon, keep Bun 1.4.1 on PATH as the build tool, then run `NOTCHBEE_BUN_RUNTIME=/absolute/path/to/your/bun scripts/build-engine.sh` from the matching Notchbee source checkout. This embeds your runtime in the rebuilt helper. Rebuild the app to package and sign that helper, or use it as a standalone engine. See [engine build instructions](engine/BUILD.md).

### Provider SDK downloads

- **Claude Agent SDK 0.3.330** (`@anthropic-ai/claude-agent-sdk`) is provided by Anthropic under its [license and terms](https://code.claude.com/docs/en/legal-and-compliance). The SDK uses the user’s separately installed Claude Code executable.
- **Cursor SDK 1.2.0** (`@cursor/sdk` and `@cursor/sdk-darwin-arm64`) is provided by Anysphere under [Cursor’s terms](https://cursor.com/terms-of-service). Notchbee does not bundle or modify it; the user downloads the unmodified package after accepting Cursor’s terms.

These SDKs and Cursor's SDK runtime dependencies are downloaded from npm only after in-app consent. They are excluded from the distributed engine and app.

The source import also carries generated schemas. The Codex protocol is generated from [OpenAI Codex](https://github.com/openai/codex/blob/main/LICENSE) (Apache-2.0), and the GitHub integration uses [GitHub’s public GraphQL schema](https://docs.github.com/en/graphql/overview/public-schema). Provider executables that users install separately carry their own terms.

## macOS dependencies

| Component | License and attribution |
| --- | --- |
| [FluidAudio 0.18.4](https://github.com/FluidInference/FluidAudio/tree/e0c6103bc87a88d25276cad491c86e757f58c865) | Apache-2.0. Includes fastcluster (BSD-2-Clause, Daniel Müllner and Google Inc.). |
| [KeyboardShortcuts 3.1.0](https://github.com/sindresorhus/KeyboardShortcuts/tree/772133d9dbe800fdac0473226822994c5c162c58) | MIT, Sindre Sorhus. |
| [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/tree/ab7d71291238df6e0492143b120c9b696a35f603) | Sparkle's permissive license and bundled component notices, including bsdiff, bspatch, Ed25519 and signature verification code. |

The pinned SwiftPM graph has no additional external package pins. FluidAudio's default optional NeMo, TTS and diarization traits are disabled in the XcodeGen project. Its ASR build links the fastcluster wrapper and the platform wrapper. The shipped Swift dependency license texts are in [the base bundle notice](engine/THIRD_PARTY_NOTICES).

## On-device speech downloads

Notchbee downloads the following models directly from the listed Fluid Inference repositories when needed. The DMG does not include the model weights. Notchbee verifies selected files and loads them as published by Fluid Inference. NVIDIA supplies the original Parakeet models and Fluid Inference supplies the Core ML conversions.

| Model and source | Attribution and license |
| --- | --- |
| [Parakeet Unified English 0.6B Core ML](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/tree/d32e972dd4315f1dc3f6be28fb2aab0ab3e80358) | NVIDIA Parakeet Unified EN 0.6B, Core ML conversion and quantized encoder by Fluid Inference, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). |
| [Parakeet CTC 110M Core ML](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml/tree/accdafd8cf8a2ff1cabe3c11e54416b405d409aa) | NVIDIA Parakeet CTC 110M, Core ML conversion by Fluid Inference. Used for vocabulary boosting. [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). |

Apple Speech fallback assets are managed and downloaded by macOS. The native voice controls do not download Whisper weights. The authenticated engine protocol retains an [optional GGUF catalog and download endpoints](licenses/engine-speech-models.md), including OpenAI Whisper conversions (the pinned GGUF cards declare Apache-2.0, and [OpenAI’s original release is MIT](https://github.com/openai/whisper/blob/main/LICENSE)) and Silero VAD (MIT). Those model weights are absent from the app bundle and its engine has no native inference backend. Configured cloud speech uses the provider’s endpoint.
