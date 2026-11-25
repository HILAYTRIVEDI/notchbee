import { configureProviderSdkDirectory } from "@t3tools/shared/providerSdk";
import { runClaudeHistoryWorker } from "./claudeHistoryWorker.ts";

const [baseDirectory, method, sessionId, rawOptions] = process.argv.slice(2);
if (!baseDirectory) throw new Error("Provider SDK storage is required.");
configureProviderSdkDirectory(baseDirectory);
await runClaudeHistoryWorker(method, sessionId, rawOptions);
