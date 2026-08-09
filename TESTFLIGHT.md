# SideStore Release Runbook

The inherited TestFlight and App Store Connect release path is retired in this fork. Its
historical commands, Apple team identity, and upload evidence remain in Git history; they are
not current instructions and must not be restored into CI. Hermex distribution is the
Apple-credential-free SideStore path defined in [`docs/improvements-contract.md`](docs/improvements-contract.md) §11.

## Build

1. `xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO -archivePath build/Hermes.xcarchive archive`
2. The archive contains the app and its nested Share Extension and Live Activity appex with no
   Apple signature. The `SideStore IPA Tracer` workflow (`.github/workflows/ipa-tracer.yml`)
   then applies deterministic inside-out local ad-hoc signatures:
   1. sign each nested `.appex` first with `codesign --force --sign - --entitlements <extension entitlements>`;
   2. sign the app last with `codesign --force --sign - --entitlements <app entitlements>`.
   An ad-hoc signature carries no Apple identity or credential; it preserves concrete
   entitlement intent for SideStore inspection. A zero-signature artifact is never called
   SideStore-ready.
3. Package `Payload/HermesMobile.app` into `Hermes-<version>-<build>-<short-source>.ipa` with
   `zip -qry`.
4. The workflow fails closed when any embedded provisioning profile, inherited identity,
   dependency-lock drift, contract-suite failure, or packaging mismatch is detected, and emits
   the IPA, a `Hermes-SHA256SUMS.txt` checksum, and a provenance manifest (source commit,
   toolchain, OS) as downloadable artifacts with bounded retention.

## Install and refresh on iPhone

1. Download the IPA and verify its SHA-256 against `Hermes-SHA256SUMS.txt`.
2. Open it in SideStore. SideStore replaces the ad-hoc signatures with the installer's
   profiles and signatures, and may remap app groups. The app and Share Extension resolve the
   same effective `ALTAppGroups` value after refresh.
3. Launch, verify login, chat streaming, Share Extension draft handoff, Live Activity, and
   background refresh; then run the release smoke checklist and report results to issue #42.

## Rollback

Rollback is a rebuild, not a blind downgrade: select the last known-good source tag, run the
protected rollback workflow against that source, give the rebuilt artifact a new higher
`CFBundleVersion`, retain the source version and rollback provenance, verify its checksum,
re-sign and install through SideStore, and run the smoke checklist. Keep the latest known-good
release locally or in private storage before installing a new build.

Until issues #29 and #42 pass, the repository has no installable release artifact. See the
[V1 execution map](https://github.com/ebreen/hermex/issues/1).
