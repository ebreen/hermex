# Security Policy

## Reporting a vulnerability

Do **not** report a vulnerability through a public issue. Private vulnerability reporting is
not currently enabled for this fork. Send the report to **ebreen@proton.me** with the subject
`Hermex security report`.

Include, when available:

- a clear description and impact;
- reproduction steps or a proof of concept;
- the Hermex app commit and iOS version;
- the canonical WebUI fork commit from `WEBUI_FORK_TESTED_SHA`;
- whether the behavior also exists unchanged in upstream `nesquena/hermes-webui`.

Expect an initial response within seven days. Allow a reasonable remediation window before
public disclosure.

## Scope

Hermex spans the native iOS app, the canonical `ebreen/hermes-webui` server fork, their wire
contract, and the Apple-credential-free SideStore release pipeline. Credential storage, authentication,
untrusted server/model content, consent boundaries, source retrieval, scheduling, handoffs,
artifact integrity, and fork-owned server behavior are in scope.

If a vulnerability is inherited unchanged from upstream, report it here first so the fork can
assess exposure and coordinate with the upstream project without exposing private details.
