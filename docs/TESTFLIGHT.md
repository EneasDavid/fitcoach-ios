# Getting FitCoach onto TestFlight

I can't upload for you: it needs your Apple Developer account, signing and an App Store Connect record. Everything else is ready.

## Once, in your Apple account
1. **Apple Developer Program** membership (paid). Note your **Team ID**.
2. **Identifiers** → App ID `com.fitcoach.app` (change the bundle id in `project.yml` if you prefer another) with *Sign in with Apple*.
3. **App Store Connect** → My Apps → **+** → New App (same bundle id). Fill the privacy answers to match `App/PrivacyInfo.xcprivacy`
   (fitness + health data, e-mail, other user content; location is **not** collected — it stays on the device).
4. **App Store Connect API key** (Users and Access → Integrations): download the `.p8`, note *Key ID* and *Issuer ID*.
5. **Firebase**: a *production* project, Firestore in a region near your users (`southamerica-east1` for Brazil), App Check with App Attest,
   rules deployed (`firebase deploy --only firestore:rules,firestore:indexes`), functions deployed with their secrets.
   Download **`App/GoogleService-Info.plist`** (git-ignored — never commit it).
6. **Export compliance**: the app only uses OS-provided encryption (TLS, CryptoKit). Decide the `ITSAppUsesNonExemptEncryption` answer with
   whoever owns compliance — it is a legal declaration, so it is deliberately not preset.

## Per build
```bash
# dry run — archives and exports an .ipa, uploads nothing
DEVELOPMENT_TEAM=ABCDE12345 scripts/testflight.sh

# upload to TestFlight
DEVELOPMENT_TEAM=ABCDE12345 ASC_KEY_ID=XXXX ASC_ISSUER_ID=xxxxxxxx-… ASC_KEY_PATH=~/keys/AuthKey_XXXX.p8 \
SPOTIFY_CLIENT_ID=… BACKEND_BASE_URL=https://southamerica-east1-<project>.cloudfunctions.net \
  scripts/testflight.sh --upload
```
After processing (5–30 min) the build shows up in **TestFlight**; add internal testers (up to 100, no review) or an external group
(first build needs *Beta App Review*).

## Known gaps before a real beta
- **Sign-in**: CPF/CREF recognition and routing work, but production has no CPF/CREF → account backend yet
  (`UnconfiguredAuthenticationService`). Testers can't log in on a production build until that exists.
- **Trainer area**: a placeholder.
- The integrations (Spotify, Strava, Places) switch themselves off when their ids / `BACKEND_BASE_URL` are empty.
- `.github/workflows/testflight.yml` is a manual workflow and has not been run.
