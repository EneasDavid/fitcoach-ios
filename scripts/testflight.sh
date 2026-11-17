#!/usr/bin/env bash
# Archive FitCoach and (optionally) upload it to TestFlight.
#
#   scripts/testflight.sh --check                                    # lists what is still missing on this machine; builds and uploads NOTHING
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/testflight.sh                # dry run: archive + export an .ipa, uploads NOTHING
#   DEVELOPMENT_TEAM=… ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=/path/AuthKey_XXXX.p8 \
#       scripts/testflight.sh --upload                               # uploads to App Store Connect / TestFlight
#
# Nothing here ships a secret: the App Store Connect API key stays on your machine / in CI secrets.
set -euo pipefail
cd "$(dirname "$0")/.."

# Optional local configuration (git-ignored): copy .env.example to .env.
if [[ -f .env ]]; then set -a; source .env; set +a; fi

UPLOAD=0; [[ "${1:-}" == "--upload" ]] && UPLOAD=1

# --check: a read-only preflight. It looks at this machine and your environment and says what is missing; it never signs, builds or uploads.
if [[ "${1:-}" == "--check" ]]; then
  missing=0
  ok()   { echo "  ✓ $1"; }
  need() { echo "  ✗ $1"; missing=1; }
  echo "TestFlight preflight"
  [[ -n "${DEVELOPMENT_TEAM:-}" ]]      && ok "DEVELOPMENT_TEAM is set"                       || need "DEVELOPMENT_TEAM (your 10-character Apple team id)"
  security find-identity -v -p codesigning 2>/dev/null | grep -q -E "Apple Distribution|iPhone Distribution" \
                                         && ok "a distribution certificate is in the keychain" || echo "  • no distribution certificate in the keychain (automatic signing with -allowProvisioningUpdates can create one once you are signed in to Xcode)"
  [[ -f App/GoogleService-Info.plist ]]  && ok "App/GoogleService-Info.plist (production Firebase)" || need "App/GoogleService-Info.plist from your PRODUCTION Firebase project"
  [[ -n "${BACKEND_BASE_URL:-}" ]]       && ok "BACKEND_BASE_URL is set"                        || need "BACKEND_BASE_URL (https://southamerica-east1-<project>.cloudfunctions.net): without it first access and password reset are off"
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_KEY_PATH:-/nonexistent}" ]] \
                                         && ok "App Store Connect API key (for --upload)"      || need "ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (App Store Connect API key .p8, for --upload)"
  command -v xcodegen >/dev/null         && ok "xcodegen"                                       || echo "  • xcodegen not found (brew install xcodegen); the committed .xcodeproj is used as is"
  echo "  • Also needed in App Store Connect: an app record for com.fitcoach.app, and the export-compliance answer (ITSAppUsesNonExemptEncryption)."
  exit $missing
fi
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
OUT="build/testflight"

fail() { echo "✗ $1" >&2; exit 1; }

[[ -n "${DEVELOPMENT_TEAM:-}" ]]        || fail "Set DEVELOPMENT_TEAM (your 10-character Apple team id)."
[[ -f App/GoogleService-Info.plist ]]   || fail "Missing App/GoogleService-Info.plist — download it from your PRODUCTION Firebase project (never commit it)."
if [[ $UPLOAD -eq 1 ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_KEY_PATH:-/nonexistent}" ]] \
    || fail "--upload needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (App Store Connect API key, .p8)."
fi

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

rm -rf "$OUT" && mkdir -p "$OUT"
echo "▸ Archiving build $BUILD…"
xcodebuild archive \
  -project FitCoach.xcodeproj -scheme FitCoach -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/FitCoach.xcarchive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CURRENT_PROJECT_VERSION="$BUILD" \
  SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-}" BACKEND_BASE_URL="${BACKEND_BASE_URL:-}" FACEBOOK_APP_ID="${FACEBOOK_APP_ID:-}" \
  -allowProvisioningUpdates -quiet

# Per-run export options: inject the team and the destination.
cp ExportOptions.plist "$OUT/ExportOptions.plist"
/usr/libexec/PlistBuddy -c "Add :teamID string $DEVELOPMENT_TEAM" "$OUT/ExportOptions.plist"
[[ $UPLOAD -eq 1 ]] && /usr/libexec/PlistBuddy -c "Set :destination upload" "$OUT/ExportOptions.plist"

AUTH=()
[[ $UPLOAD -eq 1 ]] && AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "▸ Exporting${UPLOAD:+ and uploading}…"
xcodebuild -exportArchive -archivePath "$OUT/FitCoach.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates "${AUTH[@]}"

if [[ $UPLOAD -eq 1 ]]; then
  echo "✓ Uploaded build $BUILD. It appears in App Store Connect → TestFlight after processing (usually 5–30 min)."
else
  echo "✓ Dry run done: $OUT/export (nothing was uploaded). Re-run with --upload to send it to TestFlight."
fi
