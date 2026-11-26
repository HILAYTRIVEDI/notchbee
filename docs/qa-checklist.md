# Notchbee QA checklist

This checklist records macOS 26.3 and Xcode 26.6 test results. The replay and reducer coverage uses synthetic fixtures.

| Check | Status | Evidence or remaining check |
| --- | --- | --- |
| Idle, running, done, error and disconnected states | PASS | Reducer tests and synthetic streams covered state transitions, completion, error handling and hover sizing. |
| Approval, sessions, voice and dictating states | PASS | Reducer, backend and controller tests covered state priority, approval queues, sessions and transitions into and out of voice. |
| Hover expand and collapse on a physical notch | PASS | The old 223 × 32 pt frame missed center entry from below. The installed Release expanded from 223 × 42 to 531 × 632 pt on entry from below and returned to compact on exit. Verified with cursor warps, WindowServer bounds and cropped screenshots. |
| Transparent corners and camera exclusion | PASS | Geometry regression test rejects points in the rounded corner, camera housing and outside the compact frame. |
| Transparent corners pass a real click to the app underneath | NEEDS-HUMAN | Click through a rounded corner into a scratch window. Synthetic event posting was unavailable. |
| Idle CPU | PASS | The installed app sampled at 0.0–0.1% CPU after model warm-up with the pointer outside the notch. |
| Sessions list and search, Active/Archived/All | NEEDS-HUMAN | Fixture decoding and archive state passed. Exercise the list, search and filters with scratch rows in the UI. |
| Thread timeline | PASS | Fixture replay and reducer tests covered streaming text and tools, ordering and visibility subscriptions. |
| Composer | PASS | AppKit editor tests covered caret placement and undo. Sent a prompt to a scratch Fake thread and checked the resulting timeline. |
| Composer mic button | PASS | Exercised the controller start/stop wired to the button, partial replacement, permission denial and final editor text. The physical click and mic check is below. |
| New thread | PASS | Sent AppKit clicks to the actual notch panel in a hosted test with the editor focused. The live server ran the first prompt for Codex and Claude and the Thread view received both replies. Both prompts began with a whitespace-only line. Archived and deleted the scratch threads. Physical clicks in the installed Release remain a manual check. |
| Stop thread | PASS | Stopped the scratch run and checked interrupted status and approval withdrawal. |
| Archive and unarchive | PASS | Checked both transitions on the scratch thread and reducer behavior for an open archived thread. |
| Rename | PASS | Renamed the scratch thread and checked the projected title. |
| Delete | PASS | Deleted the scratch thread and checked that the row and selected thread cleared. |
| Thread controls in the live UI | NEEDS-HUMAN | Exercise buttons, confirmation dialogs and the picker flow against a disposable live thread. Integration coverage used a Fake backend. |
| Approve, deny and stale approval | PASS | Fake backend exercised both decisions. Synthetic fixtures covered stale approval, correlated command text and multiple requests. The isolated websocket fixture accepted an approval after reconnect. |
| Approval shortcuts, ⌘↩ and Esc | NEEDS-HUMAN | Check ⌘↩ with pointer over the approval panel and with no composer editing. Check Esc collapses or cancels without approving, while an out-of-scope shortcut reaches the foreground app. |
| Voice command review and manual Send | PASS | Push-to-talk test held the draft in review without sending, then submitted to the scratch backend. Against the live server, routed a `new thread` transcript from a scratch Claude thread, submitted the reviewed draft and received the reply in the Thread view. |
| Speech download, persistence and reuse | PASS | Started with an empty cache. One real pinned download installed 13 files, about 595 MiB, in the 0700 Models directory. Three captures through the production controller and Parakeet with synthesized PCM returned the expected transcript. Captures 2 and 3 reached the audio source in 1.49 ms and 0.37 ms. No model preparation or download recurred. A fresh engine loaded the verified cache without downloading. |
| Cancel during preparation and verify installed files | PASS | Regression tests confirmed the next capture joins the existing job. Relative-path verification accepts a valid compiled bundle through macOS path aliases and rejects tampering or a symlink. |
| Raw dictation | PASS | Mode-selection logic and real Parakeet transcript on fixture audio passed. Live TextEdit insertion is tracked below. |
| Clean dictation | PASS | Tests covered the T3 cleanup request and raw-text fallback for an empty response, failure or timeout. |
| Agent dictation | PASS | Tests covered limiting context and correlating the answer to the dispatched message and run. Live review, Send and Insert Result are tracked below. |
| Clipboard restoration | PASS | Tests covered preserving all items and types, restoring after paste failure, and preserving clipboard changes made during paste. |
| Secure-field refusal | PASS | Tests covered secure role, subrole and Secure Keyboard Entry. |
| Live dictation into TextEdit and physical microphone | NEEDS-HUMAN | Opened a scratch TextEdit document. AX returned -25211 and CGEvent posting permission was unavailable. Exercise Raw insertion, Clean success, Agent review and result insertion, then force clipboard paste and check restoration. Try the mic button and verify a real secure field refuses recording. |
| Settings and hotkeys | NEEDS-HUMAN | Check recorder validation, Raw/Clean/Agent modifier variants, menu show/hide, startup expansion, login item and per-app paste overrides through the UI. |
| Reconnect and resync via fixture | PASS | Isolated replay fixture dropped the websocket with code 1012. Notchpilot reconnected and received and resolved a fresh approval. Reducer tests covered resync. |
| M1 hardware verification | NEEDS-HUMAN | Repeat the live server and CoreML checks on an M1 Mac. This run used an M2. |
| No-notch pill | PASS | Synthetic notchless display test covered anchoring below the menu bar, fitted size and hit-testing. |
| Multi-display and physical no-notch display | NEEDS-HUMAN | One display was present. Attach an external display, move focus between screens and Spaces, and check placement, pill hover and fullscreen. |

## Build and installation

- `xcodebuild build` passed.
- `xcodebuild test` passed 10 tests.
- `swift test --package-path NotchpilotCore` passed 41 tests.
- The Release build passed using the requested DerivedData directory. The installed bundle passed strict signature verification and retained hardened runtime and the audio-input entitlement. Notchpilot was left running in Live mode.
