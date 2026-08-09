# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout

This repository contains multiple bounded contexts. The native iOS client, Kanban integration,
and fork-owned Improvements domain share one product but keep distinct authority and lifecycle
rules.

Use:

- required `CONTEXT.md` at the repository root for canonical domain vocabulary and project
  concepts;
- `docs/improvements-contract.md` is canonical and normative for Improvements authority,
  lifecycle, consent, scheduling, and handoff rules;
- `PROJECT_SPEC.md` is subordinate to the canonical contract and summarizes approved product
  scope; and
- `docs/adr/` for architectural decision records when present.

`CONTEXT.md` is required and must remain consistent with the Improvements contract. The
`docs/adr/` directory is optional. If an ADR exists, treat it as authority within its stated
scope and date; do not infer that a missing ADR removes the canonical contract.

## Consumer Rules

Before making architecture, diagnosis, TDD, or issue-writing decisions, read both required domain
documents. If either required document is missing, or if active guidance contradicts it, report the
drift and stop the affected domain work. Do not proceed silently.

When output names a domain concept in an issue title, refactor proposal, hypothesis, or test name, use the term as defined in `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If the concept you need is not in the glossary yet, either reconsider whether the repo already uses a different term or note the gap for a later documentation pass.

If your output contradicts an existing ADR, surface that conflict explicitly instead of silently overriding the decision.
