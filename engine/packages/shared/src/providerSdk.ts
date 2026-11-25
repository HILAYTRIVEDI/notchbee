// @effect-diagnostics nodeBuiltinImport:off -- SDKs are resolved from a private runtime directory.
import { lstatSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

export const providerSdkDrivers = ["claudeAgent", "cursor"] as const;
export type ProviderSdkDriver = (typeof providerSdkDrivers)[number];

export const providerSdkMetadata = {
  claudeAgent: {
    packageName: "@anthropic-ai/claude-agent-sdk",
    version: "0.3.330",
    vendor: "Anthropic",
    terms: "https://code.claude.com/docs/en/legal-and-compliance",
  },
  cursor: {
    packageName: "@cursor/sdk",
    version: "1.2.0",
    vendor: "Anysphere",
    terms: "https://cursor.com/terms-of-service",
  },
} as const;

const entries = {
  claudeAgent: "sdk.mjs",
  cursor: "dist/bundled/index.js",
} as const;

// The engine launcher and its history worker set this after resolving their own storage root.
let baseDirectory: string | undefined;
export function configureProviderSdkDirectory(directory: string): void {
  baseDirectory = directory;
}

export function providerSdkDirectory(): string {
  if (baseDirectory === undefined) throw new Error("Provider SDK storage has not been configured.");
  return baseDirectory;
}

export function providerSdkInstallPath(driver: ProviderSdkDriver): string {
  return join(providerSdkDirectory(), "sdk", driver + "-" + providerSdkMetadata[driver].version);
}

export function providerSdkInstalled(driver: ProviderSdkDriver): boolean {
  if (baseDirectory === undefined) return false;
  const root = providerSdkInstallPath(driver);
  for (const directory of [join(baseDirectory, "sdk"), root]) {
    const stat = lstatSync(directory, { throwIfNoEntry: false });
    if (!stat?.isDirectory() || (stat.mode & 0o077) !== 0 || stat.uid !== process.getuid?.()) {
      return false;
    }
  }
  return lstatSync(join(root, "installed.json"), { throwIfNoEntry: false })?.isFile() === true;
}

export function loadProviderSdk(driver: ProviderSdkDriver, cursorSqlite = false): unknown {
  const metadata = providerSdkMetadata[driver];
  if (!providerSdkInstalled(driver)) {
    throw new Error(`Install ${metadata.packageName} from Settings → Providers to use this provider.`);
  }
  const directory = providerSdkInstallPath(driver);
  const entry = driver === "cursor" && cursorSqlite ? "dist/bundled/sqlite.js" : entries[driver];
  // Absolute paths bypass Bun's compiled package resolution and never fall back to a global SDK.
  return createRequire(join(directory, "loader.mjs"))(
    join(directory, "node_modules", metadata.packageName, entry),
  );
}
