# TestFlight Runbook Retired

The inherited TestFlight and App Store Connect release path is not active in this fork. Its
historical commands, Apple team identity, and upload evidence remain available in Git history;
they are not current instructions and must not be restored into CI.

Hermex distribution is an Apple-credential-free SideStore path:

1. issue #15 aligns the fork identity;
2. issue #29 builds with Apple signing disabled, applies entitlement-preserving ad-hoc
   signatures, and publishes the IPA, checksum, and provenance without Apple credentials;
3. issue #42 validates signing, install, upgrade, relaunch, extension behavior, refresh, and
   rollback on a physical iPhone.

Until those issues pass, the repository has no installable release artifact. See
[`docs/improvements-contract.md`](docs/improvements-contract.md),
[`DEVELOPMENT.md`](DEVELOPMENT.md), and the
[V1 execution map](https://github.com/ebreen/hermex/issues/1).
