# Development

At the issue #14 bootstrap baseline, `ebreen/hermes-webui` had not been created. Issue #45 has since
created and verified the fork (`https://github.com/ebreen/hermes-webui`), and the full tested commit
in `WEBUI_FORK_TESTED_SHA` is the canonical primary server target. Current server
testing validates inherited compatibility against the upstream commit in `UPSTREAM_TESTED_SHA`.
After issue #45 creates the public fork and `WEBUI_FORK_TESTED_SHA` passes the trusted fixed-host
commit check, that exact fork commit becomes the canonical primary target over real HTTPS.
The trusted fixed-host commit check passes only when `FETCH_HEAD` equals the pinned fork commit.
See
[`PROJECT_SPEC.md`](PROJECT_SPEC.md) for the full product and API plan.

> The inherited TestFlight/App Store Connect path is retired. Distribution uses the
> Apple-credential-free SideStore flow described below.

## Primary Test Target

Use:

```text
https://<your-server>
```

Before the verified fork pin exists, point this only at an upstream-compatible server for inherited
feature testing; it cannot validate Improvements. After the pin exists, point it at that exact
Hermex WebUI fork commit through an HTTPS tunnel or reverse proxy (for example, Cloudflare Tunnel).
Real HTTPS works from both the iOS simulator and physical devices without an App Transport Security
exception. If the server sets `HERMES_WEBUI_PASSWORD`, you need that password to sign in.

Before debugging the app, verify the server is reachable:

```zsh
curl https://<your-server>/health
```

## Upstream Contract Pin

The app is currently tested against `hermes-webui` tag `v0.51.85`, peeled commit `f1d399b437c1ca7fe4b6d2093aebe334c32f34a3`. The root [`UPSTREAM_TESTED_SHA`](UPSTREAM_TESTED_SHA) file is the machine-readable pin for future drift checks and contract tests.

The pin was last verified against the upstream GitHub tag source during the 2026-05-05 audit slice; authenticated settings/version checks require server credentials.

Contract test readiness is documented in [`CONTRACT_TESTS.md`](CONTRACT_TESTS.md). Current coverage verifies the app's endpoint matrix and native POST header shape with URLProtocol-backed tests; the full Docker-backed upstream contract target remains future hardening.

## SSE and Cloudflare Stream Verification

Phase 4 streaming uses `GET /api/chat/stream?stream_id=...` over Server-Sent Events. Current upstream source confirms the stream response uses `Content-Type: text/event-stream; charset=utf-8`, `X-Accel-Buffering: no`, `Connection: keep-alive`, and sends `: heartbeat` comments every 30 seconds while no app event is ready.

Cloudflare can still close long-lived responses if the origin does not send data for long enough. The expected healthy behavior for Hermex is:

- streams longer than 2 minutes continue delivering tokens, tool events, reasoning events, title events, `done`, and `stream_end` when the server emits them;
- quiet periods under normal heartbeat behavior stay connected because the server writes `: heartbeat` about every 30 seconds;
- if the connection is cut while the upstream stream is still active, returning to the foreground or reconnecting should use `GET /api/chat/stream/status?stream_id=...` and reattach to the same stream instead of resending the user message.

Manual verification before closing Phase 4:

1. Sign in to `https://<your-server>` from the simulator.
2. Start a prompt that naturally runs for more than 2 minutes.
3. Keep the app foregrounded and verify streamed content continues past the 2 minute mark.
4. During another long response, background the app for at least 30 seconds, foreground it, and verify the app either reattaches to the active stream or reloads the completed transcript without duplicating the user message.
5. If a stream drops after a quiet gap, record whether the server emitted no tokens/tool/reasoning events for more than roughly 100 seconds. That is a known Cloudflare risk even with normal SSE support.

## Local-Only Fallback

For contributors without access to the tunnel:

This upstream checkout validates inherited-feature compatibility only. It cannot validate
fork-owned Improvements behavior or replace the canonical Hermex WebUI fork gate.

1. Clone the upstream server:

```zsh
git clone https://github.com/nesquena/hermes-webui.git
cd hermes-webui
```

2. Run it with Docker or directly with Python, following the upstream README.

For simulator-only testing, `http://localhost:8787` can work when the server is running on the same Mac. For physical-device testing, use HTTPS or a Tailscale `100.64.0.0/10` IP; Hermex includes a scoped ATS exception for that Tailscale range.

## Example Server Setup (macOS + launchd)

One proven way to run the server natively on macOS is through launchd:

- LaunchAgent: `~/Library/LaunchAgents/com.hermes.webui.plist`
- Server script: `server.py` in your `hermes-webui` checkout
- Local bind: `127.0.0.1:8787`
- Public hostname: `https://<your-server>`
- Tunnel target: `http://127.0.0.1:8787`

Useful commands for this setup:

```zsh
launchctl load ~/Library/LaunchAgents/com.hermes.webui.plist
launchctl unload ~/Library/LaunchAgents/com.hermes.webui.plist
launchctl kickstart -k gui/$(id -u)/com.hermes.webui
cloudflared tunnel info <tunnel-name>
launchctl list | grep cloudflared
curl https://<your-server>/health
```

If the server appears down, check in this order:

1. launchd job status
2. local port `8787`
3. Cloudflare Tunnel status

For local port inspection:

```zsh
lsof -i :8787
```

## Local Validation With XcodeBuildMCP

XcodeBuildMCP is the preferred local validation path for feature and bug-fix slices. The repo config lives in `.xcodebuildmcp/config.yaml` and sets:

- Project: `HermesMobile.xcodeproj`
- Scheme: `HermesMobile`
- Configuration: `Debug`
- Simulator: `iPhone 17`
- Bundle ID: read from `Config/Shared.xcconfig`; the canonical target is `no.gior.hermex`
  and issue #15 aligns the source setting atomically.

After each completed implementation slice:

1. Confirm XcodeBuildMCP sees the repo defaults.
2. Run focused tests for the changed behavior when available.
3. Run the full XCTest suite before asking for review or committing.
4. Build and launch the app in Simulator when UI or runtime behavior changed.
5. Capture a screenshot or logs if the slice needs visual/runtime evidence.
6. Let the owner run the manual simulator checklist for the slice.

Agent/MCP flow:

- Call `session_show_defaults` before the first local build/run/test.
- If defaults are missing, set project `HermesMobile.xcodeproj`, scheme `HermesMobile`,
  configuration `Debug`, simulator `iPhone 17`, and the bundle ID resolved from
  `Config/Shared.xcconfig`.
- Use `test_sim` for XCTest validation.
- Use `build_run_sim` to build, install, launch, and open Simulator for manual testing.
- Use `screenshot`, UI inspection, and log capture only when they help validate the slice.

Human/CLI equivalents:

```zsh
xcodebuildmcp simulator list --enabled
```

```zsh
xcodebuildmcp simulator test --output jsonl
```

```zsh
xcodebuildmcp simulator build-and-run --output jsonl
```

If `iPhone 17` is not installed, choose a nearby available iPhone simulator and update `.xcodebuildmcp/config.yaml` only if that should become the shared repo default.

## Swift File-Size Policy

The repo keeps the project style target of small Swift files, but file-size enforcement is warning-only while the large code-audit refactors continue.

Run:

```zsh
scripts/check-swift-file-sizes
```

Policy:

- Warn on production app Swift files over 500 LOC.
- Exit successfully even when warnings are present.
- Scope the check to `HermesMobile/` production app files.
- Exempt tests, generated files, preview files, the share extension, and the live activity widget for now.
- Use warnings to make future drift visible; do not block current work on known oversized files.

You can override the warning threshold for local experiments:

```zsh
HERMES_SWIFT_FILE_SIZE_LIMIT=300 scripts/check-swift-file-sizes
```

## Raw xcodebuild Fallback

Use raw `xcodebuild` when XcodeBuildMCP is unavailable, when validating lower-level build
failures, or when matching the Apple-credential-free GitHub Actions release/archive commands exactly.

List available simulators:

```zsh
xcrun simctl list devices available
```

Build for an available iPhone simulator:

```zsh
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 15' build
```

If `iPhone 15` is not installed, choose a nearby available iPhone simulator.

## Distribution Development Status

The inherited TestFlight/App Store Connect path is retired for this fork. Do not configure an
Apple team, certificate, provisioning profile, App Store Connect API key, device ID, or signing
secret in this repository or GitHub Actions.

The release sequence is dependency-gated:

1. Issue #15 aligns the fork-owned app, extension, app-group, URL-scheme, and public metadata
   identity. Contributors keep any personal signing team in ignored `Config/Local.xcconfig`.
2. Issue #29 builds with Apple signing disabled, applies only local ad-hoc signatures that
   preserve entitlement intent, and publishes the SideStore IPA, checksum, and provenance.
3. Issue #42 validates SideStore import, signing, install, upgrade, relaunch, extension behavior,
   refresh, and rollback on a physical iPhone.

Until issue #29 merges, this repository has no installable release artifact. Use a normally
signed local Debug build for simulator/manual Keychain testing, or use `CODE_SIGNING_ALLOWED=NO`
for compile/test-only CI. Never claim SideStore compatibility from a simulator build.

## Full-App Manual Regression Checklist

Use this before issue #42 physical SideStore validation and again before any release artifact is published.
Capture bugs, polish notes, and follow-up ideas in [GitHub Issues](https://github.com/ebreen/hermex/issues).

### Onboarding/Auth
- Fresh install opens onboarding.
- Valid server URL + password logs in.
- Wrong password shows clear error.
- Server/tunnel down shows useful error.
- Sign out and reconfigure returns to onboarding.

### Sessions
- Load sessions online.
- Pull to refresh.
- Search sessions.
- Create new session.
- Pin/unpin.
- Archive/restore.
- Move to project and back to no project.
- Duplicate/fork.
- Delete disposable session only.
- Offline cached session list displays clearly.

### Chat/Streaming
- Open existing session at latest message.
- Send normal message.
- Watch response stream.
- Stop response.
- Send while streaming using each configured behavior.
- Background/foreground during active stream.
- Long response over 2 minutes.
- Network interruption recovery.
- Offline cached transcript is read-only.

### Message Actions
- User message: edit, fork, copy.
- Assistant message: listen, stop listening, select text, regenerate, fork, copy.
- Older edit/regenerate shows discard warning.
- Local assistant command cards do not expose destructive message actions.

### Composer
- Model picker and favorites/recents.
- Reasoning picker.
- Workspace picker.
- Profile switch, including new-session confirmation.
- Attach file.
- Attach one photo.
- Attach multiple photos.
- Paste image/file.
- Failed upload preserves draft.
- Voice input allowed, denied, stopped, and sent.
- Haptics on send/response completion on device.

### Slash Commands
- `/help`
- `/new`
- `/model`
- `/workspace`
- `/reasoning`
- `/title`
- `/personality`
- `/skills`
- Direct skill slash shortcut.
- `/queue`
- `/steer`
- `/interrupt`
- `/status`
- `/btw`
- `/background` and `/bg`
- `/branch` and `/fork`
- `/undo`
- `/retry`
- `/compress` and `/compact`
- Unsupported commands show friendly local message.

### Server Panels
- Files list/search.
- Text file preview.
- Image preview.
- Unsupported binary preview.
- Tasks list/detail/output.
- Skills list/search/detail/linked file.
- Memory notes/profile.
- Usage analytics timeframe switching.

### Polish/Launch
- Light and dark mode.
- Portrait and landscape.
- Largest Dynamic Type.
- VoiceOver core path.
- App icon visible.
- Launch screen acceptable.
- Privacy permission prompts readable.
- SideStore install and refresh path documented.

Preferred Git workflow before CI automation:

1. Create one short branch per work item, such as `issue/<n>-slug`.
2. Build and test on that branch.
3. Merge to `master` only after validation passes.
4. Treat `master` as the source for checksum-verified SideStore release candidates.
