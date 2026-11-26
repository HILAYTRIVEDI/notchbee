#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift="$(xcrun --find swift)"
host="$(dirname "$swift")/../lib/swift/host"
"$swift" -I "$host" -L "$host" -Xlinker -rpath -Xlinker "$host" scripts/check-branding.swift
