# Contributing

Use GitHub Issues for bugs and feature requests. For larger changes, open an issue first so the maintainer can discuss the approach. Follow the [Code of Conduct](CODE_OF_CONDUCT.md) and use [private reporting](SECURITY.md) for security issues.

Follow the [source build instructions](README.md#build-from-source). Run `swift test --package-path NotchpilotCore` and `scripts/check-branding.sh`. Use the generated Xcode scheme for app tests and the [QA checklist](docs/qa-checklist.md) for relevant manual checks. Describe what you changed and how you tested it. Use synthetic workspaces and sessions in fixtures, screenshots, and logs.
