# Notchpilot engine

The engine is the local HTTP and WebSocket backend for Notchpilot. It uses orchestration protocol 2 from the pinned upstream server. See [the protocol reference](../docs/t3-protocol.md) for RPC frames and payloads and [UPSTREAM.md](UPSTREAM.md) for the source pin.

## Build and run

Run these from the repository root on Apple Silicon with Bun 1.4.1.

```sh
scripts/build-engine.sh
build/engine/notchbee-engine --version
bun engine/tests/smoke.ts
```

The smoke test launches the executable with a temporary home, scratch project, fake Codex app-server, and an OS-assigned loopback port. It requires no provider credentials and removes its scratch directory.

The executable runs in the foreground. Launch it directly as a child process and supply the auth envelope before startup. `--help` lists the flags.

| Flag | Environment | Behavior |
| --- | --- | --- |
| `--base-dir <path>` | `NOTCHBEE_ENGINE_HOME` | Engine data root. Defaults to `~/Library/Application Support/Notchbee/engine`. |
| `--port <0–65535>` | `NOTCHBEE_ENGINE_PORT` | IPv4 loopback port. Use `0` to let macOS allocate a free port. |
| `--bootstrap-fd <n>` | `NOTCHBEE_ENGINE_BOOTSTRAP_FD` | Required readable inherited descriptor. |
| `--log-level <level>` | `NOTCHBEE_ENGINE_LOG_LEVEL` | Console log threshold, default `info`. |

Flags take precedence over branded environment variables and the envelope. The engine discards inherited T3 configuration. Provider-specific environment variables and PATH still reach provider processes. Engine storage paths that resolve into a legacy `.t3` directory are rejected.

## Native authentication

Write a JSON object followed by one newline to the pipe, then close the write end. The engine waits up to one second for the envelope after it starts reading the descriptor. Pass a fresh cryptographically random token of at least 32 characters on each launch, for example 32 random bytes encoded as hex. Keep it in the parent process's memory. This envelope uses the upstream FD schema.

```json
{
  "mode": "desktop",
  "port": 0,
  "host": "127.0.0.1",
  "noBrowser": true,
  "desktopBootstrapToken": "<random launch token>",
  "tailscaleServeEnabled": false,
  "tailscaleServePort": 443
}
```

`shellEnvironmentPrepared: true` is optional when the launcher already set a provider-capable PATH. Use the CLI flag for the data root. Legacy envelopes can supply the fallback field `t3Home` with an engine data path. The engine controls the final bind address and browser and Tailscale settings.

1. Read `userdata/server-runtime.json` under the engine's data root. Check that `pid` matches the child you launched and `origin` uses HTTP at `127.0.0.1` with the recorded port. The engine publishes this file atomically after startup.
2. POST form data to `/oauth/token` on that origin. Use `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token=<random launch token>`, `subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap`, and `requested_token_type=urn:ietf:params:oauth:token-type:access_token`. Request `scope=orchestration:read orchestration:operate`. Add `settings:write` when changing settings and `providers:manage` when managing provider instances. The response includes `access_token`, `expires_in`, and the granted `scope`.
3. POST `/api/auth/websocket-ticket/rpc` with `Authorization: Bearer <access_token>`. Connect to `/ws?orchestrationProtocol=2&wsTicket=<URL-encoded ticket>`. Request a fresh ticket on each reconnect. Send the bearer header to authenticated HTTP endpoints such as `/api/voice/post-process`.
4. Repeat the token exchange after expiry or a credential rejection. Bootstrap exchange replaces the previous desktop bearer session. Keep one credential per engine child and share it across Notchpilot's clients. Keep tokens and ticket URLs out of logs and command arguments.

## Storage and supervision for Phase B2

- Bundle `notchbee-engine` as a signed auxiliary executable. It carries Bun, SQLite, and its native dependencies. See [BUILD.md](BUILD.md) for packaging details.
- Use `posix_spawn` with an inherited pipe mapped to FD 3, or use standard input with `--bootstrap-fd 0` when the launch API only supports stdin. Close the parent's copy of the read end after spawning. Drain stdout and stderr asynchronously. Set an explicit engine data directory and stable working directory.
- Keep a single child per data directory. The runtime record can outlive a crashed child, so validate the PID and wait for a successful HTTP response before connecting. Allow up to two minutes for the first startup with SQLite migrations. The port can change on each restart.
- Send SIGTERM on quit and wait for the child to exit before restarting or replacing it. Effect's runtime can report exit code 130 for a signal-driven shutdown. The child also watches the parent PID and shuts down when it changes. Back off after unexpected exits. Exit 78 means another process owns the data directory and exit 77 means a managed policy refused startup.
- SQLite state, server settings, signing keys, runtime discovery, attachments, and logs live under `userdata/`. The engine also creates `caches/` and `worktrees/` under its data root. Treat the data directory as private. Keep upstream T3 data separate.

## Signing

`scripts/bundle-engine.sh` copies the executable to `Contents/Helpers/notchbee-engine` and signs it with the hardened runtime, the identifier `com.hilaytrivedi.Notchbee.engine`, and `Notchpilot/Engine.entitlements`: `allow-jit` (JavaScriptCore) and `disable-library-validation` (Bun loads its extracted native modules). The app's own entitlements are separate. The script runs as an Xcode post-build phase, rebuilds the engine only when a source file is newer than the binary, and signs ad hoc unless Xcode supplies an identity.
