import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Writable } from "node:stream";
import { setTimeout as delay } from "node:timers/promises";

const scratch = await realpath(await mkdtemp(join(tmpdir(), "notchpilot-smoke-")));
const binary = resolve(process.argv[2] ?? join(import.meta.dir, "../../build/engine/notchbee-engine"));
const home = join(scratch, "home");
const data = join(scratch, "data");
const workspace = join(scratch, "project");
const toolDir = join(scratch, "bin");
const temp = join(scratch, "tmp");
const codexHome = join(scratch, "codex");
await Promise.all([home, workspace, toolDir, temp, codexHome].map((path) => mkdir(path)));
assert.equal(Bun.spawnSync(["/usr/bin/git", "init", "-q", workspace], { env: { HOME: home } }).exitCode, 0);
const fixture = join(import.meta.dir, "codex-fixture.ts");
const shellQuote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
const codex = join(toolDir, "codex");
await writeFile(codex, `#!/bin/sh\nexec ${shellQuote(process.execPath)} ${shellQuote(fixture)} "$@"\n`);
await chmod(codex, 0o700);
await mkdir(join(data, "userdata"), { recursive: true, mode: 0o700 });
let exportRequests = 0;
const collector = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch: () => { exportRequests++; return new Response(null, { status: 204 }); },
});
const collectorUrl = collector.url.toString();
const disabledProviders = ["claudeAgent", "cursor", "grok", "opencode", "antigravity", "fx", "kiro", "muse", "pi"];
await writeFile(join(data, "userdata/settings.json"), JSON.stringify({
  enableProviderUpdateChecks: false,
  observability: { otlpTracesUrl: collectorUrl, otlpMetricsUrl: collectorUrl, otlpLogsUrl: collectorUrl },
  providerInstances: Object.fromEntries([
    ...disabledProviders.map((id) => [id, { driver: id, enabled: false }]),
    ["codex", { driver: "codex", config: { setupMode: "existing", binaryPath: codex, homePath: codexHome } }],
  ]),
}), { mode: 0o600 });

const token = crypto.randomUUID() + crypto.randomUUID();
const envelope = {
  mode: "desktop", port: 0, desktopBootstrapToken: token, shellEnvironmentPrepared: true,
  // Deliberately request upstream features so the test catches accidental forwarding.
  otlpTracesUrl: collectorUrl, otlpMetricsUrl: collectorUrl, otlpLogsUrl: collectorUrl,
  host: "0.0.0.0", noBrowser: false, tailscaleServeEnabled: true, tailscaleServePort: 443,
};
const env = {
  PATH: `${toolDir}:/usr/bin:/bin:/usr/sbin:/sbin`,
  HOME: home, TMPDIR: temp, CODEX_HOME: codexHome, SHELL: "/bin/sh",
  OTEL_EXPORTER_OTLP_ENDPOINT: collectorUrl,
  T3CODE_POSTHOG_HOST: collectorUrl, T3CODE_TELEMETRY_ENABLED: "true",
  T3CODE_HOME: join(home, ".t3"), T3CODE_PORT: "3773", T3CODE_LAN: "true",
};
const child = spawn(binary, ["--base-dir", data, "--bootstrap-fd", "3", "--log-level", "info"], {
  cwd: workspace, env, stdio: ["ignore", "pipe", "pipe", "pipe"],
});
let logs = "";
for (const stream of [child.stdout, child.stderr]) {
  assert.ok(stream);
  stream.on("data", (chunk) => { logs = (logs + chunk.toString()).slice(-20000); });
}
const exit = new Promise<{ code: number | null; signal: string | null }>((done) => {
  child.once("exit", (code, signal) => done({ code, signal }));
  child.once("error", (error) => { logs += error.message; done({ code: 1, signal: null }); });
});
const bootstrapInput = child.stdio[3];
assert.ok(bootstrapInput instanceof Writable);
bootstrapInput.on("error", () => {});
bootstrapInput.end(JSON.stringify(envelope) + "\n");

async function waitFor<T>(name: string, read: () => Promise<T | undefined>, timeoutMs = 180_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  do {
    const result = await read();
    if (result !== undefined) return result;
    if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Engine exited waiting for ${name}`);
    await delay(75);
  } while (Date.now() < deadline);
  throw new Error(`Timed out waiting for ${name}`);
}

let socket: WebSocket | undefined;
try {
  const runtime = await waitFor("runtime record", async () => {
    try {
      return JSON.parse(await readFile(join(data, "userdata/server-runtime.json"), "utf8"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  });
  const origin = new URL(runtime.origin);
  assert.equal(origin.hostname, "127.0.0.1");
  assert.notEqual(origin.port, "3773");
  assert.equal(runtime.pid, child.pid);
  const listeners = Bun.spawnSync(["/usr/sbin/lsof", "-nP", "-a", "-p", String(child.pid), "-iTCP", "-sTCP:LISTEN"]);
  assert.equal(listeners.exitCode, 0);
  const listenerLines = listeners.stdout.toString().trim().split("\n").slice(1);
  assert.equal(listenerLines.length, 1);
  assert.match(listenerLines[0]!, new RegExp(` 127\\.0\\.0\\.1:${origin.port} \\(LISTEN\\)$`));
  const http = (path: string, init?: RequestInit) =>
    fetch(new URL(path, origin), { signal: AbortSignal.timeout(10_000), ...init });
  const form = (subjectToken: string) => new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: subjectToken,
    subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    scope: "orchestration:read orchestration:operate settings:write providers:manage terminal:operate",
    client_label: "Isolated engine smoke",
  });
  assert.equal((await http("/")).status, 404);
  const descriptor = "/.well-known/t3/environment";
  assert.equal((await http(descriptor)).status, 200);
  assert.equal((await http(descriptor, { headers: { Host: "untrusted.invalid" } })).status, 403);
  const foreignOrigin = { Origin: "https://untrusted.invalid" };
  const preflight = await http(descriptor, { method: "OPTIONS", headers: foreignOrigin });
  assert.equal(preflight.status, 403);
  assert.equal(preflight.headers.get("access-control-allow-origin"), null);
  assert.equal((await http(descriptor, { headers: { "Sec-Fetch-Site": "cross-site" } })).status, 403);
  assert.equal((await http("/api/auth/websocket-ticket/rpc", { method: "POST" })).status, 401);
  assert.equal((await http("/oauth/token", { method: "POST", body: form("invalid-token") })).status, 401);
  assert.equal((await http("/oauth/token", { method: "POST", headers: foreignOrigin, body: form(token) })).status, 403);
  const exchange = await http("/oauth/token", { method: "POST", body: form(token) });
  assert.equal(exchange.status, 200, await exchange.clone().text());
  const credential = await exchange.json();
  assert.equal(credential.token_type, "Bearer");
  const authorized = { Authorization: `Bearer ${credential.access_token}` };
  const ticketResponse = await http("/api/auth/websocket-ticket/rpc", { method: "POST", headers: authorized });
  assert.equal(ticketResponse.status, 200);
  const { ticket } = await ticketResponse.json();
  const wsUrl = new URL("/ws", origin);
  wsUrl.protocol = "ws:";
  wsUrl.searchParams.set("orchestrationProtocol", "2");
  wsUrl.searchParams.set("wsTicket", ticket);
  // Bun accepts custom WebSocket handshake headers through this constructor overload.
  const BunWebSocket = WebSocket as typeof WebSocket & {
    new (url: string, options: { headers: Record<string, string> }): WebSocket;
  };
  const browserSocket = new BunWebSocket(wsUrl.toString(), { headers: foreignOrigin });
  try {
    await new Promise<void>((done, fail) => {
      const timer = setTimeout(() => fail(new Error("Timed out waiting for cross-origin rejection")), 5_000);
      browserSocket.addEventListener("open", () => {
        clearTimeout(timer);
        fail(new Error("Accepted a cross-origin WebSocket"));
      }, { once: true });
      browserSocket.addEventListener("error", () => {
        clearTimeout(timer);
        done();
      }, { once: true });
    });
  } finally {
    browserSocket.close();
  }
  socket = new WebSocket(wsUrl);
  const ws = socket;
  const frames: any[] = [];
  const events: any[] = [];
  ws.addEventListener("message", ({ data }) => {
    const frame = JSON.parse(String(data));
    frames.push(frame);
    if (frame._tag === "Chunk") {
      events.push(...frame.values);
      ws.send(JSON.stringify({ _tag: "Ack", requestId: frame.requestId }));
    }
  });
  await waitFor("WebSocket upgrade", async () => ws.readyState === WebSocket.OPEN ? true : undefined, 5_000);
  let nextId = 0;
  const send = (tag: string, payload: object) => {
    const id = String(++nextId);
    ws.send(JSON.stringify({ _tag: "Request", id, tag, payload, headers: [] }));
    return id;
  };
  const rpc = async (tag: string, payload: object) => {
    const id = send(tag, payload);
    const response = await waitFor(tag, async () =>
      frames.find((frame) => frame._tag === "Exit" && frame.requestId === id));
    assert.equal(response.exit._tag, "Success", JSON.stringify(response.exit));
    return response.exit.value;
  };

  const config = await rpc("server.getConfig", {});
  assert.deepEqual(config.providerSdks.map(({ driver, installed }: { driver: string; installed: boolean }) =>
    [driver, installed]), [["claudeAgent", false], ["cursor", false]]);
  const unapprovedVersion = send("provider.sdk.install", {
    instanceId: "claudeAgent", driver: "claudeAgent", version: "0.0.0",
  });
  const rejectedInstall = await waitFor("SDK version rejection", async () =>
    frames.find((frame) => frame._tag === "Exit" && frame.requestId === unapprovedVersion));
  assert.equal(rejectedInstall.exit._tag, "Failure");
  assert.match(JSON.stringify(rejectedInstall.exit), /The SDK version changed/);
  assert.equal(await Bun.file(join(data, "sdk/claudeAgent-0.3.330/installed.json")).exists(), false);
  assert.deepEqual(config.observability, {
    logsDirectoryPath: join(data, "userdata/logs"),
    localTracingEnabled: false,
    otlpTracesEnabled: false,
    otlpMetricsEnabled: false,
    otlpLogsEnabled: false,
  });
  assert.equal((await http("/api/observability/v1/traces", {
    method: "POST", headers: { ...authorized, "Content-Type": "application/json" },
    body: JSON.stringify({ resourceSpans: [] }),
  })).status, 404);
  assert.ok(config.providers.some(({ instanceId }: { instanceId: string }) => instanceId === "codex"));
  console.log("Provider catalog:", config.providers.map(({ instanceId }: { instanceId: string }) => instanceId).join(", "));
  const settings = await rpc("server.updateSettings", { patch: { promptSuggestionsEnabled: false }, providerInstanceMutation: {
    operation: "upsert", instanceId: "codex",
    instance: { driver: "codex", config: { setupMode: "existing", binaryPath: codex, homePath: codexHome } },
  } });
  assert.equal(settings.promptSuggestionsEnabled, false);
  console.log("Authenticated and updated settings.");
  const projectId = crypto.randomUUID();
  const threadId = crypto.randomUUID();
  await rpc("projects.mutate", {
    type: "project.create", commandId: crypto.randomUUID(), projectId, title: "Scratch", workspaceRoot: workspace,
  });
  const dispatch = (type: string, fields: object) => rpc("orchestration.dispatchCommand", {
    type, commandId: crypto.randomUUID(), threadId, ...fields,
  });
  await dispatch("thread.create", {
    createdBy: "user", creationSource: "web", projectId, title: "Scratch",
    modelSelection: { instanceId: "codex", model: "gpt-6-luna" },
    runtimeMode: "approval-required", interactionMode: "default", branch: null, worktreePath: null,
  });
  console.log("Created the scratch project and thread.");
  send("orchestration.subscribeThread", { threadId });
  await waitFor("thread snapshot", async () => events.find((item) => item.kind === "snapshot"));
  await dispatch("message.dispatch", {
    createdBy: "user", creationSource: "web", messageId: crypto.randomUUID(),
    text: "Reply with a short message.", attachments: [], dispatchMode: { type: "queue_after_active" },
  });
  await waitFor("streamed assistant text", async () => {
    const failed = events.find((item) =>
      item.kind === "event" && item.event.type === "turn-item.updated" && item.event.payload.type === "error");
    if (failed) throw new Error(JSON.stringify(failed.event.payload));
    return events.find((item) =>
      item.kind === "event" && JSON.stringify(item.event).includes("Isolated smoke stream."));
  });
  console.log("Received streamed assistant text.");
  await dispatch("thread.stop", { stopDelegatedTasks: false });
  await waitFor("interrupted turn", async () => events.find((item) =>
    item.kind === "event" && item.event.type === "run.updated" && item.event.payload.status === "interrupted"));
  console.log("Observed the interrupted turn.");
  const terminalId = "smoke";
  const terminal = await rpc("terminal.open", { threadId, terminalId, cwd: workspace });
  assert.equal(terminal.status, "running");
  await rpc("terminal.close", { threadId, terminalId, deleteHistory: true });

  const voice = await http("/api/voice/post-process", {
    method: "POST", headers: { ...authorized, "Content-Type": "application/json" },
    // Whitespace is returned verbatim, exercising the authenticated route without inference.
    body: JSON.stringify({ transcript: " ", options: { speechCustomWords: [], speechPostProcessingPrompt: { mode: "default", customInstructions: "" } }, draft: { text: "", selection: { start: 0, end: 0 } } }),
  });
  assert.equal(voice.status, 200, await voice.clone().text());
  assert.deepEqual(await voice.json(), { text: " " });
  assert.ok(!(await readdir(home)).includes(".t3"));
  const legacy = join(home, ".t3");
  const alias = join(scratch, "legacy-alias");
  await mkdir(legacy);
  await symlink(legacy, alias);
  const rejected = Bun.spawnSync([binary], {
    cwd: workspace,
    env: {
      ...env,
      NOTCHBEE_ENGINE_HOME: alias, NOTCHBEE_ENGINE_PORT: "0",
      NOTCHBEE_ENGINE_BOOTSTRAP_FD: "0",
    },
    stdin: Buffer.from(JSON.stringify(envelope) + "\n"),
    stderr: "pipe",
    stdout: "pipe",
  });
  assert.notEqual(rejected.exitCode, 0);
  assert.match(rejected.stderr.toString() + rejected.stdout.toString(), /legacy engine data directory is reserved/);
  assert.deepEqual(await readdir(legacy), []);
  assert.equal(exportRequests, 0);
  assert.ok(!(await readdir(data)).includes("usage-host-id"));
  assert.ok(!(await readdir(join(data, "userdata"))).includes("anonymous-id"));
  assert.deepEqual(await readdir(join(data, "userdata/logs")), ["terminals"]);
  console.log("Verified loopback, headless HTTP, FD bootstrap, bearer and ticket auth, settings, project and thread creation, streamed events, stop, PTY open/close voice post-processing, and zero telemetry requests or artifacts.");
} catch (error) {
  console.error(logs.replaceAll(token, "[REDACTED]"));
  throw error;
} finally {
  socket?.close();
  child.kill("SIGTERM");
  const shutdown = setTimeout(() => child.kill("SIGKILL"), 10_000);
  await exit;
  clearTimeout(shutdown);
  collector.stop(true);
  await rm(scratch, { recursive: true, force: true });
}
