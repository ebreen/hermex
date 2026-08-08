# AGENTS.md — working agreement for Hermex

Hermex is a native SwiftUI iPhone app (Xcode target/scheme `HermesMobile`, product name
`Hermex`) plus product-owned capabilities in the canonical WebUI fork. Read by every
agent (Codex, Claude Code, …); keep this file tool-agnostic.

Canonical precedence is scoped rather than one-document-fits-all:

1. `docs/improvements-contract.md` governs the Improvements bounded context.
2. `CONTEXT.md` governs domain language, including the existing Kanban contract.
3. The relevant normative section of `PROJECT_SPEC.md` governs established app behavior.
4. The selected GitHub issue narrows the current slice but cannot silently contradict a
   canonical contract.

## Session start & wrap-up

- Read `CURRENT.md` first if it exists — it holds the latest resumable state. It is
  local-only (gitignored), never committed; a fresh clone will not have one.
- Read the canonical contract relevant to the issue, then only the `PROJECT_SPEC.md`
  sections needed for that slice.
- Active work lives in GitHub Issues. Implement only the issue selected by the human, one
  labeled `ready-for-agent`, or one named in `CURRENT.md` — not every open issue.
- On "wrap up": verify repository/build/test state, overwrite `CURRENT.md` with the new
  state (it stays uncommitted), then commit the work. History lives in `git log` and
  merged PRs; there is no append-only local log.

## How work flows

- One issue → one short `issue/<n>-slug` branch → one PR (branches with no issue use
  `chore/` or `fix/`). Issue, triage, and domain conventions live in `docs/agents/`.
- `master` is the release-candidate branch: keep it buildable and never do product work
  directly on it. Protection is external GitHub state, not a claim established by this
  file; query GitHub before relying on branch protection.
- Repository-local implementation and commits proceed autonomously. Obey explicit issue
  constraints on pushing or remote actions. Merging, publishing artifacts/releases, and
  other irreversible external actions require human authorization.

## Hard rules

1. **Never invent API endpoints or JSON shapes.** For fork-owned behavior, verify the
   authenticated running WebUI fork first (final wire arbiter), then its version-matched
   source/API documentation. Use https://get-hermes.ai/api-docs/ and the pinned upstream
   copy at `.codex-tmp/hermes-webui/` only as inherited-compatibility references. The
   upstream copy is read-only; refreshing it with `git pull` is fine.
2. **Respect the locked dependency stack.** Add a dependency only when the selected issue
   explicitly changes that contract and records the rationale.
3. **Tolerant decoding:** every `Codable` model uses optionals for fields the server might
   add or rename. Never crash on unknown additive fields or enum values.
4. **No destructive host commands** (`rm -rf`, `git push --force`, modifying
   `~/Library/LaunchAgents/`, or restarting host services). Use a safer alternative or
   leave an explicit human-run step when the action is genuinely irreversible.
5. **Do not commit broken work.** Run the focused checks and applicable full suite; fix
   regressions before committing.
6. **Honor Improvements authority.** The WebUI fork is the server system of record; iOS
   is a replaceable, read-only-offline projection. Follow
   `docs/improvements-contract.md` for IDs, conflicts, sync, consent, lifecycle, learning,
   and side effects.

## Tooling

- Prefer terminal validation; request Xcode UI involvement only when terminal and
  simulator tooling cannot answer the question.
- Use **XcodeBuildMCP** for simulator build/test/run/log; fall back to raw
  `xcodebuild`/`xcrun simctl` for archives or low-level diagnosis. Defaults live in
  `.xcodebuildmcp/config.yaml` (scheme `HermesMobile`, simulator **iPhone 17**); if that
  simulator is missing, pick a nearby iPhone and report which one.
- **Simulator installs must be signed.** Never install a `CODE_SIGNING_ALLOWED=NO` build
  for manual simulator testing because stripped entitlements break Keychain. Use
  XcodeBuildMCP `build_run_sim` or a normally signed Debug build. Compile-only CI may
  disable signing.
- Before review or commit, run the contract validator plus the focused/full applicable
  tests. Build and launch for a manual simulator check when UI behavior changes.

## App identity and distribution

Product/display name `Hermex` · application ID `no.gior.hermex` · app group
`group.no.gior.hermex` · internal Xcode target/scheme `HermesMobile`.

Distribution is an Apple-credential-free, ad-hoc entitlement-seeded SideStore IPA. CI and the repository must contain no
Apple signing secrets, certificates, provisioning profiles, App Store Connect keys, or
private deployment credentials. Source/config identity alignment belongs to its dedicated
implementation issue; do not mix it into unrelated slices.

## Working with the human

- Default to autonomous product decisions for reversible repository-local work. State
  consequential assumptions, but request input only for unknowable identity, credentials,
  irreversible external actions, or a decision explicitly reserved by the task.
- After each slice, report: (1) files changed, (2) build/test commands, (3) results, and
  (4) the next suggested step, plus a short manual simulator plan when UI changed.

## Keep this file honest

If this agreement contradicts a canonical contract or verified repository behavior,
report the conflict and correct this file in the same narrowly scoped documentation slice
when authorized. Prefer executable checks over repeated prose rules.
