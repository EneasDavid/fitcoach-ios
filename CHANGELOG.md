# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/). Versions below **1.0.0** are initial development: they are published as GitHub
*pre-releases* and anything may change. See [`docs/RELEASING.md`](docs/RELEASING.md) for what "stable" will mean.

## [Unreleased]

### Changed
- A **Debug** build without `App/GoogleService-Info.plist` now opens in the in-memory demo mode instead of crashing in `FirebaseApp.configure()`, so a fresh clone runs
  with no Firebase project. **Release** builds never fall back (a missing plist stays a hard failure). `-UITestMode` still forces the demo.

## [0.1.0] - 2026-11-17

First public snapshot.

### Added
- **Student app**: today's workout from the rotation (not the weekday), a dedicated screen per exercise (muted video, muscles, collapsed substitutions), numeric-keypad
  load entry, rest timer, locked completed sets with "undo last", effort sheet, month-calendar history with a full per-day record, a feed of shareable cards with
  photos, gym-arrival detection, Strava and Spotify connections, "reduce motion & data" mode, pt-BR localisation, iPad layout.
- **Trainer area**: student roster by CPF + name with private nicknames, workout editor, individual progress charts the trainer builds, strength-week / volume-week
  cycles with a warning when the student lifts the wrong way round, **summary metrics** (attendance, volume load, session-RPE load, acute:chronic load, estimated 1RM,
  rest and rep-range compliance, sets per muscle), **run a workout next to the student** (loads, sets and rest entered by the trainer, saved to the student's history), body
  data (weight, height, BMI, bioimpedance), photos students attach, trainer details (name, photo, CREF) shown to students.
- **Account**: CPF/CREF sign-in, first access (CPF + name), forgot password (CPF + registered e-mail, one-time code), CPF mask.
- **Backend**: Firestore security rules with emulator tests, Cloud Functions (registration, password reset, Strava, Places proxy) with unit tests.
- **Pipeline**: regression CI (package tests with a 70 % coverage gate, rules, functions, app + UI on an iPhone simulator) and a security pipeline (gitleaks, Semgrep,
  OWASP Dependency-Check, npm audit + CycloneDX SBOM, MASVS/API-Top-10 static checks, OWASP CI/CD hardening checks, opt-in CodeQL, manual OWASP ZAP).

### Security
- CPF is never stored raw (server-keyed HMAC + masked display); nicknames are unreadable by students; photos reach the trainer through a separate collection so
  cards (which can carry the songs that were playing) stay private; coached sessions live in a trainer-written collection.

### Known limitations
- Not run against a real Firebase project; **no database is configured** (the app runs in demo mode with in-memory data).
- Not uploaded to TestFlight (needs a paid Apple Developer account); in-app account deletion and a health-data consent screen are not built.
- Some UI regression tests are known to fail (password-reset flow, full-day history detail); see the CI run of the release commit.

[Unreleased]: https://github.com/EneasDavid/fitcoach-ios/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/EneasDavid/fitcoach-ios/releases/tag/v0.1.0
