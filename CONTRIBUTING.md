# Contributing to Hermex

Thanks for your interest in contributing! This document covers local setup,
running tests, code signing for contributors, and the PR workflow. Please also
read the [Code of Conduct](CODE_OF_CONDUCT.md). Improvements changes must follow
the canonical [`docs/improvements-contract.md`](docs/improvements-contract.md).

## Local setup

- **Xcode 26 or newer** (the project builds with the iOS 18 SDK or later; the
  deployment target is iOS 18).
- Clone the repo and open `HermesMobile.xcodeproj`. Dependencies resolve
  automatically via Swift Package Manager — the dependency list is locked in
  `PROJECT_SPEC.md`; add one only through a selected issue that changes the
  locked stack and records why.
- Build and run the **`HermesMobile`** scheme on an iPhone simulator
  (`iPhone 17` is the reference device; any recent iPhone simulator works).
- To actually use the app you need your own
  Hermex-compatible WebUI fork. The fork is canonical for product-owned server
  capabilities; upstream [`hermes-webui`](https://github.com/nesquena/hermes-webui)
  remains an inherited-compatibility input. See the
  [README](README.md#making-the-server-reachable) for
  reachable-server options (Cloudflare Tunnel, reverse proxy, Tailscale, or
  `http://localhost:8787` for simulator-only testing).

## Running tests

The standard-library documentation/authority lock is the cheap first check and
runs for every PR, including documentation-only changes:

```zsh
python3 -m unittest tests/test_fork_contract.py -v
```

The full XCTest suite is the repo's green bar for changes to app, build, test, or
workflow code:

```zsh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
```

If that simulator name isn't installed, pick a nearby iPhone from
`xcrun simctl list devices available`. CI runs the same suite with code signing
disabled when a pull request changes non-documentation paths; docs-only pull requests run only
the standard-library contract lock. Forks therefore get green CI without signing secrets.

## Code signing for contributors

The product identity is `Hermex`, application ID `no.gior.hermex`, and app group
`group.no.gior.hermex`. Source/config alignment is handled by its dedicated
identity issue. **Never edit `project.pbxproj` merely to sign with your own
team** — override locally instead:

1. Create `Config/Local.xcconfig` (it is gitignored, so it never lands in a PR):

   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   // Optional — only needed if provisioning complains about the bundle ID.
   // The app-group entitlement must stay in sync with the bundle ID.
   // APP_BUNDLE_IDENTIFIER = com.yourname.hermex
   // APP_GROUP_IDENTIFIER = group.com.yourname.hermex
   ```

2. Build normally. `Config/Shared.xcconfig` is wired into the project and ends
   with `#include? "Local.xcconfig"`, so your local values override the
   committed defaults for every target — no project-file changes needed.

For simulator-only development you usually don't need any of this: simulator
builds don't require a paid team. Note that unit tests and CI run with
`CODE_SIGNING_ALLOWED=NO`; installing such a build on a simulator for *manual*
testing breaks Keychain entitlements — use a normally-signed build for that
(see `AGENTS.md`).

## What PRs we welcome (and what we don't)

Bug fixes, test coverage, and focused Improvements are welcome. Start anything
larger than a small fix from a selected issue and make reversible product
decisions autonomously within the canonical contracts. Human input is reserved
for unknowable identity, credentials, or irreversible external actions.
Drive-by rewrites, reformat-the-world diffs, and unscoped architecture overhauls
will be closed without detailed review.

Keep each PR to **one logical change** with a reviewable diff. If a change is
independently useful, it deserves its own PR.

## App bug or server bug?

Hermex spans native iOS and its canonical WebUI fork, so apparent app bugs may
come from either projection or server authority. Before filing a bug, reproduce
it in the fork's **web UI** against the same server:

- **Breaks in the web UI too** → file it in the canonical WebUI fork. Until issue
  [#45](https://github.com/ebreen/hermex/issues/45) initializes that repository, record
  the blocker on #45 instead. If the behavior is inherited unchanged, also link the relevant
  [upstream](https://github.com/nesquena/hermes-webui/issues) ticket and use the
  `upstream-change` label.
- **Only breaks in the app** → file it here with the bug-report form.

## PR workflow

1. **Start from an issue.** Every change should trace to a GitHub issue —
   comment on it so work isn't duplicated, or open one first (bug/feature
   templates are provided).
2. **Branch** from `master` as `issue/<number>-<short-slug>` (e.g.
   `issue/42-fix-session-search`).
3. **Make the change**, keeping these repo hard rules (full list in
   [`AGENTS.md`](AGENTS.md)):
   - **Tolerant decoding:** every `Codable` model uses optionals for fields the
     server might add or rename — never crash on unknown fields.
   - **Never invent API endpoints or JSON shapes** — verify the running fork,
     then version-matched fork source/docs; use upstream only for inherited
     compatibility.
   - **No new third-party dependencies** unless the selected issue explicitly
     changes the locked stack and records why.
   - **Improvements authority:** follow
     [`docs/improvements-contract.md`](docs/improvements-contract.md); server
     versions win and iOS remains read-only offline.
4. **Run the full test suite** (command above) and make sure it passes.
5. **Open a PR** against `master` using the PR template — link the issue with
   `Fixes #<number>`, describe what changed and how you tested it. CI must be
   green; automated review bots may comment, and the maintainer reviews and
   merges.
6. **Disclose AI usage** in one line of the PR description: the tool/model
   used (e.g. "built with Claude Code"), or "human-authored". This repo is
   itself built with coding agents, so it's normal context for review — not a
   gate.

`master` is the release-candidate branch. Protection is external repository state;
query GitHub before relying on branch protection. Distribution will produce an
Apple-credential-free, ad-hoc entitlement-seeded SideStore IPA. Contributors and CI never need Apple signing
certificates, provisioning profiles, App Store Connect keys, or private
deployment credentials; downstream users/installers provide signing.

## Questions

Open a [GitHub issue](https://github.com/ebreen/hermex/issues/new/choose) if
something here is unclear or wrong — docs fixes are welcome contributions too.
