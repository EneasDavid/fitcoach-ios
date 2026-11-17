# Security policy

## Reporting a vulnerability
Please **do not open a public issue**. Use GitHub's private reporting: *Security → Advisories → Report a vulnerability* on this repository.
Include what you found, how to reproduce it, and which part of the system it touches (iOS app, Firestore rules, Cloud Functions). Expect an
acknowledgement within a few days.

## What is in scope
The iOS app (`App/`, `Sources/`), the Firestore security rules (`firebase/firestore.rules`) and the Cloud Functions (`functions/`).
Student data includes **health and body measurements, photos and identifiers (CPF)**: treat any way to read another person's data, to write
data you do not own, or to enumerate who is registered as high severity.

## How the project defends itself
See [`docs/SECURITY_CI.md`](docs/SECURITY_CI.md): secret scanning, SAST, dependency scanning, MASVS-mapped static checks, hardened workflows and
the regression suites that pin the security rules.
