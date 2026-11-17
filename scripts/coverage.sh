#!/usr/bin/env bash
# Runs every unit-test target with code coverage and enforces the regression-coverage gate.
#
#   scripts/coverage.sh              # gate at 70 %
#   COVERAGE_MIN=80 scripts/coverage.sh
#
# Exit code is non-zero if any module (or the total) is below the gate, so CI fails the build.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN="${COVERAGE_MIN:-70}"
EXTRA=()

# A machine with only the Command Line Tools (no Xcode) keeps Swift Testing's macro plugin outside the
# default search path; point the compiler at it. With Xcode selected this block is skipped.
CLT_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ -d "$CLT_PLUGINS" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  EXTRA+=(-Xswiftc -plugin-path -Xswiftc "$CLT_PLUGINS")
fi

swift test --enable-code-coverage ${EXTRA[@]+"${EXTRA[@]}"}

BIN_DIR="$(swift build --show-bin-path ${EXTRA[@]+"${EXTRA[@]}"})"
PROFDATA="$(dirname "$(swift test --show-codecov-path ${EXTRA[@]+"${EXTRA[@]}"})")/default.profdata"

# One report across *all* test bundles (the stock JSON SwiftPM emits only covers some of them).
BUNDLES=()
for bundle in "$BIN_DIR"/*Tests.xctest; do
  name="$(basename "$bundle" .xctest)"
  BUNDLES+=("$bundle/Contents/MacOS/$name")
done

OBJECTS=()
for binary in "${BUNDLES[@]:1}"; do OBJECTS+=(-object "$binary"); done

REPORT="$(mktemp -t fitcoach-coverage).json"
xcrun llvm-cov export -format=text -summary-only \
  -instr-profile="$PROFDATA" "${BUNDLES[0]}" ${OBJECTS[@]+"${OBJECTS[@]}"} \
  -ignore-filename-regex='/Tests/|/\.build/' > "$REPORT"

python3 scripts/check_coverage.py "$REPORT" --min "$MIN"
