import { resolve } from "node:path";

const engine = resolve(import.meta.dir, "../engine");
// Bun embeds a relative /_bun/unref beacon for its development server.
const reporting = /ingest\.t3\.codes|posthog|phc_[a-z0-9]+|axiom\.(?:co|cloud)|x-axiom-dataset|sentry\.io|sendBeacon\s*\((?!["']\/_bun\/unref["'])|\/api\/observability\/v1\/traces/i;
const exporters = /effect\/observability|\bOtlp(?:Exporter|Logger|Tracer|Metrics)\b|@opentelemetry\/(?:exporter|sdk)|T3CODE_RELAY_CLIENT_OTLP/;
const identity = /hashTelemetryId|getTelemetryIdentity|getServerOwners|TelemetryOwner|anonymousIdPath|usage-host-id|readIdentityFile|openAiUserId/;
const credentialFile = /["']auth\.json["']|\.claude\.json/;
const sdkReporting = /\.(?:trackEvents|submitLogs|ingestConversation|uploadIssueTrace)\s*\(/;
// These paths refer to provider credentials for auth, account isolation or quota display.
const credentialPaths = new Set([
  "apps/server/src/provider/Drivers/CodexDriver.ts",
  "apps/server/src/provider/Drivers/CodexHomeLayout.ts",
  "apps/server/src/provider/claudeResetCredits.ts",
  "packages/contracts/src/settings.ts",
  "packages/provider-grok/src/server/usageLimits.ts",
  "packages/provider-opencode/src/server/usageLimits.ts",
]);

function check(path: string, contents: string, sourcePath?: string): void {
  const forbidden =
    reporting.test(contents) ||
    exporters.test(contents) ||
    sdkReporting.test(contents) ||
    identity.test(contents) ||
    (sourcePath !== undefined &&
      (/OTEL_EXPORTER_OTLP/.test(contents) ||
        (!sourcePath.includes("/_generated/") &&
          !credentialPaths.has(sourcePath) &&
          credentialFile.test(contents))));
  if (forbidden) {
    console.error(`Engine privacy check found a reporting or identity collection signature in ${path}.`);
    process.exitCode = 1;
  }
}

const sources = new Bun.Glob("{apps/server,packages/*}/{src/**/*.ts,package.json}");
for await (const path of sources.scan({ cwd: engine })) {
  if (path.includes("/node_modules/")) continue;
  check(path, await Bun.file(resolve(engine, path)).text(), path);
}
for (const path of process.argv.slice(2)) {
  check(path, await Bun.file(path).text());
}
