# Versions and releases

## Versioning
[Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`, tagged `vMAJOR.MINOR.PATCH`.
- **PATCH**: fixes, no behaviour change a user would notice. **MINOR**: new features, backwards compatible (including the Firestore data model and the rules).
  **MAJOR**: breaking changes (a data migration, a removed endpoint).
- **0.y.z is initial development** and is published as a GitHub **pre-release**. So is anything with a suffix (`1.0.0-rc.1`).
- **"Stable" means ≥ 1.0.0.** Do not tag 1.0.0 until:
  1. the whole CI is green on the release commit, **including the app + UI regression job**;
  2. the app has been exercised against a real Firebase project (rules deployed, functions deployed, a full first-access → workout → history flow);
  3. a build has been through TestFlight on a real device;
  4. in-app account deletion and the health-data consent screen exist (App Store requirements for an app with accounts and health data);
  5. the open advisories in `docs/SECURITY_CI.md` are fixed or consciously accepted.

## Cutting a release
1. Move the `## [Unreleased]` entries of `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD` heading and add the compare link at the bottom.
2. Set `MARKETING_VERSION` in `project.yml` to `x.y.z`.
3. Commit, push, wait for CI. Then tag the commit and push the tag:
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z
   ```
4. `.github/workflows/release.yml` runs the regression suite on the tagged commit, builds the assets and creates the GitHub Release with the changelog section as
   its notes (a tag without a changelog section fails). Attached: source archive, CycloneDX SBOM of the Cloud Functions, `SHA256SUMS.txt`.

## What "Packages" means here
GitHub Packages does not host Swift packages: SwiftPM resolves a package straight from the repository's **tags**, so a release tag *is* the package version. The Swift
package in this repository is `FitCoachKit`, with the libraries `Domain`, `SyncKit`, `SecurityKit`, `DataKit` and `PresentationKit`:
```swift
.package(url: "https://github.com/EneasDavid/fitcoach-ios.git", from: "0.1.0")
```
(The repository is *all rights reserved*, see `LICENSE`: using it as a dependency needs the owner's permission.) The Cloud Functions are deployed to Firebase, not published
as an npm package, and the iOS app goes to TestFlight, not to the registry, so the *Packages* tab of the repository stays empty on purpose.
