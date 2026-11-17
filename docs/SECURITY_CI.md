# Security and regression pipeline

Two workflows run on every pull request and every push to `main` (plus a nightly regression run and a weekly security run):
[`ci.yml`](../.github/workflows/ci.yml) (regression) and [`security.yml`](../.github/workflows/security.yml) (security).
Nothing in them needs a secret except the optional `NVD_API_KEY`. **They have not been run on GitHub yet** — the first push is the first real run;
expect to adjust runner images or scanner flags (see *First run* below).

## Regression (`ci.yml`)
| Job | What it runs | What it protects |
|---|---|---|
| `ci-scripts` | `python3 -m unittest` over `scripts/ci` | the security checkers themselves: each rule is shown to catch a planted violation |
| `functions` | `npm test` (`node --test`) in `functions/` | registration, password reset, Strava, Places logic |
| `rules` | Firestore emulator + `firebase/tests/rules.test.js` | **authorisation**: who can read/write what (BOLA/BFLA regressions) |
| `packages` | `scripts/coverage.sh` (Domain, SyncKit, SecurityKit, DataKit, PresentationKit) | business rules, sync, encryption, presentation; **fails below 70 % coverage** |
| `app` | `xcodebuild test` on an **iPhone** simulator: app tests + the XCUITest flows | the flows a person actually takes (never an iPad: by design) |

## Security (`security.yml`)
| Job | Tool (OWASP project) | Finds | Blocks the build? |
|---|---|---|---|
| `secrets` | gitleaks | credentials in git history | yes |
| `sast-semgrep` | Semgrep, OWASP Top 10 + JavaScript + secrets rule packs | injection, weak crypto, insecure patterns | yes |
| `masvs-static` | `scripts/ci/masvs_static_checks.py` | see below | yes |
| `sca-dependency-check` | **OWASP Dependency-Check** | known-vulnerable dependencies (CVSS ≥ 7) | yes — needs `NVD_API_KEY`, otherwise skipped with a warning |
| `sca-npm` | `npm audit` + **OWASP CycloneDX** SBOM | advisories in the Cloud Functions' production dependencies; an SBOM artifact | production deps: yes · test tooling: report only |
| `workflow-hardening` | `scripts/ci/check_workflows.py` | the **OWASP Top 10 CI/CD Security Risks** in these very workflows | yes |
| `codeql` | CodeQL (Swift, JavaScript) | semantic SAST | opt-in (`ENABLE_CODE_SCANNING=true`; needs a public repo or GitHub Advanced Security) |
| `zap-baseline` | **OWASP ZAP** baseline | passive DAST findings on a deployed backend | manual only (`workflow_dispatch` with a URL you own) |

### What `masvs_static_checks.py` verifies (OWASP MASVS v2 / API Security Top 10)
cleartext `http://` URLs and App Transport Security (NETWORK-1) · weak hashes/ciphers (CRYPTO-1) · secrets in `UserDefaults`, Keychain items readable
while locked, secrets committed anywhere in the tree (STORAGE) · privacy manifest, tracking declaration, location purpose string (PRIVACY) ·
debuggable entitlements · **Firestore rules**: no `if true`, every write tied to an owner, default-deny present (API1/API5) · **Cloud Functions**: every HTTP
endpoint authenticates the caller or verifies a token (API2).

### What this does **not** cover
- No dynamic mobile testing (OWASP MASTG): traffic interception, runtime hooking, binary reverse engineering. Do that by hand before a public release.
- MASVS-RESILIENCE (jailbreak detection, obfuscation, anti-tamper) is not implemented.
- Swift dependency scanning is partial: Dependency-Check reads `Package.swift`, but the app's Firebase dependency is declared in `project.yml`
  (XcodeGen), which no scanner reads. Dependabot (`swift` ecosystem) and the GitHub dependency graph help once the generated project is resolved.
- The scanner containers (`semgrep`, `gitleaks`, `dependency-check`, `zaproxy`) use the `latest` tag on purpose, to receive new rules; they run with a
  read-only token and no secrets. Every GitHub **action** is pinned to a full commit SHA (with its version in a comment): a tag can be repointed, a SHA cannot.
  Dependabot proposes the SHA updates, with a 7-day cooldown.

## One-time repository settings
1. **Branch protection on `main`** (Settings → Branches): require a pull request, require the checks `ci-scripts`, `functions`, `rules`, `packages`, `app`,
   `secrets`, `sast-semgrep`, `masvs-static`, `workflow-hardening`, require branches up to date, block force-pushes.
2. **Secrets and variables**: `NVD_API_KEY` (secret, free from nvd.nist.gov) to enable Dependency-Check; `ENABLE_CODE_SCANNING=true` (variable) once
   code scanning is available.
3. **Settings → Code security**: enable Dependabot alerts and security updates, secret scanning and push protection; private vulnerability reporting.
4. **Actions → General**: set the default workflow permission to *read repository contents*, and *require approval for first-time contributors*.
5. For TestFlight: an environment named `testflight` with a required reviewer holding the Apple secrets (see `testflight.yml`).

## First run
The macOS jobs assume an image with Xcode 26 or newer (`macos-26`); if your account does not have it, change `runs-on`. `scripts/ci/pick_iphone.sh` picks
whichever iPhone simulator exists. The UI job takes well over 15 minutes. If a scanner flags something, fix it or suppress it **with a written reason
and an expiry** (`.github/dependency-check-suppressions.xml`, or a `# nosemgrep: <rule>  reason` comment).

## Known open advisory
`firebase/` (the emulator test harness) pulls `@firebase/firestore`/`@grpc/grpc-js` versions with high-severity advisories. It is a development-only
tool that never ships and never touches production data; npm's suggested fix (an old major version) is not a real fix. It is reported, not blocking,
and tracked by Dependabot.
