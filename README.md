<div align="center">

<img src="docs/assets/readme/hermex-icon.png" alt="Hermex app icon" width="96" />

# Hermex

**Control and improve your self-hosted Hermes agent from your iPhone.**

Your server. Your iPhone. Direct agent control.

[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](PROJECT_SPEC.md)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

[V1 execution map](https://github.com/ebreen/hermex/issues/1) · [Report a bug](https://github.com/ebreen/hermex/issues/new/choose) · [Contributing](CONTRIBUTING.md)

<img src="docs/assets/readme/hero-devices.png" alt="Hermex running on two iPhones: a streaming chat session and the home screen with Tasks, Skills, Memory, Insights, and Sessions" width="720" />

</div>

Hermex is a native SwiftUI iPhone app plus planned product-owned capabilities in the Hermex WebUI
fork tracked by [issue #45](https://github.com/ebreen/hermex/issues/45). It is a mobile cockpit and
human approval surface for an AI agent that lives on a machine **you** control. The phone is not
the compute or scheduling plane: the agent, its tools, and canonical Improvements state stay on
your own hardware.

- **Free.** No subscriptions, no in-app purchases.
- **Private by design.** No analytics or tracking SDKs. Agent API traffic goes directly to your
  configured server. Rendering a transcript can automatically fetch link-preview metadata and remote media
  from third-party URLs supplied by server or agent content. Link previews, remote media, and links you open
  can contact third-party sites and expose the device IP address.
- **Native.** Real SwiftUI, built for iOS 18+, not a web wrapper.

## Features

- **Chat with your agent** — send messages with model, reasoning-effort, workspace, and profile options; attach files and images; watch responses stream in real time with thinking and tool-call detail.
- **Steer or stop a run** mid-flight.
- **Sessions** — browse, search, and resume every conversation on your server; cached sessions stay readable offline.
- **Pick your models** — switch between any model or provider your server is configured for, with recents and favorites.
- **Profiles & projects** — switch agent profiles and organize sessions into projects.
- **Tasks** — view and edit your agent's scheduled cron jobs from your phone.
- **Skills** — browse and search the agent's installed skills.
- **Workspace browser** — explore your server's file system from the app.
- **Memory & Insights** — read-only panels for agent memory and usage analytics.
- **V1 in progress — Subjects & Proposals** — the planned bounded Dream Cycle, review, and explicit Session/Kanban handoff loop is not yet shipped on `master`; follow the execution map.

<div align="center">
<table>
  <tr>
    <td align="center"><img src="docs/assets/readme/screenshot-chat.png" alt="Streaming chat with code blocks and markdown tables" width="240" /><br /><sub><b>Stream responses in real time</b></sub></td>
    <td align="center"><img src="docs/assets/readme/screenshot-tasks.png" alt="Tasks screen listing scheduled cron jobs" width="240" /><br /><sub><b>Manage scheduled tasks</b></sub></td>
    <td align="center"><img src="docs/assets/readme/screenshot-skills.png" alt="Skills screen with searchable agent skills" width="240" /><br /><sub><b>Browse agent skills</b></sub></td>
  </tr>
</table>

The screenshots show inherited mobile capabilities. The Inbox-first Improvements UI is tracked in the [V1 execution map](https://github.com/ebreen/hermex/issues/1).
</div>

## Getting started

Hermex will require the self-hosted Hermex WebUI fork, inherited from the MIT-licensed [upstream
WebUI](https://github.com/nesquena/hermes-webui). At the issue #14 bootstrap baseline, the intended
`ebreen/hermes-webui` repository had not been created; [issue
#45](https://github.com/ebreen/hermex/issues/45) establishes and verifies its clean baseline before
server feature work. These setup steps apply only after that baseline exists:

1. **Run the fork.** Install and start the version pinned by `WEBUI_FORK_TESTED_SHA` on macOS, Linux, or Windows/WSL2. Set `HERMES_WEBUI_PASSWORD`.
2. **Make it reachable from your phone** (see options below).
3. **Connect.** Build Hermex from source today. Issue #29 adds the Apple-credential-free, ad-hoc entitlement-seeded SideStore IPA; issue #42 validates physical installation. Enter your server URL and password in onboarding.

Self-hosting the server, securing it, and keeping it reachable are your responsibility.

### Making the server reachable

- **HTTPS via a tunnel or reverse proxy (recommended).** Expose the server through Cloudflare Tunnel or any reverse proxy that terminates real TLS at a hostname you own. Real HTTPS keeps iOS App Transport Security happy with no exceptions. On a publicly reachable hostname the password is your only app-level defense — set a strong one.
- **Tailscale.** Run the server bound to all interfaces with a password, install Tailscale on both the server and the iPhone, and connect to `http://<tailnet-ip>:8787`. The app allows plain HTTP only for Tailscale's `100.64.0.0/10` device range.
- **Simulator-only local testing** can use `http://localhost:8787` when the server runs on the same Mac.

### Troubleshooting the connection

If connection testing fails, check these first:

1. The machine hosting `hermes-webui` is awake.
2. `hermes-webui` is running and serving `/health` (`curl https://<your-server>/health`).
3. The tunnel, reverse proxy, or Tailscale route is connected.
4. The server URL and password are correct.

## Building from source

You need Xcode 26 or newer (iOS 18 SDK) and an iPhone or simulator on iOS 18+. The fork does not use App Store or TestFlight distribution. CI will produce an Apple-credential-free SideStore artifact in issue #29.

Clone the repo, open `HermesMobile.xcodeproj`, and run the `HermesMobile` scheme on an iPhone simulator (the Xcode target is `HermesMobile`; the app's display name is `Hermex`). Dependencies are resolved automatically via Swift Package Manager.

From the command line:

```zsh
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```zsh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
```

If that simulator is not installed, list available devices and choose a nearby iPhone simulator:

```zsh
xcrun simctl list devices available
```

Local validation defaults for XcodeBuildMCP users live in `.xcodebuildmcp/config.yaml`; the standard post-change flow is in [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Server compatibility

Fork-owned behavior is developed and tested against the canonical commit in `WEBUI_FORK_TESTED_SHA`; issue #45 creates that pin before server implementation. [`UPSTREAM_TESTED_SHA`](UPSTREAM_TESTED_SHA) remains an inherited-compatibility pin only. Include both app and server commit IDs in bug reports. The app decodes additive fields tolerantly, while endpoint shapes are verified against the authenticated running fork and its version-matched source; see [`CONTRACT_TESTS.md`](CONTRACT_TESTS.md).

## Documentation map

- [`docs/improvements-contract.md`](docs/improvements-contract.md): canonical and normative for the Improvements bounded context.
- [`CONTEXT.md`](CONTEXT.md): canonical product vocabulary and matching Improvements glossary.
- [`PROJECT_SPEC.md`](PROJECT_SPEC.md): broader product scope, inherited API behavior, dependencies, and architecture outside Improvements; subordinate to the Improvements contract within that bounded context.
- [`PROJECT_INTENT.md`](PROJECT_INTENT.md): short orientation; useful for product tradeoffs, not implementation details.
- [`DEVELOPMENT.md`](DEVELOPMENT.md): local development, isolated server tests, and validation workflow.
- [`TESTFLIGHT.md`](TESTFLIGHT.md): tombstone for the retired inherited TestFlight path.
- [`CONTRACT_TESTS.md`](CONTRACT_TESTS.md): fork-owned contract-test readiness, the trusted-validator bootstrap, and the pin-advance policy.
- [`PRIVACY.md`](PRIVACY.md): app, configured-server, provider-consent, and third-party request boundaries.
- [`SECURITY.md`](SECURITY.md): how to report a vulnerability.
- [`docs/agents/`](docs/agents): repo-local agent workflow conventions (issues, triage labels, domain notes).
- [GitHub Issues](https://github.com/ebreen/hermex/issues): source of truth for active work and decisions.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to pick up work and open a PR, [`AGENTS.md`](AGENTS.md) for the working agreement coding agents follow in this repo, and the [Code of Conduct](CODE_OF_CONDUCT.md). The short version:

- Do not invent API endpoints or JSON shapes; verify against the authenticated running fork and version-matched fork source.
- Every `Codable` model decodes tolerantly — never crash on unknown fields.
- Add no third-party dependencies beyond the locked list in `PROJECT_SPEC.md` without explicit approval.
- Implement fork-owned server behavior only in `ebreen/hermes-webui`; treat upstream as a read-only compatibility/sync input.

## Project status

V1 is being delivered through dependency-linked issues from the [canonical map](https://github.com/ebreen/hermex/issues/1). `master` is the integration baseline; unfinished behavior is not advertised as shipped. Until issues #29 and #42 pass, the repository has no installable release artifact.

## License

MIT — see [LICENSE](LICENSE).

Hermex is an independent fork built on the upstream [hermes-webui](https://github.com/nesquena/hermes-webui) project and is not affiliated with its maintainers. Apple and SideStore are not affiliated with this project.
