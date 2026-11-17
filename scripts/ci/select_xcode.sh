#!/usr/bin/env bash
# Selects the newest Xcode installed on a GitHub-hosted macOS runner (the app uses iOS 26 APIs, so "the default" may be too old).
set -euo pipefail
XCODE="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$XCODE" ]]; then sudo xcode-select -s "$XCODE"; fi
xcodebuild -version
