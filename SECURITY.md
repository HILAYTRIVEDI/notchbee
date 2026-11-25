# Security

Report suspected vulnerabilities through [GitHub’s private vulnerability reporting form](https://github.com/HILAYTRIVEDI/notchbee/security/advisories/new) when it is enabled. Include the affected version or commit, macOS version, impact, and enough detail to reproduce the issue. Redact credentials, private URLs, and personal data from evidence.

Keep vulnerability details out of public issues and pull requests while the report is being investigated.

## Local trust boundary

Notchbee starts its bundled engine on IPv4 loopback and verifies the child owns the listener before sending credentials. It uses a separate local data directory with owner-only permissions. T3 Code sessions and settings remain in T3 Code.

Notchbee sends no product telemetry. Claude and Cursor SDK downloads require in-app consent and must match exact SHA-512 pins. See the [network inventory](engine/NETWORK.md).

## Automated checks

These run on every push to `master` and on every pull request:

- **CodeQL** code scanning for the Swift app and core package, the engine's TypeScript and the GitHub Actions workflows. It also runs weekly.
- **gitleaks** secret scanning of the full Git history.
- **Engine privacy check** (`scripts/check-engine-privacy.ts`). It fails the build if analytics, telemetry exporters or crash reporting reappear in the engine.
- **Core tests** and the **branding check**.

Dependabot checks GitHub Actions and the Swift package each week. The app's Swift package pins in `Notchpilot/project.yml` and the engine's Bun lockfile are reviewed by hand when dependencies or the engine are updated.
