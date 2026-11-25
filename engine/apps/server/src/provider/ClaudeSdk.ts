import { loadProviderSdk } from "@t3tools/shared/providerSdk";

export function loadClaudeSdk(): typeof import("@anthropic-ai/claude-agent-sdk") {
  return loadProviderSdk("claudeAgent") as typeof import("@anthropic-ai/claude-agent-sdk");
}
