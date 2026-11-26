import { runCliCommand } from "./binMain.ts";

// Ambient T3 launch configuration can refer to an independent installation.
for (const key of Object.keys(process.env)) {
  if (key.startsWith("T3CODE_") || key.startsWith("OTEL_")) delete process.env[key];
}
// The in-process Claude SDK also checks the host environment for these settings.
process.env.DISABLE_TELEMETRY = "1";
process.env.DISABLE_ERROR_REPORTING = "1";
process.env.CLAUDE_CODE_ENABLE_TELEMETRY = "0";
process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
process.env.DO_NOT_TRACK = "1";
await runCliCommand();
