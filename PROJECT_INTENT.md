# Hermex — Project Intent

This file is for fast orientation. `PROJECT_SPEC.md` describes the broader product and
implementation plan; `docs/improvements-contract.md` is normative for the Improvements
bounded context; `CONTEXT.md` locks domain language.

Hermex combines a native iPhone control/review surface with product-owned capabilities in
the canonical WebUI fork. The server is the execution and system-of-record plane. iOS is
a native interaction surface with a replaceable cache that remains read-only offline.

## Mental Model

- Start or continue native Hermes Sessions from iOS.
- Watch streaming agent work without using the desktop browser UI.
- Steer, stop, inspect, and recover work while away from the host machine.
- Study Improvement Subjects through bounded, consented Context Sources and review the
  resulting Proposals without automatically starting work.
- Keep authentication, navigation, composer controls, attachments, and offline recovery
  native while treating server versions as authoritative.

## Boundaries

- The Hermex WebUI fork is canonical for fork-owned records, versions, conflicts, sync,
  consent snapshots, and side effects.
- iOS caches server projections; offline writes are disabled, stale mutations receive an
  explicit conflict, and the server version wins.
- Generic Cron, Sessions, Profiles, Projects, Memory, and Kanban keep their native domain
  ownership. Improvements references them through Context Sources and Handoffs.
- Existing inherited APIs remain capability-checked. Never invent endpoint paths or JSON
  shapes; verify the running fork, fork source/docs, then upstream compatibility inputs.
- Improvements language, lifecycle, retrieval, learning, and Create & Start behavior must
  conform to `docs/improvements-contract.md`.

## Distribution and Identity

Hermex targets distribution as an Apple-credential-free, ad-hoc entitlement-seeded SideStore IPA after the identity, packaging, and physical-device gates pass. No installable fork artifact exists yet. Its product identity is
`Hermex`, application ID `no.gior.hermex`, and app group `group.no.gior.hermex`. Apple
signing credentials do not belong in CI or the repository.

## Decision Policy

Make reversible, repository-local product decisions autonomously within the selected
issue and canonical contracts. Request human input only for unknowable identity,
credentials, or irreversible external actions. Explicit issue constraints always win.

## Product Feel

The intended feel is dense, calm, operator-grade, and mobile-native. Prefer scan-friendly
screens, compact controls, clear status, safe confirmations, and direct recovery paths
over marketing-style UI.

## Fresh-Session Reading

Follow `AGENTS.md`: read `CURRENT.md` first if it exists (it is local-only and ignored),
then the canonical documents and only the `PROJECT_SPEC.md` sections relevant to the
selected issue.
