# T3 Code upstream

Repository: [pingdotgg/t3code](https://github.com/pingdotgg/t3code)
Release: `v0.1.9`
Commit: `24e77473ecf41bc1f7142529c7911c1c1aae1d76`

The import contains the server sources and its runtime workspace dependencies.
Run `scripts/sync-engine-upstream.sh <ref>` with the ref available in
`vendor/t3code` or in `T3CODE_UPSTREAM_CHECKOUT`. The script applies the
Notchpilot patches in numeric order before updating the tracked import.
After updating upstream dependencies, run `cd engine && bun install` to
refresh the lockfile, then build and run the engine smoke test.
