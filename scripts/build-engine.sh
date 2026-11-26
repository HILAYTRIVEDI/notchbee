#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/build/engine"
if [[ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]]; then
  echo "Build on an Apple Silicon Mac to stage the matching native dependencies." >&2
  exit 1
fi

if [[ "$(bun --version)" != "1.4.1" ]]; then
  echo "Bun 1.4.1 is required for the embedded runtime and lockfile." >&2
  exit 1
fi

bun "$root/scripts/check-engine-privacy.ts"
mkdir -p "$output"
stage="$(mktemp -d "$output/.build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
(
  cd "$root/engine"
  bun install --frozen-lockfile --production --ignore-scripts
  bun "$root/scripts/stage-engine-natives.ts" "$stage/native"
)
test -x "$stage/native/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$stage/native.tar.gz" -C "$stage/native" node_modules
cat > "$stage/entry.ts" <<'ENTRY'
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { engineName } from "../../../engine/packages/contracts/src/engineBrand.ts";
import { setEngineNativeDirectory } from "../../../engine/packages/shared/src/engineNative.ts";
import archive from "./native.tar.gz" with { type: "file" };

const nativeDirectory = mkdtempSync(join(tmpdir(), engineName + "-"));
const cleanup = () => rmSync(nativeDirectory, { recursive: true, force: true });
process.once("exit", cleanup);
const extracted = spawnSync("/usr/bin/tar", ["-xzf", "-", "-C", nativeDirectory], {
  input: Buffer.from(await Bun.file(archive).arrayBuffer()),
});
if (extracted.error || extracted.status !== 0) {
  throw new Error("Could not load the engine's native packages.", { cause: extracted.error });
}
setEngineNativeDirectory(nativeDirectory);
await import("../../../engine/apps/server/src/bin.ts");
ENTRY
runtime="${NOTCHBEE_BUN_RUNTIME:-$(command -v bun)}"
test -x "$runtime"
bun build "$stage/entry.ts" --compile --target=bun-darwin-arm64 --compile-executable-path="$runtime" \
  --minify --compile-autoload-package-json --no-compile-autoload-dotenv --no-compile-autoload-bunfig \
  --metafile="$stage/bundle.json" --outfile "$stage/notchbee-engine"
bun "$root/scripts/check-engine-privacy.ts" "$stage/notchbee-engine"
# The package names are present as installer metadata. Check code-only signatures.
if LC_ALL=C grep -aEq 'Claude Code native binary at \$\{|CursorAgentError' "$stage/notchbee-engine"; then
  echo "A proprietary SDK code signature was found in the compiled engine." >&2
  exit 1
fi
bun "$root/scripts/engine-build-notices.ts" "$stage/bundle.json" "$stage/native" > "$stage/THIRD_PARTY_NOTICES"
mv "$stage/notchbee-engine" "$output/notchbee-engine"
mv "$stage/THIRD_PARTY_NOTICES" "$output/THIRD_PARTY_NOTICES"
stat -f '%z bytes %N' "$output/notchbee-engine"
