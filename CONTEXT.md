# Hermex Domain

Canonical language for Hermex concepts that need consistent names across the product, planning, and support.
The normative Improvements rules live in `docs/improvements-contract.md`.

## Kanban

**Kanban**:
The Hermex destination for organizing and operating server-backed work across workflow states.
_Avoid_: Boards, Tasks

**Board**:
A named container of Kanban work and its workflow states.
_Avoid_: Kanban, project

**Card**:
An individual unit of work on a Board.
_Avoid_: Task, Kanban task, work item

**Status**:
The workflow state of a Card: Triage, To Do, Ready, Running, Blocked, Done, or Archived.
_Avoid_: Column, lane, stage

**Column**:
A visual grouping of Cards that share a Status.
_Avoid_: Status, lane

**Lane**:
An optional visual grouping of Cards by Profile, including an Unassigned lane.
_Avoid_: Status, column

**Profile**:
A Hermes agent configuration that can perform Card work.
_Avoid_: Assignee, user, agent

**Assignment**:
The relationship between a Card and the Profile selected to perform it. A Card without that relationship is Unassigned.
_Avoid_: Ownership

**Prerequisite**:
A Card that must precede another Card in a dependency relationship.
_Avoid_: Parent, blocker

**Dependent**:
A Card that relies on a Prerequisite.
_Avoid_: Child, blocked card

**Dispatcher**:
The server operation that claims eligible Ready Cards and may launch worker processes.
_Avoid_: Runner, launcher

**Preview Dispatch**:
A dry run that reports expected Dispatcher outcomes without launching workers.
_Avoid_: Test run, simulate dispatcher

**Run Dispatcher**:
The action that invokes the Dispatcher and may launch workers or consume API budget.
_Avoid_: Dispatch, run

**Dispatch Run**:
The recorded execution of the Dispatcher.
_Avoid_: Run, dispatcher result

**Archived**:
The Status of a Card removed from the active workflow.
_Avoid_: Deleted

**Archive Card**:
The action that changes a Card's Status to Archived.
_Avoid_: Delete Card, remove Card

**Archive Board**:
The action that removes a non-default Board from active use. Hermex cannot restore an archived Board in-app.
_Avoid_: Delete Board, remove Board

**Bulk Action**:
A named operation applied to multiple selected Cards.
_Avoid_: Bulk update, batch operation

**Select Cards**:
The mode for choosing Cards before applying a Bulk Action.
_Avoid_: Multi-select, bulk mode

## Improvements

**Improvement Subject** (UI: **Subject**):
A configurable thing that the Dreamer studies for worthwhile Proposals. A Subject can reference Projects, repositories, workspaces, Boards, services, stores, and other Context Sources, but it is not an alias for any of them.
_Avoid_: Feature, Project, workspace, repository, Board, target

**Subject State**:
The availability of a Subject for Dream Cycles: Active, Paused, or Archived.
_Avoid_: Status, enabled

**Context Source**:
A bounded, consented source of evidence associated with a Subject, such as a Hermex Project, repository, workspace, Board, service, store, Memory section, or selected Session history.
_Avoid_: Subject, project context

**Dreamer**:
The role performed by the Lead Hermes Profile selected to generate Proposals for a Subject. Profile names the reusable agent configuration; Dreamer names its role in Improvements.
_Avoid_: agent, Profile, worker

**Dream Schedule**:
A paused-by-default plan for when a Dreamer examines one Subject and which Context Sources apply.
_Avoid_: Cron, task, automation

**Dream Cycle**:
One immutable attempt by a Dreamer to examine one Subject, started by an active Dream Schedule or a manual request.
_Avoid_: run, Session, job

**Dream Cycle Result**:
The outcome of a Dream Cycle: zero or more Proposals, including the valid No Proposal result.
_Avoid_: response, output

**No Proposal**:
A successful Dream Cycle Result that states no worthwhile Proposal met the quality threshold. It is not an error.
_Avoid_: empty result, failure

**Proposal**:
A reviewable suggestion produced by one Dream Cycle for one Subject. A Proposal keeps its origin, human Decisions, Handoffs, and Outcome distinct from the Session or Card that may later carry the work.
_Avoid_: Card, issue, idea, task, recommendation, Feature entity

**Feature**:
An ordinary descriptor for a Proposal that adds a capability the Subject does not currently have. `Feature` is not a persisted domain entity and never receives its own ID or lifecycle.
_Avoid_: entity, bounded-context name

**Improvement**:
An ordinary descriptor for a Proposal that changes an existing capability, workflow, quality attribute, reliability property, or maintenance condition. Improvements, plural, names the bounded context.
_Avoid_: Feature entity, fix

**Proposal Review State**:
The human decision state of a Proposal: New, Reviewing, Accepted, Deferred, Rejected, or Dismissed.
_Avoid_: Status, Column, delivery state

**Dismiss Proposal**:
Hide a low-interest or currently irrelevant Proposal without recording a strong negative product decision. Dismissal is reversible.
_Avoid_: Reject Proposal, delete

**Reject Proposal**:
Record a deliberate decision not to pursue a Proposal.
_Avoid_: Dismiss Proposal, delete

**Defer Proposal**:
Record that a Proposal remains plausible but should return for review later.
_Avoid_: Dismiss Proposal, Reject Proposal

**Accept Proposal**:
Record that a Proposal is worthwhile to pursue. Acceptance starts nothing and does not create a Session, Card, issue, commit, Handoff, or pull request.
_Avoid_: approve execution, start work

**Proposal Delivery State**:
The server-derived progress projection of an Accepted Proposal from its Handoffs and Outcome: Unsent, Discussing, Planned, In Progress, Implemented, Verified, or Abandoned. It is independent from Proposal Review State.
_Avoid_: Status, review state

**Handoff**:
A human-confirmed connection from an Accepted Proposal to a native destination where discussion or execution continues. A Proposal can have both a Session Handoff and a Kanban Handoff.
_Avoid_: promotion, automatic dispatch, execution

**Session Handoff**:
A Handoff that creates or links a Session for discussing, refining, or implementing a Proposal.
_Avoid_: Send chat, start agent

**Kanban Handoff**:
A Handoff that creates or links a Card for planning and executing a Proposal on a selected Board.
_Avoid_: Promote Card, dispatch

**Create & Start**:
A separately confirmed Handoff that reuses one destination-creation key, then uses a separate start-operation key. A destination without native idempotency stops at an outcome-uncertain result after an ambiguous call and does not retry automatically.
_Avoid_: Accept Proposal, automatic execution

**Outcome**:
The observed result of pursuing or abandoning a Proposal, including whether the expected value was verified.
_Avoid_: response, Proposal Decision, delivery state

**Dream Perspective**:
The bounded angle a Lead Dreamer applies during one Dream Schedule, such as Product, Reliability, Simplification, or Security/Privacy.
_Avoid_: Profile, role, prompt

**Critic**:
An optional independent Profile role that challenges, scores, or tightens candidate Proposals before they enter the inbox.
_Avoid_: approver, Dreamer

**Source Evidence**:
A classified reference that supports or qualifies a Proposal claim and records what source was observed and when.
_Avoid_: context, citation text, proof

**Proposal Score**:
A transparent quality estimate from 0 through 100 derived from evidence, impact, novelty, specificity, feasibility, and Subject fit.
_Avoid_: confidence, priority, truth

**Proposal Update**:
Append-only evidence or reasoning linked to an existing Proposal instead of creating a duplicate Proposal.
_Avoid_: edit, revision, duplicate Proposal

**Proposal Decision**:
An append-only human transition of Proposal Review State with actor, reason, time, and observed Proposal version.
_Avoid_: edit, Outcome, delivery state

**Subject Guidance**:
An explicit, human-written or human-corrected preference that guides future Dream Cycles for one Subject.
_Avoid_: global memory, instruction, Learning Hypothesis

**Learning Hypothesis**:
A reversible, evidence-linked preference inferred from Proposal Decisions and Outcomes for one Subject. It can affect ranking only.
_Avoid_: fact, Subject Guidance, global memory

**Audit Event**:
An immutable, ordered accountability fact covering consent, retrieval, Decisions, Handoffs, Outcomes, and side effects.
_Avoid_: mutable log entry, Sync Event

**Sync Event**:
An immutable, cursor-ordered change fact used to converge replaceable client projections with server state.
_Avoid_: notification, Audit Event
