#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
upstream="${T3CODE_UPSTREAM_CHECKOUT:-$root/vendor/t3code}"
engine="$root/engine"
if (( $# > 1 )); then
  echo "Usage: $0 [upstream-ref]" >&2
  exit 2
fi
ref="${1:-$(sed -n 's/^Commit: `\([0-9a-f]*\)`$/\1/p' "$engine/UPSTREAM.md")}"
commit="$(git -C "$upstream" rev-parse --verify "${ref}^{commit}")"
tag="$(git -C "$upstream" describe --tags --exact-match --match 'v[0-9]*' --exclude '*-*' "$commit" 2>/dev/null || true)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# Archive directly from the commit so local changes in the upstream checkout are irrelevant.
git -C "$upstream" archive "$commit" LICENSE apps/server/src apps/server/schema \
  apps/server/package.json packages patches pnpm-workspace.yaml third-party-licenses \
  | tar -xf - -C "$stage"
ruby "$root/scripts/prepare-engine-import.rb" "$stage" "$tag"

for patch in "$engine"/patches/*.patch; do
  if [[ -f "$patch" ]]; then
    (cd "$stage" && git apply --whitespace=error "$patch")
  fi
done

mkdir -p "$engine/apps" "$engine/packages" "$engine/dependency-patches"
rsync -a --delete --exclude=node_modules/ "$stage/apps/" "$engine/apps/"
rsync -a --delete --exclude=node_modules/ "$stage/packages/" "$engine/packages/"
rsync -a --delete "$stage/dependency-patches/" "$engine/dependency-patches/"
rsync -a --delete "$stage/third-party-licenses/" "$engine/third-party-licenses/"
cp "$stage/LICENSE" "$stage/package.json" "$engine/"
cat > "$engine/UPSTREAM.md" <<META
# T3 Code upstream

Repository: [pingdotgg/t3code](https://github.com/pingdotgg/t3code)
Release: \`${tag:-untagged}\`
Commit: \`$commit\`

The import contains the server sources and its runtime workspace dependencies.
Run \`scripts/sync-engine-upstream.sh <ref>\` with the ref available in
\`vendor/t3code\` or in \`T3CODE_UPSTREAM_CHECKOUT\`. The script applies the
Notchpilot patches in numeric order before updating the tracked import.
After updating upstream dependencies, run \`cd engine && bun install\` to
refresh the lockfile, then build and run the engine smoke test.
META
