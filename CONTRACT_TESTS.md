# Contract Test Readiness

Inherited Hermex API behavior was tested against upstream `hermes-webui` tag `v0.51.85`,
peeled commit `f1d399b437c1ca7fe4b6d2093aebe334c32f34a3`.

`UPSTREAM_TESTED_SHA` is the machine-readable inherited-compatibility pin. At the issue #14
bootstrap baseline, the intended fork repository name was `ebreen/hermes-webui`, and it had not
been created. Issue [#45](https://github.com/ebreen/hermex/issues/45) creates and verifies it, then
records its tested commit in `WEBUI_FORK_TESTED_SHA`. Until then, server implementation remains
blocked. A contract runner tests the fork first and consults upstream only for unchanged inherited
behavior.

When `WEBUI_FORK_TESTED_SHA` becomes non-empty, the trusted workflow performs an unauthenticated
fixed-host fetch from `github.com/ebreen/hermes-webui.git` and requires `FETCH_HEAD` to
equal the pin. It passes no token, checks out no fork files, and executes no fork script. An absent,
malformed, private, missing, or unreachable pin fails before `Trusted Contract Gate` can pass.

## Trusted Improvements Validator

`.github/workflows/contract-ci.yml` uses `pull_request_target` only as a read-only validation
boundary. It checks out the trusted base validator separately, treats the pull-request merge
tree as inert data, and never executes candidate code. The inert candidate checkout alone uses
`allow-unsafe-pr-checkout: true` so fork-originated PR merge refs can be read; it persists no
credentials. The base workflow requires `tests` to be a Git tree and
`tests/test_fork_contract.py` to be a regular `100644` blob, extracts that blob with `git cat-file`,
and compares its bytes with the base validator. Filesystem checks separately reject a symlink in
the validator path or any lexical ancestor. `Trusted Contract Gate` is the branch-protection check
for this boundary.

The validator also carries two base-relative one-way identity ratchets. One covers inherited Apple
Team and bundle/app-group/source-fallback values. The other covers inherited runtime owner URLs,
the predecessor URL scheme, and the old Share/Live Activity suffixes. Both scan regular content,
binary lines, paths, tracked `__pycache__` paths, and symlink targets. Because the identity tokens
are folded into bytecode, trusted Python runs with bytecode generation disabled: both the ordinary
`Improvements contract` job in `pr-ci.yml` and the trusted `contract-ci.yml` validator set
`PYTHONDONTWRITEBYTECODE=1`, and every local bootstrap run must set it too. The exact base multiset is the maximum: the base-relative
ratchet permits deletion but rejects copying, movement, or reintroduction. A separate atomic-state
gate accepts only the exact issue #14 quarantine or the complete canonical issue #15 replacement;
a partial migration fails. This lets issue #15 remove the quarantined identity without locking it in
place or permitting a half-migrated build.

Issue #14 is the one-time bootstrap. GitHub cannot run a new `pull_request_target` workflow until
that workflow exists on the default branch, so the issue #14 pull request cannot receive its own
trusted check. Its bootstrap gate is the complete local suite, Actionlint, exact-diff scans, the
ordinary read-only PR workflow, and independent exact-SHA review. After merge, require
`Trusted Contract Gate` before any later pull request can merge.

The bootstrap also adds the fork privacy notice at the future `master` URL used by the app. That
URL is expected to return `404` before issue #14 reaches `master`; this is not waivable for a
release. Immediately after merge, verify unauthenticated `2xx` responses and expected fork content
for both the configured privacy and support URLs before identity or artifact work continues.

An ordinary pull request must not change `tests/test_fork_contract.py` or any protected workflow's
exact-byte SHA-256 digest. Blank lines and comments are included because a comment inside `run: |`
can break a shell continuation. Use this trust-root update procedure only when the validator itself
must change:

1. Open a dedicated trust-root pull request containing only the validator, protected workflows,
   their executable digests, tests, and this procedure. Do not combine product code or secrets.
2. Run the old and replacement validators against the candidate tree. Prove each new poison goes
   RED before its fix, then run the exact parsed workflow steps locally.
3. Freeze the commit and obtain independent exact-SHA review of the full trust-root diff. A green
   candidate-owned workflow is not approval.
4. Merge only the reviewed SHA with an explicit administrator bypass of `Trusted Contract Gate`;
   do not disable the workflow or weaken repository permissions for other pull requests.
5. Verify the new default-branch workflow and digest immediately, then open a harmless canary pull
   request. The canary pull request must receive both `Trusted Contract Gate` and `CI Gate` before
   normal development resumes.

## Advance Policy

`UPSTREAM_TESTED_SHA` records the last upstream commit the app was *validated*
against. Without a rule for moving it, the pin drifts ever further behind
`master` and the contract tests validate against an increasingly ancient
upstream. This section is that rule.

**Trigger — what makes the pin eligible to advance.** A green live-smoke
against the target upstream release:

1. All read-only endpoint groups in this file's "Endpoint Priority" list return
   and decode through the app's tolerant `Codable` models.
2. The mutating checks run against **one disposable session only** (create a
   throwaway session, exercise branch/truncate/rename/pin/archive/move/delete,
   then delete it). No production or owner session is touched.

Only after both pass is the target release "validated".

**Cadence and owner.** The repo owner runs the smoke and advances the pin
**after each successful smoke** — there is no fixed calendar; the smoke is the
gate. When a smoke is green, move the pin to the latest release it validated.
When a smoke is skipped or held, the pin stays and the reason is recorded (in
`CURRENT.md` for the session, or the relevant issue).

**How to advance.** Replace the SHA in `UPSTREAM_TESTED_SHA` with the peeled
commit of the validated release, then update the human-readable tag references
in this file, `README.md`, and `DEVELOPMENT.md` to match. Commit the pin move
together with a one-line note of which smoke validated it. `PROJECT_SPEC.md`
§16 now points at the pin file instead of carrying its own copy, so it needs no
update on advance.

**Visibility.** `scripts/upstream-watch` prints `Releases behind tested pin`
(the count of release tags the target is ahead of the pin) in both the Triage
Verdict and Baselines. Past the loud threshold (default `20`, configurable with
`--releases-loud-threshold`) the digest emits a ⚠️ LOUD line in the verdict so
the validation debt cannot grow silently. The current gap is large because the
pin has never advanced via the watch cycle; the first advance happens the next
time the owner runs a green smoke.

> Follow-up candidate (`ready-for-agent`): the "releases behind" count is now
> computed; a future slice could add per-release diff summaries or auto-open a
> `needs-triage` issue when the loud threshold is crossed.

## Current Slice

This slice adds lightweight readiness coverage, not the full Docker-backed CI contract target from `PROJECT_SPEC.md`.

Implemented now:
- `HermesMobileTests/APIClientTests.swift` contains a contract-readiness matrix for every app-used `Endpoint` case.
- The matrix asserts HTTP method intent, path, and query parameters for health, auth, sessions, destructive session actions, streaming, uploads, workspaces/files, models/providers/profiles/reasoning, slash-command endpoints, read-only server panels, skills, memory, and analytics source endpoints.
- Focused request tests assert native POST calls do not send `Origin` or `Referer`, preserving the upstream CSRF contract for non-browser clients.
- Multipart upload request tests also assert no `Origin` or `Referer`.

Not implemented in this slice:
- No live calls to the owner's server.
- No Docker startup.
- No new Xcode contract-test target.
- No mutating checks against a real upstream instance.

## Endpoint Priority

Read-only checks, safe for live contract smoke tests:
- `GET /health`
- `GET /api/auth/status`
- `GET /api/sessions`
- `GET /api/session?session_id=...&messages=...`
- `GET /api/session/status?session_id=...`
- `GET /api/projects`
- `GET /api/workspaces`
- `GET /api/workspaces/suggest?prefix=...`
- `GET /api/list?session_id=...&path=...`
- `GET /api/file?session_id=...&path=...`
- `GET /api/file/raw?session_id=...&path=...`
- `GET /api/models`
- `GET /api/providers`
- `GET /api/settings`
- `GET /api/reasoning`
- `GET /api/profiles`
- `GET /api/personalities`
- `GET /api/commands`
- `GET /api/crons`
- `GET /api/crons/status`
- `GET /api/crons/output?job_id=...&limit=...`
- `GET /api/skills`
- `GET /api/skills/content?name=...`
- `GET /api/memory`

State-changing checks, only safe against disposable test data:
- `POST /api/auth/login`
- `POST /api/auth/logout`
- `POST /api/session/new`
- `POST /api/session/rename`
- `POST /api/session/delete`
- `POST /api/session/pin`
- `POST /api/session/archive`
- `POST /api/session/move`
- `POST /api/session/branch`
- `POST /api/session/truncate`
- `POST /api/session/update`
- `POST /api/session/compress`
- `POST /api/session/undo`
- `POST /api/session/retry`
- `POST /api/chat/start`
- `GET /api/chat/cancel?stream_id=...`
- `POST /api/chat/steer`
- `POST /api/default-model`
- `POST /api/reasoning`
- `POST /api/profile/switch`
- `POST /api/personality/set`

Streaming and async checks:
- `GET /api/chat/stream?stream_id=...`
- `GET /api/chat/stream/status?stream_id=...`
- `POST /api/btw`
- `POST /api/background`
- `GET /api/background/status?session_id=...`

Upload checks:
- `POST /api/upload`

## Future Full Contract Target

The full v1 target should:

1. Clone `ebreen/hermes-webui` and check out the SHA in `WEBUI_FORK_TESTED_SHA`.
2. Run the fork's full suite with the compatible Hermes Agent SHA recorded by issue #45.
3. Start the canonical fork in Docker with a disposable workspace and password.
4. Run an XCTest or command-line Swift contract harness against the local canonical fork base URL.
5. Exercise read-only endpoints first.
6. Create one disposable session for mutating endpoints, then run branch/truncate/rename/pin/archive/move/delete checks only against that disposable session.
7. Assert each JSON response decodes through the app's tolerant `Codable` models.
8. Verify SSE event decoding from a controlled stream fixture or a short disposable chat turn.
9. Run on pull requests and nightly.

For inherited compatibility, run the same relevant endpoint harness separately against
`nesquena/hermes-webui` at `UPSTREAM_TESTED_SHA`. That run cannot validate Improvements or
replace the canonical fork gate.

Until that target exists, the existing mock tests and this endpoint matrix are the readiness gate for request shape drift inside the iOS client.

## Upstream Watch Report

Use `scripts/upstream-watch` for the lightweight weekly upstream triage pass.
It compares `UPSTREAM_TESTED_SHA` and `UPSTREAM_TRIAGED_SHA` with a target
upstream ref, defaults to `.codex-tmp/hermes-webui` and `origin/master`, and
prints a markdown report.

`.codex-tmp/hermes-webui` is a local, read-only clone of the public upstream
that contributors create themselves (it is gitignored):

```bash
git clone https://github.com/nesquena/hermes-webui .codex-tmp/hermes-webui
```

Never modify that clone; it exists so endpoint shapes, tags, and diffs can be
checked against the exact upstream source.

Example:

```bash
scripts/upstream-watch --fetch
```

The report highlights:
- how many release tags the target is ahead of the tested pin
  ("Releases behind tested pin"), with a ⚠️ LOUD flag past the threshold
  (see "Advance Policy" above);
- mobile endpoint paths no longer found in upstream route literals;
- mobile endpoint paths missing from `APIEndpointContractTests`;
- newly added upstream route literals since the last triaged SHA;
- removed upstream route literals since the last triaged SHA;
- upstream route literals still unvalidated since the tested SHA, bucketed into
  **new / unclassified** (led by feature group so passkeys, Notes, TTS,
  `project-os`, and the expanded `/api/git/*` surface stand out), plus collapsed
  counts for **implemented** (derived from `Endpoints.swift`), **roadmap**, and
  **n-a** (classified from the `docs/agents/feature-gap-index.md` table);
- changed high-signal upstream files such as `api/routes.py`, `api/streaming.py`,
  model/provider/session modules, upload/media/workspace modules, and upstream
  contract/RFC docs;
- recent commit subjects containing risk keywords;
- the upstream `CHANGELOG.md` bullets added since the last triaged SHA, parsed
  from the `### Added/Changed/Fixed/Security/Removed` sections and rendered inline
  grouped by category (the highest-signal upstream summary; additive to the
  subject-keyword scan, which still covers cases where upstream forgets to update
  the CHANGELOG). Per-category lists cap at `--changelog-limit` (default 40); a
  truncated category shows `- ... N more` and logs the drop to stderr. Degrades to
  "None" when `CHANGELOG.md` is absent at either ref.
- new upstream **request keys** since the last triaged SHA — snake_case string
  literals read via `.get("<key>")` in `api/routes.py` (e.g. `explicit_model_pick`,
  `expand_renderable`) that a route-*path* diff cannot see. This catches new
  params/fields added to existing, unchanged routes; it is additive to the route
  and CHANGELOG scans. The list caps at `--request-key-limit` (default 80) with a
  `- ... N more` marker + stderr notice, and shows "None" when nothing was added.
- upstream **SSE wire event types the app does not handle** — the `event:` name in
  the 2nd positional arg of every `_sse(handler, "<name>", ...)` call in
  `api/routes.py` + `api/streaming.py`, unioned with the documented callback-emitted
  set (`token`, `reasoning`, `tool`, `tool_complete`, `title`, `done`,
  `interim_assistant`), minus the `case "<name>":` literals the app handles in
  `SSEClient.swift`. SSE drift is path-invisible (a new event lands on an existing,
  unchanged route), so this is additive to the route/CHANGELOG/request-key scans and
  feeds the coverage verdict. Wire `event:` names only — inner `event_type` fields
  (`tool.started`, etc.) are out of scope. The list caps at `--sse-event-limit`
  (default 40) with a `- ... N more` marker + stderr notice, shows "None" when fully
  covered, and degrades gracefully if either source file is missing.

Treat the report as triage input, not approved scope. Create `needs-triage`
issues for likely contract breakage or meaningful parity opportunities, and
promote an issue to `ready-for-agent` only after the app impact and acceptance
criteria are clear. Update `UPSTREAM_TRIAGED_SHA` only after the digest has
been reviewed and any follow-up issues have been created. Update
`UPSTREAM_TESTED_SHA` only after focused validation against that upstream commit.

The GitHub Action `Upstream Hermes-WebUI Watch` runs the same report, uploads
it as an artifact, and creates or updates the standing
`Upstream Hermes-WebUI watch digest` issue. It can be run manually and also
runs weekly on Monday at 14:00 UTC. Scheduled runs post the digest issue by
default; manual runs can disable issue posting with the `post_issue` input.
