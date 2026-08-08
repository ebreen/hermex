# Improvements Contract

**Status:** Canonical and normative

**Bounded context:** Improvements

**Applies to:** the Hermex WebUI fork, Hermex iOS, and every Improvements API consumer

This document locks the product language, authority, persistence, retrieval, lifecycle,
and delivery contract for Improvements. `CONTEXT.md` is the matching glossary. If another
canonical document conflicts with this contract, this contract governs the Improvements
bounded context and the conflicting document must be corrected.

## 1. Name and boundary

Improvements is the bounded-context name. An **Improvement Subject** is the thing being
studied; its UI label is **Subject**. `Feature` is not a persisted domain entity. Feature
and improvement may be ordinary descriptors for a Proposal, but neither receives a
standalone ID, lifecycle, repository, endpoint, or database table.

Improvements studies a Subject, retrieves bounded evidence, runs Dream Cycles, and offers
reviewable Proposals. It does not replace the systems that supply evidence or receive
work. Cron, Sessions, Profiles, Projects, and Kanban remain native referenced systems.
A Dream Schedule may use native Cron machinery, a Context Source may point at a native
record, and a Handoff may create or link a native destination; Improvements stores the
reference and its own history rather than copying or redefining those systems.

### Canonical server source

At the issue #14 bootstrap baseline, the intended future repository name was
`ebreen/hermes-webui`, and that fork had not been created. Issue
[#45](https://github.com/ebreen/hermex/issues/45) creates and verifies it from current
upstream. Its full tested commit is recorded in `WEBUI_FORK_TESTED_SHA`; until that file contains a
real 40-character fork commit and the fork repository exists, no server implementation slice may
start. A non-empty pin passes only after the trusted workflow performs an unauthenticated fixed-host
fetch from `github.com/ebreen/hermes-webui.git` and proves `FETCH_HEAD` equals that pin. It
passes no token and executes no fork script. After that gate, the authenticated running fork is the
final wire arbiter, then its version-matched source and tests. The
https://github.com/nesquena/hermes-webui repository remains a read-only inherited-compatibility
and upstream-sync input, never the authority for fork-owned Improvements behavior.

## 2. Canonical records and lifecycle

All persisted record IDs are stable opaque IDs. Each record carries a server version,
creation time, and last-change time unless it is an immutable event. IDs reveal no type,
ordering, Profile, or storage location and are never reused. The top-level records are:

| Record | Meaning | Lifecycle or mutability |
|---|---|---|
| **Subject** | The Improvement Subject being studied, with its Context Sources and guidance. | `active`, `paused`, or `archived`. Archived Subjects cannot run new Dream Cycles. |
| **Context Source** | A bounded reference to evidence for one Subject. | `active`, `suspended`, or `revoked`; revocation prevents later retrieval but preserves audit history. |
| **Consent Grant** | Versioned authorization for one principal, Schedule, provider boundary, source scope, purpose, and expiry. | `active`, `expired`, or `revoked`; terminal versions remain auditable. |
| **Dream Schedule** | The Subject, source set, trigger, Lead Profile, Lead Dream Perspective, optional Critic, and limits for recurring study. | `paused`, `enabled`, `degraded`, or `archived`. |
| **Dream Cycle** | One scheduled or manual attempt using an immutable consent snapshot and input manifest. | `queued`, `running`, `succeeded`, `no_proposal`, `invalid_output`, `failed`, `cancelled`, `unknown`, or `skipped_overlap`. A retry is a new linked Cycle, never a rewritten attempt. |
| **Proposal** | One reviewable, actionable thesis produced for one Subject and traceable to its originating Dream Cycle. | Review state is `new`, `reviewing`, `accepted`, `deferred`, `rejected`, or `dismissed`. Origin and original thesis remain immutable. |
| **Proposal Update** | Append-only evidence or reasoning that materially updates an existing Proposal without duplicating it. | Immutable after append. |
| **Proposal Decision** | An append-only human decision transition with actor, reason, time, and observed Proposal version. | Immutable; current Proposal review state is a projection of ordered Decisions and idempotent Review Return events. |
| **Handoff** | A human-confirmed connection to a native Session, Kanban Card, or other supported destination. | `preparing`, `created`, `started`, `outcome_uncertain`, `failed`, `cancelled`, or `completed`; destination IDs remain native-system IDs. |
| **Outcome** | The observed delivery/value result associated with an accepted Proposal and its Handoffs. | `unknown`, `in_progress`, `implemented`, `verified`, `abandoned`, or `superseded`, with versioned observations. |
| **Dream Perspective** | A reusable bounded angle such as Product, Reliability, Simplification, or Security/Privacy. | `active` or `archived`; a cycle snapshots the selected version. |
| **Subject Guidance** | Explicit human-authored or human-corrected preference for one Subject. | `active`, `superseded`, or `archived`; prior versions remain auditable. |
| **Learning Hypothesis** | An evidence-linked, inferred preference for one Subject. | `proposed`, `active`, `suppressed`, or `retired`; every transition is reversible and audited. |
| **Audit Event / Sync Event** | Immutable facts used for accountability and ordered replication. | Append-only ordered audit and sync events; correction is another event, never an in-place rewrite. |

Source Evidence and Proposal Score are versioned value records attached to a Cycle,
Proposal, or Proposal Update; they are not alternate names for the records above.
Each Dream Cycle is an immutable attempt. Retry creates a new linked Dream Cycle ID and
never rewrites a terminal attempt.

Hard deletion is not part of ordinary record lifecycle. Archive, revoke, suppress, retire,
or append a correcting event so decisions, consent, and external side effects remain
explainable. The sole user-visible exception is the explicit permanent Subject purge in §10.

### Allowed transitions and terminal effects

- Subject: `active` ↔ `paused`; either may become `archived`. Archive stops new Cycles. An
  archived Subject restores only to `paused`, so restoration cannot restart spend. Permanent
  purge is a separate explicit operation, not a status change.
- Context Source: `active` ↔ `suspended`; either may become terminal `revoked`. Re-adding a
  revoked source creates a new ID and consent lineage.
- Consent Grant: a new Grant starts `active`. It becomes `expired` when server time reaches its
  `expires_at`, or `revoked` through an append-only revocation event. Both states are terminal and
  cannot be reactivated. Renewal creates a new Consent Grant with a new stable ID and links it to
  its predecessor through `renewed_from_grant_id`. If the predecessor is still active, the same
  transaction revokes it with reason `superseded`. Renewal never rewrites a terminal Grant.
- Dream Schedule: `paused` ↔ `enabled`; validation or drift may move either to `degraded`;
  repair returns it to `paused`; `paused` or `degraded` may become terminal `archived`.
- Dream Cycle: `queued` may become `running`, `cancelled`, or `skipped_overlap`; `running`
  becomes one of the other terminal Cycle results. Terminal Cycles never reopen or rewrite.
- Proposal review: `new` may become `reviewing`; a new append-only Decision may project any
  non-purged Proposal to `accepted`, `deferred`, `rejected`, or `dismissed`. Dismissal and
  every other review decision may be reconsidered through another Decision event. Defer records
  a required `review_after` timestamp. At the first server reconciliation at or after that time,
  when the Subject is not archived, the server atomically appends exactly one idempotent
  `defer_elapsed` Review Return event linked to that Defer Decision and returns the Proposal from
  `deferred` to `reviewing` if no later Decision superseded the defer. Archived Subjects do not
  consume `defer_elapsed`; while archived, no event is appended and the overdue Proposal remains
  `deferred`. When the Subject is restored to `paused`, restoration reconciliation atomically
  appends the deterministic `defer_elapsed` event for each overdue, unsuperseded Defer Decision,
  transitions its Proposal to `reviewing`, and marks that event complete exactly once. Repeated
  reconciliation and restart replay use the Defer Decision ID as the event idempotency key. A
  Review Return never increments unread, accepts, creates a Handoff, or starts work.
- Handoff: `preparing` may advance to `created`, `outcome_uncertain`, `failed`, or `cancelled`;
  `created` may advance to `started`, `completed`, `outcome_uncertain`, `failed`, or `cancelled`;
  `started` may advance to `completed`, `outcome_uncertain`, `failed`, or `cancelled`. An ambiguous
  native response moves the Handoff to `outcome_uncertain`. After explicit reconciliation it may
  recover to the observed durable state, or to `failed` when absence is established. A failed
  Handoff may resume under the same ID to `preparing`, `created`, or `started`, according to its
  last durable completed step; retry never repeats a completed native side effect. Abandon handoff
  projects it to `cancelled` while preserving any native destination. `completed` and `cancelled`
  are terminal; all delivery facts remain in History.
- Outcome: `unknown` may become `in_progress`, `implemented`, `verified`, `abandoned`, or
  `superseded`; `in_progress` may become `implemented`, `verified`, `abandoned`, or
  `superseded`; `implemented` may become `verified`, `abandoned`, or `superseded`. A later
  versioned observation may supersede any non-superseded projection; prior observations remain.
- Dream Perspective: `active` may become `archived`; restoring creates a new active version so
  an existing Cycle snapshot never changes.
- Subject Guidance: correction creates a new `active` version and projects the previous one to
  `superseded`; active guidance may become `archived`; restoration creates a new active version.
- Learning Hypothesis: `proposed` may become `active`, `suppressed`, or `retired`; `active` and
  `suppressed` may move between each other or to `retired`; explicit restoration moves a
  `retired` hypothesis to `suppressed` for review before it can influence ranking again.

Changing a Proposal away from `accepted` does not cancel, delete, or roll back an existing
Session, Card, Handoff, or running work. It blocks new Handoffs until a later Decision projects
the Proposal back to `accepted`. Cancellation is an explicit native destination action.

## 3. Proposal, update, decision, and unread semantics

A candidate becomes a new Proposal only when it expresses a materially distinct,
actionable thesis for the same Subject. New evidence, a changed score, tighter reasoning,
or another observation about the same thesis becomes a Proposal Update. A Decision never
rewrites Proposal origin or content. Dismiss is a reversible low-interest choice; Reject
is a deliberate negative product decision; Defer keeps a Proposal eligible for later
review; Accept records value only.

Unread is a server-derived projection, not a mutable Proposal boolean. Only a new
threshold-clearing Proposal or a material Proposal Update increments unread. Handoff and
Outcome changes appear in History without increasing unread; no-proposal Cycles,
below-threshold candidates, retries, and diagnostics do the same. For each reviewing
principal and Proposal, the server stores the greatest unread-relevant event cursor actually
observed. Opening or marking a Proposal read advances only through the greatest cursor
delivered with that view, so a concurrent later Proposal Update stays unread. A review action
also marks the acted-on version read. All devices converge from the server cursor.

## 4. Authority, versions, conflicts, and offline behavior

The WebUI fork is the canonical server system of record. The iOS cache is a replaceable projection.
It contains server records and is read-only while offline. Deleting the cache and replaying
sync must recover the same canonical state.

Every mutable response includes its opaque ID and server version. A mutation names the
version it observed. The server version wins. A stale mutation receives an explicit conflict.
The conflict contains or references the current server version, and the client preserves
its draft for review rather than overwriting either side. The client never silently merges,
retries, or treats local cache state as newer authority.

Improvements never mutates native Memory. Memory excerpts may be retrieved only through
the consent and source rules in §7, while the native Memory system retains ownership.

### Storage scope

The Improvements domain owns a dedicated SQLite database under `HERMES_WEBUI_STATE_DIR`.
It is global to one WebUI deployment, not scoped to the currently active Hermes Profile.
Switching the active chat Profile must not hide, fork, or relocate Improvement records.

The implementation uses Python stdlib `sqlite3`, WAL mode, foreign keys, and explicit schema migrations.
A restorable backup before every migration is mandatory. Migration
failure leaves the previous database and API contract authoritative.

The database stores stable references and last-observed metadata for native Hermes
objects. It must not copy whole Sessions, Cards, Profile files, Memory files, or chat
histories. Cross-Profile reads must not temporarily switch process-global `HERMES_HOME`
during a request; they use an explicit global-domain adapter.

## 5. IDs, idempotency, API compatibility, and ordered sync

All Improvements mutations require an idempotency key. A native side-effect adapter may retry
automatically only when the destination enforces that key or offers an authoritative lookup that
proves the prior attempt did not take effect. Repeating the same actor, operation, target,
payload, and idempotency key returns the original logical result inside the Improvements domain.
Reusing a key for a different payload is an explicit client error. When a destination cannot
deduplicate or prove absence, an ambiguous timeout becomes `outcome_uncertain` and stops; it is
never treated as permission to repeat the side effect.

The API advertises a `major.minor` contract version:

- Within one major version, additive minor versions may add optional fields, enum values,
  event kinds, capabilities, and read endpoints. Clients may ignore unknown optional fields.
  An unknown lifecycle or side-effect-bearing enum value is preserved and shown as a visible
  unsupported state; the client disables unsafe actions instead of ignoring, coercing, or
  guessing its meaning.
- Removing or renaming required meaning, changing authority or ordering, or changing a
  mutation's side effects requires an explicitly incompatible major version. A client
  that does not support that major blocks Improvements writes and reports incompatibility;
  it never guesses a nearby payload or endpoint.

The ordered cursor sync contract is ascending and gap-aware. Each Sync Event has a stable
event ID, opaque cursor, and `previous_cursor`. Every page echoes its requested
`from_cursor`, returns an ordered event chain, and includes `next_cursor` plus the server's
`high_water_cursor`. The first event must name the requested cursor as its predecessor and
each later event must name the prior event cursor. Duplicate event IDs are harmless.

If the server cannot prove continuity because a predecessor expired, a cursor is unknown,
or the chain is impossible, it returns an explicit `reset_required` response rather than an
apparently empty page. An authoritative snapshot is captured atomically with a
`snapshot_cursor` high-water mark. The client replaces its projection with that snapshot,
then requests and applies events strictly after that snapshot cursor; writes committed after
the snapshot watermark therefore cannot be lost.

A non-empty page's `next_cursor` is exactly the cursor of its final event. An empty page returns
`next_cursor` equal to the echoed `from_cursor`; `high_water_cursor` advertises later work but
never advances the client by itself. Any tail mismatch returns `reset_required`. A page's
`next_cursor` is committed only after its whole chain succeeds. Unknown required invariants or
impossible version transitions also force snapshot and replay. Archive and revocation tombstones
participate in the same order. Audit ordering and sync ordering may use separate cursors, but
each is total within its advertised stream.

Server schema migrations are forward-only, transactional, and backed by a restorable
server snapshot. Restore and replay happen on the server; iOS is rebuilt from sync rather
than used as a backup. Migration failure leaves the prior schema authoritative and does
not publish a partially upgraded major version.

## 6. Dream scheduling and generation guardrails

Seeded and newly created Dream Schedules start Paused. Activation is an explicit server
mutation. A Subject may own multiple schedules. Each enabled schedule has exactly one Lead
Profile and one Lead Dream Perspective plus an optional independent Critic Profile. The
Critic may be `none`, `advisory`, or `required`; it can challenge or rescore candidates but
cannot approve execution.

The installation migration idempotently creates two suggested Subjects under immutable seed
keys: `hermex-fork` for this Hermex fork and `hermes-agent-deployment` for the Hermes Agent
deployment. Each receives one suggested daily Schedule template under its own stable template
key. Both templates start paused, permit **Run Now**, and suggest staggered overnight times.
Display names and times are editable, but seed keys are never reused. Restart does not duplicate
them, and archive or permanent purge is never undone by reseeding. Onboarding still requires
explicit confirmation of timezone, Profile, source policy, consent, and provider/model behavior
before enablement. Additional Subjects remain user-addable and their schedules also start paused.

Each schedule stores its recurrence, explicit IANA timezone, Profile, optional provider/model
override, trusted Project or absolute workdir, skills, restricted toolsets, source policy,
budgets, retry policy, Cron projection ID/hash, and reconciliation state. Omitted model and
provider inherit the Profile. Profile and every trusted reference must validate before the
schedule becomes `enabled`.

Lead and Critic execution has read-only source access. It cannot commit, open a pull request,
edit a Card, create a Session, change a Schedule, invoke a Handoff, or recursively schedule
work. Generated content cannot expand the approved source, skill, toolset, workdir, provider,
or execution boundary. Only the separately confirmed Handoff contract in §8 can cross from
generation into a native side effect.

V1 uses one deployment scheduling timezone: `Europe/Oslo`. Every schedule stores it for
forward compatibility and enablement rejects a different zone. Hermes timezone configuration
is explicit; server-local fallback is not authority. The editor previews the next three
wall-clock runs and UTC offsets, warns about ambiguous or nonexistent daylight-saving times,
and avoids suggesting the local 02:00 transition hour. Per-schedule timezone execution is not
silently emulated in V1.

Improvements owns every Dream Schedule. Cron is an idempotent execution projection, not the
schedule system of record. A Cron job ID is an adapter reference, never a Subject or Schedule
identity. Enabling or changing a schedule reconciles one owned recurring job in the selected
Profile. Each recurring, catch-up, retry, and manual projection is a `no_agent` script-only
admission adapter. It carries only the Schedule ID/version, projection identity, and native fire
ID to an authenticated loopback Improvements entrypoint; it contains no excerpts, prompt,
provider credential, or model invocation. It is local-delivery only and is not attached to a
chat. Candidate-controlled Cron text cannot bypass admission or call a provider directly.

Every fire passes through one transaction before any native agent invocation, retrieval, or
provider submission. The transaction reserves the Cycle under the native fire idempotency key;
validates that the Subject is `active`, the Schedule and projection version permit that trigger,
and every Context Source, Profile, workdir, toolset, skill, budget, retry rule, and dependency is
still valid; resolves the Lead and optional Critic provider/model independently; verifies the
matching current Grants; and acquires one durable per-Subject lease. The lease records the Cycle,
owner, acquisition and heartbeat times, expiry, in-flight provider deadline, and a monotonically
increasing fencing token. Only after that transaction commits may the controlled worker start.
Every retrieval, provider submission, result ingestion, and lease renewal must present the
current token; a stale fencing token fails closed before data access or egress.

The initial lease lasts 120 seconds and a live worker heartbeats at least every 30 seconds. Before
one bounded provider request, it renews the lease beyond that request's enforced timeout plus a
safety margin and commits an in-flight marker/deadline. A lease that expires before any invocation
marker records `failed` with `lease_expired` and permits a later fire. Expiry after a native or
provider invocation records `unknown`; automatic takeover remains blocked even after the deadline
until authoritative result/status lookup proves the invocation terminal and reconciliation has
atomically fenced the old token. If the destination or provider offers no authoritative lookup,
the Subject remains Needs attention and later fires record a zero-egress policy skip. Only a
separate product-owner confirmation that identifies the uncertain invocation and restart risk may
abandon that block; it is never a retry or automatic catch-up. A crashed or resumed worker can
continue only while it still owns the lease and exact token. Responses from a fenced worker are
discarded and cannot authorize another retrieval, submission, or ingestion.

**Run Now** uses the same admission transaction and creates one owned, due-now, one-shot Cron job
from the same immutable schedule snapshot. It never resumes, changes, or silently enables the
recurring projection. The UI returns `queued`; it does not hold an HTTP request open, and a
healthy gateway should claim the one-shot within 90 seconds. A duplicate **Run Now** opens the
active Cycle rather than creating another.

Only one Dream Cycle may run for a Subject, even when several schedules fire. A fire that loses
the lease transaction records `skipped_overlap`, links the active Cycle, and performs zero
retrieval or provider egress. A fire that fails Subject, Schedule, source, role, Grant, or
configuration validation records a policy-specific terminal Cycle and also performs zero
retrieval or provider egress. A losing or policy-blocked fire never queues a backlog. Native
collapsed catch-up creates at most one `catch_up` Cycle after downtime and advances to the next
future occurrence; it never replays every missed interval. Pausing stops future recurrence only.

A transient provider/network or schema-ingestion failure permits one bounded retry as a new
linked one-shot Cycle. The retry keeps `retry_of_cycle_id`; neither attempt is rewritten.
Policy, permission, missing-reference, deterministic validation, cancellation, and `unknown`
failures do not retry automatically. V1 offers **Stop after current Cycle** by pausing future
recurrence and may record `cancellation_requested`; it does not offer a hard-cancel that the
native scheduler cannot guarantee.

Cron output is diagnostic transport, not canonical Proposal state. A Dreamer's entire final
response is one bounded JSON envelope with at least:

```json
{
  "schemaVersion": 1,
  "subjectId": "subject-id",
  "scheduleId": "schedule-id",
  "result": "no_proposal",
  "summary": "bounded summary",
  "proposals": []
}
```

The `result` enum is exactly `proposals` or `no_proposal`. `proposals` requires from one
through five validated Proposal objects. `no_proposal` requires an empty `proposals` array.
Cycle failure states are never valid Dreamer envelope `result` values; the ingestion service
records `invalid_output`, `failed`, `cancelled`, or `unknown` from its own observed execution
and validation outcome. The summary is required, nonblank, and bounded for either valid result.

Ingestion uses the native Cron execution ID as its idempotency key and validates identity,
size, UTF-8, schema version, enums, source permissions, and Proposal count before one atomic
commit. Malformed output creates no partial Proposals.

Reconciliation runs at startup, after every Schedule mutation, and periodically. A paused Schedule
with an active Cron projection reconciles by pausing that Cron job. A deleted or renamed Profile, or a missing provider,
model, workdir, skill, or tool,
makes the Schedule `degraded` and blocks execution; the service never silently switches a
reference. An externally edited owned job is paused and shown as drift with **Repair from
Schedule** and validated **Adopt changes** actions. An orphaned owned job is paused and reported,
never deleted automatically. When the scheduler heartbeat is unhealthy, Schedule health is
`degraded` without rewriting domain configuration. An interrupted native execution with unknown
side effects records `unknown` and requires human review. Generic Cron views mark managed Dream
jobs and direct edits back to the Subject schedule editor.

Detection and repair are separate durable phases. If reconciliation finds a missing, duplicated,
or drifted owned recurring projection, its first transaction commits the Schedule as `degraded`,
blocks new Cycles from that projection set, and appends an audit/sync event with every observed
Cron job ID and normalized projection hash. That detection transaction does not repair the
projection.

A later **Repair from Schedule** recreates a missing projection or repairs duplicates. For a
missing projection, the next reconciliation invokes the operation automatically, but only after
the degraded transaction and sync event commit. Duplicate or drift repair requires the explicit
human action. For duplicates, the operation keeps the stored `cron_projection_id` only when that
job has the Schedule tag and
exact canonical projection hash. Otherwise, the lexicographically smallest valid managed job ID
is the deterministic winner among exact tag-and-hash matches. If none match, there is no winner:
the service pauses every candidate and creates or recovers one replacement under the Schedule
projection idempotency key. It pauses every non-winner, preserves it for audit, and never deletes
it automatically. Repair may restore `degraded` to `paused` only after reconciliation observes
exactly one valid projection. A human must enable recurrence again.

V1 does not depend on APNs or iOS background execution. Hermex refreshes the server-authoritative
unread count on launch, foreground, and manual refresh. Quiet and `no_proposal` Cycles create
History without an unread Proposal.

A candidate Proposal includes title/kind, Subject and Perspective, a concrete problem or
opportunity, bounded change and non-goals, impact, acceptance evidence, dependencies,
cost, risks, rollback, confidence, counterargument, suggested destination, and a deterministic
fingerprint. Each factual Source Evidence entry records a stable locator, observed time,
bounded excerpt or claim summary, freshness/access state, and classification:
`verified`, `strong_inference`, `assumption`, or `speculation`.

Proposal kind is exactly `Feature` or `Improvement`. Unknown kinds fail validation before
scoring; they are never coerced into a nearby value.

Reject a candidate before scoring if it violates source/tool policy; exposes a secret or
disallowed personal data; makes an unsupported factual claim; has no concrete
problem/opportunity, impact, or acceptance evidence; is generic advice without a bounded
change; is an exact duplicate; or asks for automatic merge, deployment, credential changes,
or other out-of-scope autonomy.

Deduplication has three ordered layers. First, a unique deterministic fingerprint detects an
exact semantic key for the same Subject, affected area, problem, and intended outcome. Second,
local similarity retrieves a bounded related-record corpus across active, rejected, dismissed,
archived, and implemented Proposals; `active` includes `new`, `reviewing`, `accepted`, and
`deferred`, and compacted records remain eligible through their retained fingerprint, title,
reason, and relationship metadata. Third, the Lead and Critic compare the candidate with that
bounded set and persist a novelty explanation. Probabilistic similarity is retrieval only and
must not reject a candidate by itself, select a canonical record, or create an Update without the
semantic comparison. An exact retry returns the existing record. The same thesis/outcome with
genuinely new evidence creates an immutable Proposal Update linked to that Proposal. A material
difference creates a new related Proposal and records the relationship; it is not discarded as a
near duplicate.

Only candidates that pass every hard gate receive Proposal Score. The score is an integer from
0 through 100 and the initial inbox quality threshold is 70. The fixed V1 score weights are
**Evidence 25**, **Impact 20**, **Novelty 15**, **Specificity and testability 15**,
**Feasibility and scope 15**, and **Strategic fit 10**. The Inbox shows the dimension
breakdown and Critic rationale and never presents the score as objective truth.

Critic mode is deterministic. With `none`, a structurally valid Lead result proceeds through
the same hard gates and score. If an advisory Critic fails, an otherwise valid Lead Proposal
may publish with a visible `single_pass` badge. If a required Critic fails, no Proposal enters
the inbox. A required Critic may veto a hard-gate failure regardless of numeric score, but it
cannot invent an unrelated Proposal or authorize execution.

A Cycle may publish up to five Proposals after hard gates, scoring, deduplication, and required
Critic review. It has no quota; zero Proposals is valid and is distinct from failure or
cancellation. Rejected, below-threshold, and lower-ranked candidates remain only as bounded
Cycle diagnostics and never increment unread.

The cycle snapshots its schedule version, Subject version, source manifest, consent,
provider/model selection, Lead, Perspective, Critic, scoring rubric, threshold, and caps.
Changing any of those affects only a later Dream Cycle.

## 7. Cross-Profile retrieval, consent, and untrusted evidence

Every client-facing Improvements route uses the same authenticated WebUI origin and session
boundary that Hermex already trusts; no cross-origin Improvements API is permitted. Internal
Cron admission may use only an authenticated loopback or same-process adapter that is not exposed
as a second product origin. No third-party database or analytics service receives Improvements data,
including Subjects, Proposals, prompts, Memory, Session excerpts, consent records, or audit events.
Model-provider egress is the separate, explicitly granted path below.

V1 supports broad cross-Profile Session and Memory retrieval as an explicit Subject source
policy. When the owner enables that policy for a Schedule, all current Hermes Profiles are
eligible for local search across their Session and Memory indexes. This is broad retrieval,
not bulk provider submission: retrieval first searches and deduplicates locally, then ranks
handles, fetches only the most relevant bounded excerpts, redacts them, and enforces the
provider budget before egress.

Only Subject-linked and consented Profiles and Context Sources are eligible. The broad policy
is represented by separate all-Profile Session and all-Profile Memory Context Sources, and
the consent snapshot freezes the exact Profile set and source classes for that Dream Cycle.
A Profile added later requires renewed consent before it becomes eligible. A Schedule without
the explicit broad policy cannot search all Profiles by default. Every retrieved item must
trace to its selected Context Source, Profile, and stable native handle.

Only the authenticated product owner may issue or renew a Consent Grant. Before either
mutation, the server presents one complete confirmation naming the Schedule and Perspective. The
confirmation names each Lead and Critic role independently: its Profile, effective provider,
model, provider trust boundary, purpose, context/query/item/token/excerpt budgets, and whether the
role is absent, advisory, or required. It also names broad cross-Profile and external-source scope;
exact Context Sources and Profiles; redaction policy; trusted workdir and permitted toolsets; and
expiry. A shared provider is still represented once per role rather than inferred from one
singular field. The server persists that exact confirmation payload, actor, confirmation time, and
payload digest as immutable Grant evidence before any excerpt may leave the server. Authentication
to the mutation API does not itself grant provider egress.

Schedule enablement fails without a matching active Consent Grant whose immutable confirmation
covers each role's effective provider/model and trust boundary, source and Profile scope, purpose,
budgets, trusted workdir and permitted toolsets, and server-observed expiry. A scope,
provider-boundary, role, purpose, workdir, tool-permission, or budget expansion pauses the Schedule
and requires a newly confirmed Grant before enablement. A narrower configuration still creates a
new Cycle snapshot and cannot recover authority that the current Grant does not contain.

**Run Now** on a paused Schedule requires the same authenticated product owner and complete
per-role confirmation. It may use an already active matching Grant. If none exists, the server
issues a `manual_once` Grant bound to the exact Schedule version, reserved Cycle ID, role scopes,
and one native fire idempotency key. Admission consumes it atomically; it cannot authorize a
second Cycle, retry, catch-up, or recurring projection. Issuing or consuming a `manual_once` Grant
does not enable recurrence, change the paused Schedule, or create a recurring Cron job.

The current Consent Grant is a server-authoritative authorization record with active, expired,
or revoked state and a server-authoritative `expires_at`. Every Consent Grant renewal creates a
new Grant ID, even when scope and provider are unchanged, and links it through
`renewed_from_grant_id`; the predecessor remains immutable and is atomically revoked as
`superseded` if it is still active. Scope or provider changes always require such a new Grant
before use. Revocation is an append-only authority event and takes effect immediately. Expiry is
effective when server time reaches `expires_at`, even before a cleanup task persists the state;
the next authority check records the transition. Before a Cycle,
the server persists an immutable provider consent snapshot containing:

- Subject, Dream Schedule, Dream Cycle, consenting principal, and consent time;
- Lead and Critic role independently, including each Profile, provider, model, trust boundary,
  mode, and role-specific purpose and budget;
- allowed source classes, exact Context Source IDs, and allowed Profiles;
- query count plus item, token, and excerpt caps;
- redaction rules and policy version;
- retention and audit requirements; and
- the approved purpose, current Grant ID and immutable record version, and expiry observed at
  snapshot time.

Consent must be renewed when the scope or provider changes. Changing either effective provider
pauses the Schedule and requires renewed confirmation.
A model fallback may run only inside the already approved provider trust boundary; the Cycle
records the actual provider and model. A model change creates a new snapshot and cannot inherit
broader rights. The immutable snapshot is evidence, not ongoing authorization: the server
checks the current Consent Grant immediately before every retrieval and every provider
submission, and again between bounded batches. It also checks the current Subject fencing token
at each boundary. If consent expires during a Cycle, or is revoked,
the server stops further retrieval and egress, discards any not-yet-published candidates, records
the Cycle as `cancelled` with `consent_expired` or `consent_revoked`, and never uses the stale
snapshot to continue. Already-used evidence remains represented by redacted
provenance sufficient for audit. Caps are enforced before provider submission and again before
persistence.

This policy-blocked terminal result is never automatically retried.

Expiry or revocation pauses the Schedule before its next run and requires a new active Consent
Grant plus explicit enablement. It never silently reactivates recurrence.

Retrieved text is untrusted data, never an instruction, authorization, tool call, or
permission expansion. Retrieval preserves source boundaries, labels provenance, applies
redaction before model use, and prevents quoted content from changing prompts, tools,
Profiles, destinations, consent, or schedule state. Audit records the query class,
selected item IDs, excerpt sizes, redaction policy, provider/model, and result counts
without copying secrets into logs.

Historical Sessions explain intent and prior reasoning; they are not proof of current external
state. If a direct source exists—a repository file, live API, issue, Card, current document, or
website—the Dreamer must inspect it before making a current factual claim. If that source is
unavailable, the claim is visibly stale, inferred, or unverified rather than presented as current.

## 8. Decisions, handoffs, starts, and outcomes

Accept starts nothing. Accept appends a Proposal Decision only; it creates no Session,
Card, issue, branch, commit, Handoff, or worker run.

After acceptance, create-only is the quiet default. Every action first shows a complete,
editable preview: Proposal/Subject identity, evidence and privacy boundary, exact destination
effect, backlink, generated brief or first message, Profile/model/provider, any existing native
target version, and all trusted Project/workspace/tool/skill/runtime/dependency values. Generated
prose never supplies an
unchecked identifier, path, permission, or execution configuration.

- **Open Draft Session** reserves a create-intent Handoff, creates or recovers one native
  Session, persists the exact editable first-message draft, and opens it without sending.
- **Save to Triage** reserves a create-intent Handoff and creates or recovers one native
  Kanban Card in `triage`. The Dispatcher cannot run it.
- **Create & Start Session** sends the confirmed exact first message through the normal
  chat-run path after Session creation. Existing Hermes tool approvals still apply.
- **Create & Start Work** requires a valid assignee and complete specification. It creates
  or recovers the Card in `todo` with the native Kanban idempotency key, then nudges the
  existing gateway dispatcher for one pass. It must not start a second persistent dispatcher.
  When parent dependencies are incomplete, the label becomes **Create & Queue Work** and the
  Card remains blocked by dependencies until Kanban can promote it to `ready`.

If **Save to Triage** already created the destination, a later confirmed **Create & Start Work**
uses the separate start-operation key to transition the same target Card from `triage` to `todo`
before requesting dispatcher execution. It must never create a second Card. The transition uses
the same lease, fencing, invocation-marker, and uncertainty rules as every other native start
side effect. An ambiguous transition becomes `outcome_uncertain`; reconciliation must establish
the Card's authoritative Status before retry can continue.

Before that start preview is shown, the server reads the authoritative Card and binds its native
target version, Board, Status, title/body, assignee, workspace, dependencies, skills, tools, and
runtime fields into the preview hash. Confirmation authorizes an idempotent `prepare_target` step
under the Handoff lease, not a blind dispatch. That step uses native compare-and-set against the
confirmed target version, requires the Card still to be the same `triage` target, and atomically
applies the exact confirmed execution payload plus the `todo` transition. Any external edit,
Board move, Status change, or version mismatch returns `stale_preview`, performs no preparation or
start call, and requires a fresh preview and confirmation. An adapter without an authoritative
version check and compare-and-set capability must disable this upgrade rather than approximate it.
The server persists the prepared payload hash and resulting native version before dispatch.

Every start action is separate from Accept and presents one confirmation naming the destination
and start side effect. One destination-creation key identifies the Proposal, destination kind,
and destination scope. The destination-creation key is independent of create or start intent, so
**Open Draft Session** followed by **Create & Start Session** reuses the existing Handoff and
target. A separate start-operation key binds the Handoff ID and confirmed start payload hash.
Reusing either key with a changed destination or changed start payload is an explicit conflict.
Under those keys the server runs this resumable idempotent Improvements-domain saga:

1. Validate the accepted Proposal version, complete preview/version, destination, and authority.
2. **Reserve the Handoff intent** under its unique constraint. Before each native call, atomically
   compare-and-set the step from `not_attempted` to `invoking`, persist a durable invocation
   marker, and acquire its single-worker lease and fencing token. The marker commits before the
   native call.
3. **Create or recover the destination** with the Proposal backlink, subject to the destination
   capability rule below.
4. **Persist the target ID** and durable completed-step marker on the Handoff.
5. **Prepare an existing target** through the version-checked `prepare_target` step when create-only
   is upgraded to start, then persist its prepared payload hash and resulting native version.
6. **Request execution** under the separate start-operation key only when the confirmed intent is
   `start` and the destination can deduplicate the request or expose an authoritative result
   lookup.
7. Persist the observed result, append audit/sync/Outcome events, and return authority state.

A retry resumes after the last durable step and returns the existing Handoff and target.
Exactly-once creation is claimed only when the destination enforces the Handoff idempotency key
or an authoritative pre-retry lookup proves the first attempt did not take effect. For Kanban,
the domain key is also passed to native `--idempotency-key`.

Session creation has no equivalent native key. The Handoff unique constraint prevents duplicate
intents, and the invocation marker, lease, and fencing token allow only one local caller. They
cannot prove that a native call failed after invocation. A timeout, connection loss, cancellation,
ambiguous 5xx, malformed success, or crash after the invocation marker but before durable result
persistence becomes `outcome_uncertain`. A lease expiry after a native attempt has the same
result. The next worker may reconcile but must not repeat the call; it must not call
`/api/session/new` again for that Handoff. An outcome-uncertain Session must not automatically
retry.

The UI offers **Reconcile**, **Link existing Session**, **Open Sessions**, and **Abandon** for an
uncertain Session create. It does not offer Retry. If the user chooses **Create another despite
possible duplicate**, the confirmation explains the risk and creates a new linked Handoff with a
new key; it is not a retry of the uncertain call. The same no-repeat rule applies to an ambiguous
first-message send or Session start. Duplicate taps and network retries return the existing
Handoff, target, or visible outcome-uncertain state; they never trigger another native attempt.

Never delete a destination automatically because a later start step failed. A partial Handoff
stays visible as **Needs attention**. A known failed step may offer Retry, Open target, and
Abandon handoff. An `outcome_uncertain` step offers Reconcile, Open possible target, and Abandon;
Retry appears only after a known pre-invocation failure or an adapter-authoritative absence proof;
it never appears for an uncertain Session call. A known Session send failure keeps and opens the
same Session with its draft restored. A dispatcher outage preserves the `todo` Card as
**Queued; dispatcher unavailable**. Missing Profile,
Board, Project, workspace, or dependency validation fails before native creation. Undo may
delete only an untouched, never-started destination; otherwise it abandons/archives the
Handoff and preserves native state and audit.

If an assignee Profile disappears after Card creation, the Card remains with the same target ID.
The Handoff becomes **Needs attention** with reason `reassignment_required`, requests reassignment,
and cannot nudge dispatch until a valid assignee is explicitly confirmed. It never deletes,
recreates, or silently reassigns the Card.

Every Handoff audit trail records, without secrets, actor and timestamp; Proposal and Subject
IDs; the confirmed preview snapshot, version, and hash; destination kind and target ID; Handoff
intent and Handoff idempotency-key hash; creation-key hash and start-operation-key hash;
creation-payload hash and start-payload hash; selected Profile, model, provider, workspace,
Project, Board, dependencies, skills, tools, and runtime limits; target versions before and after
preparation; every invocation, preparation, lease, and fencing marker; each saga step and error
category; observed dispatcher or Session start result; and later Card or Session Outcome
references. The Proposal links to every Handoff, and every destination keeps a stable Proposal
backlink.

Proposal Delivery State is server-derived and independent from review. The server first derives
one observation per durable destination: an active Session is `Discussing`, a planning Card is
`Planned`, started work is `In Progress`, completed work is `Implemented`, and explicit human or
acceptance evidence is `Verified`. It then applies one deterministic fold across all Handoffs with
this precedence: `Verified` > `Implemented` > `In Progress` > `Planned` > `Discussing`. An
abandoned Session never hides an in-progress Card, and a completed Session never hides verified
Kanban evidence.

`Abandoned` is derived only when at least one native destination was durably created and every
created destination is abandoned, cancelled, or authoritatively stopped, with no observation in
the precedence list. `Unsent` means no native destination was ever durably created; a Handoff that
failed or was cancelled before creation does not advance delivery. An `outcome_uncertain` or
Needs-attention Handoff contributes only the strongest native state actually observed and never
guesses a higher state. Changing review state never rewrites delivery history.

## 9. Automatic learning boundary

The product owner chose automatic derived learning. The service may turn bounded Decision and Outcome
patterns into Subject-specific Learning Hypotheses and use them immediately as soft
retrieval/ranking influences. Subject Guidance is explicit authority and always outranks an
inferred hypothesis.

Feedback is ordered evidence, not a binary label. The strongest positive signal is a verified
outcome with stated benefit; strong positive is implemented/completed with no known regression;
medium positive is accepted and started; weak positive is accepted but not started or deferred
with a revisit reason. Dismissed is weak negative; rejection with a reason and abandoned or
reverted delivery are strong negative; duplicate/already-done is a novelty negative. A delivery
or provider failure, invalid output, unknown execution, or no-proposal Cycle is no preference
signal. Completion is not verification, and every raw Decision or Outcome remains auditable so
learning can be recomputed.

Learning is ranking-only and reversible. It may reorder eligible evidence, candidates, and
already-publishable Proposals. It must not affect the publication threshold, hard-gate result,
fixed score weights, or numeric score used for eligibility. It cannot expand retrieval, weaken
consent/redaction, change provider/model/Profile, activate or edit a schedule, alter tools,
skills, workdir, credentials, approval behavior, global Memory, User Profile, Agent Soul,
human decisions, safety policy, create a Handoff, or start work.

Each hypothesis records its bounded statement, confidence and influence strength, supporting
and contradicting Decision/Outcome IDs, Perspective/dimensions, timestamps, decay state, and
whether the product owner pinned, corrected, disabled, or reset it. One event creates only a weak
provisional influence. Repeated independent support raises confidence. Contradicting outcomes
lower it. Unpinned hypotheses decay after 90 days without support. An explicit correction has
highest priority and remains until changed.

Every Proposal exposes **Why this was suggested**, including the hypotheses that influenced
ranking. The Subject screen provides history, pin, correct, disable, and reset controls. Reset
removes derived influence and rebuilds it from retained audit events only after explicit
request; reset never changes source permissions, schedules, native objects, or audit history.

## 10. Retention, export, and purge

Preservation overrides compaction. A Proposal that ever entered `accepted` or `deferred`, ever
had a Handoff or Outcome, or ever had a Delivery State other than `Unsent` retains its full
original thesis, bounded Source Evidence, Proposal Updates, Decisions, Handoffs, and Outcomes
until explicit permanent Subject purge, regardless of its current review state. This historical
predicate wins if that Proposal is later rejected, dismissed, archived, or abandoned.

Only a Proposal that has never been accepted or deferred, has no Handoff or Outcome, has always
remained `Unsent`, is unpinned, and is currently rejected or dismissed may compact after 180 days.
Compaction retains its fingerprint, title, review history and reason, related-record edges, and
minimal learning evidence; it deletes its bounded excerpts and generated body.
An unreviewed Inbox Proposal is never auto-dismissed. After 14 days it becomes visibly stale and
offers review, defer, or dismiss.

`queued` and `running` Cycles are not eligible for age compaction; recovery must first reconcile
them to a terminal state. Full diagnostics for terminal `succeeded`, `no_proposal`,
`invalid_output`, `failed`, `cancelled`, `unknown`, and `skipped_overlap` Cycles remain for 90
days. After that:

- evidence and configuration linked to a published Proposal follow that Proposal's longer
  retention rule;
- unpublished candidate excerpts and transient error/provider payloads are deleted; and
- the service retains aggregate counts plus a minimum non-secret audit record containing Cycle,
  Subject, Schedule, trigger/retry identity, terminal state/reason, timestamps, Grant and native
  execution references, role/provider/model identifiers, payload digests and sizes, and the
  source-manifest digest until Subject purge.

Raw source objects, full chats, Memory documents, repositories, and provider payloads are never
copied as retention shortcuts. Bounded redacted Source Evidence attached to a published Proposal
follows Proposal retention. Evidence used only by an unpublished Cycle follows the 90-day Cycle
rule; compaction deletes its excerpt while preserving stable handles, observed time, hash,
classification, redaction-policy version, and counts in the minimum audit record.

Immutable Grant confirmation evidence—including the exact confirmed per-role scope, actor,
timestamp, expiry, payload digest, status, and renewal/revocation chain—remains until explicit
Subject purge and never derives authority after expiry or revocation. Minimum non-secret
provider-submission provenance also remains until purge: Cycle and Grant IDs, role,
provider/model, submit/result times, bounded request size, source-manifest and payload digests,
redaction-policy version, and outcome. Stored submission bodies or excerpts follow the stricter
Proposal-or-Cycle content rule above; logs must not duplicate them or retain secrets.

Native raw Cron output is not duplicated and follows native Hermes retention. Subject export,
archive, learning reset, and explicit permanent purge are distinct actions. Purge shows exactly
which external Sessions and Cards remain under native lifecycles, identifies any cross-Subject
record that cannot be removed with this Subject, and requires a destructive confirmation before
deleting Improvements-owned records.

## 11. Distribution and app identity

The distribution artifact is an Apple-credential-free, SideStore-ready IPA. Product identity is
`Hermex`; the application identifier is `no.gior.hermex`; the app-group identifier is
`group.no.gior.hermex`. The Xcode target/scheme may remain `HermesMobile` as an internal
implementation name.

No Apple signing secrets, certificates, provisioning profiles, App Store Connect keys,
team identity, account, or private deployment credentials belong in CI or the repository.
Xcode archives with signing disabled. CI may then apply only local ad-hoc signatures to app
and nested extensions so concrete entitlement intent survives for SideStore inspection; an
ad-hoc signature contains no Apple identity or credential. SideStore replaces it with the
installer's profiles and signatures. This contract never calls a zero-signature Mach-O
artifact SideStore-ready.

Issue #15 is the explicit migration blocker for inherited Apple Team, bundle, app-group, and
source-fallback identity. Until that issue removes and tests every inherited value atomically, this
repository must not produce or publish a release artifact. The known migration state does not
authorize a signing or upload path, and no new file may copy those values. Every candidate must
preserve the exact issue #14 identity quarantine or complete the canonical issue #15 migration.
Partial identity migration fails. Completion requires zero inherited Team, bundle, app-group,
URL-scheme, extension-suffix, owner-route, Keychain, or source-fallback occurrences; an empty Team
assignment; every target at `0.1.0`; and the exact canonical app, `.tests`, `.share`, `.liveactivity`,
app-group, Keychain, URL-scheme, and source-fallback values.

Before every archive, the release gate follows redirects with an unauthenticated GET to the exact
`AppConfig.privacyPolicyURL` and `AppConfig.supportURL`. Both final responses must be `2xx`, remain
on the expected fork-owned GitHub repository hosts/paths, and the privacy response must contain the
current `# Hermex Privacy Notice` heading. No archive, package, upload, or release may proceed when
either route is unavailable, requires private repository access, resolves to inherited ownership,
or lacks the expected notice. Issue #14 may introduce the in-repository notice while its `master`
URL is still `404` because the bootstrap itself cannot ship an artifact; the gate must be rerun and
pass after merge before issue #15 or any later artifact work proceeds.

The issue #14 baseline `MARKETING_VERSION = 1.5` values and the unshipped `1.5.0` Changelog
section are inherited predecessor provenance. Any local or upstream `v1.4.0` and `v1.5.0` tag
refs have the same status. Their absence from the fork remote does not authorize reusing those
names. None of these are Hermex fork versions, known-good sources, or release/rollback authority.
Issue #15 atomically sets every target to `0.1.0` with the canonical bundle, extension, app-group,
Keychain, and URL-scheme identity and records that exact migration commit as the fork identity epoch
in release provenance. A fork release workflow must verify both canonical identity and ancestry: it
rejects any source or peeled tag commit that does not descend from that epoch. It never chooses the
numerically latest repository tag across the epoch boundary.

Semantic Versioning controls `CFBundleShortVersionString`. Development versions use `0.y.z`;
the first acceptance-complete physical-iPhone release is `1.0.0`. After the identity epoch, later
SemVer changes do not require a trusted-validator modification. Every target advances together.
`CFBundleVersion` is the
monotonic protected release-workflow run number. Each release records the immutable GitHub run
ID and exact source commit in provenance. The IPA filename is
`Hermex-<version>-<build>-<short-source>.ipa`.

Release artifacts have explicit retention. PR artifacts expire after 14 days. Merged-`master`
diagnostic artifacts expire after 30 days. A tagged release IPA, checksum, provenance manifest,
source archive, and test summary are retained with its GitHub Release until the product owner
explicitly removes that release. Before installing a new build, keep the latest known-good
release locally or in private storage and verify its source reference and checksum.

Rollback is a rebuild, not a blind downgrade. Select the last known-good source tag and run the
protected rollback workflow against that source. Give the rebuilt artifact a new, higher
`CFBundleVersion`, retain the source version and rollback provenance, verify its checksum, then
re-sign and install it through SideStore and run the release smoke checklist.

## 12. Agent decision policy

The default is autonomous product decisions for reversible, repository-local work within
the selected issue and these contracts. Agents state consequential assumptions and keep
changes narrow, but do not repeatedly stop for ordinary product choices. Human input is
required only for unknowable identity, credentials, or irreversible external actions, or
when an explicit task instruction reserves a decision. Existing safety, verification,
and no-push constraints remain binding.
