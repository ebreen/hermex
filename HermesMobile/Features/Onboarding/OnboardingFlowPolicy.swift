import Foundation

enum OnboardingFlowPolicy {
    static let pageCount = 5
    static let connectPageIndex = 4
    static let agentPromptPageIndex = 2

    static let agentSetupPrompt = """
Set up Hermes Web UI on this machine for access from my iPhone via Tailscale.

Until the canonical Hermex WebUI fork is published, use https://github.com/nesquena/hermes-webui only as an inherited-feature compatibility fallback. It is a Python server. Follow its README to install dependencies and start it on port 8787.
Enable password authentication by setting the HERMES_WEBUI_PASSWORD environment variable. Generate a secure random password, write it to a permission-restricted local file (for example ~/.hermes-webui-password with 600 permissions), and tell me the path to that file. Never print the password in your reply — I will retrieve it outside the agent transcript.
Install Tailscale on this machine. Search the web for the correct install method for this OS if you're unsure. Authenticate to my Tailscale account — if this requires opening a URL or an auth key, tell me exactly what to do.
Make the WebUI reachable over Tailscale:
- Try tailscale serve --bg 8787 first (gives HTTPS + nice hostname).
- If Tailscale Serve is disabled on my tailnet, fall back: bind the server to 0.0.0.0 instead of localhost so it listens on the tailnet interface. Before doing this, confirm password auth is active — never expose an unauthenticated WebUI.
Set up auto-start appropriate for this OS so the WebUI survives reboots.
Verify it works: when Tailscale Serve succeeded, curl the HTTPS MagicDNS URL reported by `tailscale serve status` with /health appended. When using the bind-all fallback instead, curl http://$(tailscale ip -4):8787/health.
Reply with:
- The exact server URL I enter in Hermex
- The path to the password file (not the password itself)
- Any setup steps I still need to do on my iPhone
Do not use Cloudflare. Optimize for Tailscale + iPhone.
"""

    static let tailscaleAppStoreURL = URL(string: "itms-apps://apps.apple.com/us/app/tailscale/id1470499037")!

    static let tailscaleAppStoreFallbackURL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    static func primaryButtonTitle(for page: Int) -> String {
        switch page {
        case 0:
            return String(localized: "Get Started")
        case 1:
            return String(localized: "Set Up")
        case connectPageIndex:
            return String(localized: "Connect")
        default:
            return String(localized: "Continue")
        }
    }

    static func shouldShowCopyReminder(
        page: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        page == agentPromptPageIndex && !hasCopiedAgentPrompt && !hasBypassedCopyReminder
    }

    static func shouldInterceptForwardNavigationFromAgentPrompt(
        from oldPage: Int,
        to newPage: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        oldPage == agentPromptPageIndex
            && newPage > oldPage
            && !hasCopiedAgentPrompt
            && !hasBypassedCopyReminder
    }

    static func shouldClearConnectFocusWhenLeavingPage(_ page: Int) -> Bool {
        page != connectPageIndex
    }

    static func showsServerShortcut(for page: Int) -> Bool {
        page < connectPageIndex
    }
}
