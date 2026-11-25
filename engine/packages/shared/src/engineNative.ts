import { createRequire } from "node:module";
import { join } from "node:path";

let runtimeRequire: NodeJS.Require | undefined;

export function setEngineNativeDirectory(directory: string): void {
  runtimeRequire = createRequire(join(directory, "engine-native.cjs"));
}

export const engineNativeRequire = () => runtimeRequire ?? createRequire(import.meta.url);
