# T3 Code local WebSocket protocol

Notchbee uses orchestration protocol 2 from its [bundled engine fork](../engine/UPSTREAM.md). Release builds start and verify their own engine on IPv4 loopback.

## Connection and authentication

1. The app launches the helper on an OS-assigned port and sends a random bootstrap secret over an inherited descriptor. It validates the runtime record and checks that the child owns the listener.
2. The app exchanges the bootstrap proof at `/oauth/token` for an in-memory bearer with scoped permissions.
3. POST `/api/auth/websocket-ticket/rpc` with the bearer, then open `/ws?orchestrationProtocol=2&wsTicket=<ticket>` on the verified origin. The ticket is short-lived and scoped to RPC.


Source paths

- Runtime discovery and port selection · `apps/server/src/config.ts`, `apps/server/src/serverRuntimeState.ts`, `apps/desktop/src/app/DesktopApp.ts`
- Bootstrap and credential issuance · `apps/desktop/src/backend/DesktopBackendConfiguration.ts`, `apps/desktop/src/backend/DesktopLocalEnvironmentAuth.ts`, `apps/web/src/environments/primary/auth.ts`, `apps/server/src/cli/auth.ts`, `apps/server/src/auth/SessionStore.ts`, `apps/server/src/persistence/AuthSessions.ts`
- Upgrade and browser ticket flow · `packages/contracts/src/environment.ts`, `packages/contracts/src/environmentHttp.ts`, `apps/server/src/auth/EnvironmentAuth.ts`, `apps/server/src/auth/RpcAuthorization.ts`, `apps/server/src/ws.ts`, `packages/client-runtime/src/authorization/remote.ts`

## Frames and subscriptions

The socket uses Effect RPC with JSON text frames. A request has a connection-local string ID. The method is in `tag` and the method input is in `payload`.

```json
{"_tag":"Request","id":"1","tag":"orchestration.subscribeShell","payload":{},"headers":[]}
```

- A unary response is `{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"sequence":42}}}` for a successful dispatch. Failures have `exit._tag: "Failure"` and an encoded `exit.cause`. Decode the cause for a typed server error.
- A stream has zero or more `{"_tag":"Chunk","requestId":"1","values":[...]}` frames and an `Exit` when it terminates. Process every value in order, then send one `{"_tag":"Ack","requestId":"1"}` per chunk for flow control. A client can send `{"_tag":"Ping"}` and receive `{"_tag":"Pong"}`.
- RPC request IDs correlate frames. The UUID `commandId` inside a mutation identifies the operation. Thread, message, run, and approval request IDs identify individual records. Treat provider-derived IDs as opaque strings.

**Open question 2. One socket can subscribe to the whole environment's thread summaries. Detailed events are per thread.**

| Need | RPC and input | Result |
| --- | --- | --- |
| List and observe threads in the environment | `orchestration.subscribeShell`, `{}` | Initial `kind: "snapshot"` with `snapshotSequence`, `projects`, and active-list `threads`. Then project and thread updates/removals keyed by sequence. Each thread summary includes `status`, `providerInstanceId`, `activeRunId`, and `pendingRuntimeRequest`. Active-list threads include idle threads. |
| List archived threads | `orchestration.getArchivedShellSnapshot`, `{}` | Unary snapshot with archived `threads`. The regular shell snapshot focuses on the active list. Shell deltas include a `location` of `active` or `archive`. |
| Observe full activity for selected threads | `orchestration.subscribeThread`, `{ "threadId": "…" }` | A snapshot with a projection, then `{kind:"event",sequence,event}` items. The projection includes runs, messages, turn items, runtime requests, and provider sessions. Open one stream per thread, multiplexed on the same WebSocket using distinct request IDs. |

Record the most recent sequence per stream and pass it as `afterSequence` on reconnect when retaining the prior projection. The server replays where possible and may send a replacement snapshot. Rebuild state from a fresh snapshot when starting without a prior projection. Notchbee leaves optional compact and paginated representations at their defaults.

Source paths · `packages/contracts/src/rpc.ts`, `packages/contracts/src/orchestrationV2.ts`, `packages/client-runtime/src/rpc/session.ts` and `session.test.ts`, `packages/client-runtime/src/state/shell.ts` and `threads.ts`, `apps/server/src/ws.ts`, `apps/server/src/terminal/OutputProtocol.ts`.

## Commands

Pass each of the following JSON objects as the RPC request's `payload`. Generate fresh UUIDs at submission time. For a new scratch workspace, register the existing directory via `projects.mutate` with `{type:"project.create",commandId,projectId,title,workspaceRoot}`. A normal notch client can pick a project ID from the shell snapshot.

**Send to an existing thread** with `orchestration.dispatchCommand`:

```json
{"type":"message.dispatch","commandId":"<uuid>","createdBy":"user","creationSource":"web","threadId":"<thread>","messageId":"<uuid>","text":"Reply with OK","attachments":[],"dispatchMode":{"type":"queue_after_active"}}
```

`queue_after_active` queues behind active work and runs when the thread is ready. Watch thread events for the eventual outcome. The RPC success value reports the committed sequence.

**Create a thread** with `orchestration.dispatchCommand` and then send a prompt as above:

```json
{"type":"thread.create","commandId":"<uuid>","createdBy":"user","creationSource":"web","threadId":"<uuid>","projectId":"<project>","title":"Scratch","modelSelection":{"instanceId":"claudeAgent","model":"claude-sonnet-4-6"},"runtimeMode":"approval-required","interactionMode":"default","branch":null,"worktreePath":null}
```

The web composer uses `orchestration.launchThread` when sending from a new draft. Send `commandId`, `projectId`, a non-blank `title`, `modelSelection`, `runtimeMode`, `interactionMode`, `workspaceStrategy`, and `initialMessage: {messageId,text,attachments:[]}`. The workspace strategy can use the project root with an optional branch, an existing worktree path, or a new worktree with a base ref. Notchpilot uses the project root and the default interaction mode. The model selection identifies the provider by instance ID and the model by slug. Its optional `options` field carries an array of `{id, value}` selections, with a string or boolean value.

The launch RPC creates the thread and dispatches the first message on the server. The successful response includes `threadId`, a projection with the initial message and run, and the message's commit sequence on servers that support it. Open the returned thread and subscribe to its detail stream to follow the run. No separate turn command or intervening event is needed to send the first prompt.

Source paths · `packages/contracts/src/project.ts`, `packages/contracts/src/orchestrationV2.ts`, `packages/contracts/src/modelSelection.ts`, `packages/client-runtime/src/operations/commands.ts`, `apps/web/src/components/chat/useComposerSend.ts`.

## Notchpilot thread controls

| Operation | RPC and payload | Notes |
| --- | --- | --- |
| Load the provider catalog | `server.getConfig`, `{}` | Read provider instance IDs, enabled state, model slugs, default model markers and supported runtime modes. For the selected project, use the configured model and runtime defaults when available. The project picker uses unarchived projects from the shell stream. |
| Create a thread with a first prompt | `orchestration.launchThread`, launch payload described above | The New tab, voice command and new-thread Agent dictation use the same launch request. Notchpilot generates separate UUIDs for the command, thread and message. An unchanged New form keeps those IDs for retries. The title seed comes from the first non-blank line and T3 can generate the final title. The New tab opens the returned thread. |
| Stop the selected thread's run | `orchestration.dispatchCommand`, `{type:"thread.stop",commandId,threadId,stopDelegatedTasks:false}` | Uses the selected thread ID and leaves its delegated threads alone. |
| Rename | `orchestration.dispatchCommand`, `{type:"thread.metadata.update",commandId,threadId,title}` | The updated title comes back through the shell/detail events. |
| Archive, unarchive, delete | `orchestration.dispatchCommand`, `{type:"thread.archive" \| "thread.unarchive" \| "thread.delete",commandId,threadId}` | On v0.1.9 an active-list removal also occurs when a thread moves to Archive. Refresh the archived shell snapshot before deciding whether the thread was moved or deleted. Delete asks for confirmation in the panel. |

The thread view reads `projection.messages` and `projection.turnItems` on `orchestration.subscribeThread`. `message.updated` carries the current message record including its accumulated text and `streaming` flag. Upsert by message ID so streaming updates replace the same row. `turn-item.updated` carries activity records and can stream assistant text before the final `message.updated` arrives. Use the item’s `messageId` to update the same row as the final message. Render concise summaries for tool activity. Runtime-request events continue to drive approval cards, and checkpoint events update the diff summary.

Source paths · `packages/contracts/src/rpc.ts`, `packages/contracts/src/server.ts`, `packages/contracts/src/orchestrationV2.ts`, `packages/client-runtime/src/operations/commands.ts`, `apps/server/src/ws.ts`, `apps/server/src/orchestration-v2/ThreadLaunchService.ts`.

## Dictation cleanup and Agent replies

T3 Code v0.1.9 exposes text cleanup through authenticated HTTP `POST /api/voice/post-process` at the verified local server origin. The WebSocket RPC contract has no transcript-cleanup method. The web client calls `postProcessEnvironmentTranscript` from `useEnvironmentSpeechInput.ts`, which sends JSON to this endpoint. Notchpilot uses its existing bearer credential with `orchestration:operate` scope and re-verifies the local listener before the request.

```json
{
  "transcript": "spoken words",
  "draft": {"text": "", "selection": {"start": 0, "end": 0}},
  "options": {
    "speechCustomWords": [],
    "speechPostProcessingPrompt": {"mode": "default", "customInstructions": ""}
  }
}
```

The response is `{"text":"Spoken words."}`. Notchpilot reads the user's cleanup prompt and dictionary from T3's `userdata/client-settings.json` and includes `speechCorrectionWord` when configured. Its draft is empty so cleanup sends only the transcript and settings. `speechRemoveFillerWords` belongs to T3's audio transcription options and is absent from the web client's text cleanup payload. Notchpilot transcribes locally. T3 chooses the cleanup provider and model through `resolveSpeechPostProcessingModelSelection` and calls `TextGeneration.generateTranscriptionPostProcessing`. Notchpilot inserts the local transcript if cleanup fails or exceeds five seconds, provided the original field still has focus and is safe.

Agent dictation sends only after the user confirms the transcript, app context, and target in the notch. It uses `orchestration.dispatchCommand` for the last active thread or `orchestration.launchThread` to start a new thread in approval-required mode. Notchpilot subscribes to that thread's detail stream and matches `runs[].userMessageId` to the dispatched message ID, then collects non-streaming assistant messages by `runId`. Inserting the reply requires a separate click and another focused-field check.

Source paths · `apps/web/src/speech/useEnvironmentSpeechInput.ts`, `packages/client-runtime/src/voice-input/environment.ts`, `packages/contracts/src/speech.ts`, `packages/contracts/src/environmentHttp.ts`, `apps/server/src/speech/http.ts`, `apps/server/src/speech/postProcessing.ts`, `packages/contracts/src/orchestrationV2.ts`.

## Provider approvals

- Observe `thread.updated.thread.pendingRuntimeRequest` on the shell stream for an environment-wide badge. The shell carries a single summary per thread. Open its detail stream to render the tool and see all outstanding requests.
- On the detail stream, `runtime-request.updated` carries the request in `event.payload`. On first subscription see `projection.runtimeRequests`. A Claude Bash approval appeared as `kind: "command"`, `status: "pending"`, and `responseCapability.type: "live"`. The corresponding `turn-item.updated` with `type: "approval_request"` carries the display details and uses the same ID in `requestId`. Filter user-input questions and other non-approval runtime requests from the permission UI.
- Answer via `orchestration.dispatchCommand` with `{type:"runtime-request.respond",commandId,threadId,requestId,decision:"accept"}`. Use `"decline"` for denial. The `requestId` value is the T3 runtime request's `id`. A successful resolution arrives as another `runtime-request.updated` with `status: "resolved"` and the recorded decision. A second answer after resolution produces `OrchestrationV2DispatchCommandError`.
- The server resolves by thread and request ID, authorizes the call using `orchestration:operate`, and delivers the decision to the live provider session through the effect outbox.

Source paths · `packages/contracts/src/orchestrationV2.ts`, `packages/contracts/src/providerPolicy.ts`, `apps/web/src/components/chat/usePendingThreadRequests.ts`, `packages/client-runtime/src/operations/commands.ts`, `apps/server/src/orchestration-v2/Orchestrator.ts`, `apps/server/src/orchestration-v2/EffectWorker.ts`, `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts`.

## Synthetic fixture replay

The fixtures use example projects, prompts, dates, and identifiers to exercise protocol behavior.

| Fixture | Scenario |
| --- | --- |
| [setup-and-list](../fixtures/setup-and-list.jsonl) | Project and both threads created. A separate client listed them using shell and archive RPCs. |
| [normal](../fixtures/normal.jsonl) | Codex completed a prompt on its existing scratch thread and returned the requested text. |
| [approval](../fixtures/approval.jsonl) | Claude requested Bash permission. The responder accepted. The command completed with `hi`. |
| [denial](../fixtures/denial.jsonl) | Claude requested Bash permission. The responder declined. The command was denied and Claude completed the turn with a denial report. |
| [stale-approval-error](../fixtures/stale-approval-error.jsonl) | A repeat answer on the resolved request returned a typed RPC failure. |
| [cancel](../fixtures/cancel.jsonl) | The client sent `thread.stop` and the Codex run reached `interrupted`. |
| [thread-launch](../fixtures/thread-launch.jsonl) | A successful Codex launch with its initial message and a model option. Also covers the validation failure for a whitespace-only title and the typed launch failure for an unknown project ID. |

Each JSONL row has `at`, `connection`, `direction` (`in` or `out`), and `frame`. Group by connection when matching request IDs.

In a Debug build, choose **Debug → Live** or **Debug → Fake** to switch between the bundled engine and the demo feed. The Swift tests replay these fixtures:

```sh
swift test --package-path NotchpilotCore
(cd NotchpilotCore && xcodebuild -scheme NotchpilotCore -destination 'platform=macOS,arch=arm64' test)
xcodegen generate --spec Notchpilot/project.yml
xcodebuild -project Notchpilot/Notchpilot.xcodeproj -scheme Notchpilot -destination 'platform=macOS,arch=arm64' build test
```

The settings window adds `settings:write` for the default model selection and
`providers:manage` for provider-instance upserts (including secret settings).
Project and settle commands retain `orchestration:operate`. Config reads and
explicit provider refreshes use `orchestration:read`. Issued sessions expire
after 20 minutes.
