## What changed and why

## Checks (the pipeline enforces most of these; tick what only a person can judge)
- [ ] Tests added or updated for the behaviour that changed (a bug fix has a test that failed before it)
- [ ] No secret, key, token, `GoogleService-Info.plist` or real personal data in the diff
- [ ] Anything that reaches the network or Firestore: authentication, authorisation (whose data is this?) and input validation are in place and tested
- [ ] New personal data (health, photos, identifiers): `App/PrivacyInfo.xcprivacy` and the privacy answers reviewed
- [ ] A new Cloud Function endpoint is authenticated (ID token, App Check or a verified token) and rate-limited
