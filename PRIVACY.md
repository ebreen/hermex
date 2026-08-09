# Hermex Privacy Notice

Effective: 8 August 2026

Hermex is a native client for a user-operated Hermes deployment. This notice covers the
Hermex iPhone app and the fork-owned Improvements capability. It does not replace the
privacy policy of a user-configured Hermes server, network operator, model provider, or
website that the user chooses to contact.

## Data sent to the configured server

Hermex sends requests directly to the user-configured Hermes server. Depending on the
feature used, those requests can contain authentication material, custom request headers,
messages, prompts, attachments, voice or image content, selected Profile/model/workspace
settings, and commands that the user confirms. The server and its configured model
providers control their own processing and retention.

The app stores connection credentials and configured custom headers in the iOS Keychain.
It can cache server-provided Sessions and messages on the device for offline reading.
Users can clear the offline cache in Settings. Removing local data does not delete records
from the configured server or from a model provider.

## Third-party content requests

Rendering server or agent content can cause automatic link-preview metadata requests and
remote media requests from the iPhone. Those requests go to the third-party host named in
the content, not only to the configured server. The host and its network providers can
observe the device IP address and request metadata. Opening a link can disclose additional
information under the destination site's own policy.

## Improvements data

The fork-owned Improvements API uses the same authenticated WebUI origin as the rest of
Hermex. The Improvements domain does not send Subjects, Proposals, prompts, Memory, or
Session excerpts to a third-party database or analytics service. When the product owner
explicitly grants provider consent, the server can send the confirmed bounded excerpts to
the independently named Lead or Critic model provider. The confirmation and current Grant
control that egress.

## Analytics and support

The Hermex app does not include a third-party analytics SDK. A configured server or model
provider can have its own diagnostics, logs, or usage accounting; inspect that deployment
before sending sensitive data.

Support uses the fork's GitHub issue tracker. GitHub Issues are public and are processed by
GitHub under its own terms and privacy statement. Do not include credentials, authorization
headers, private server URLs, prompts, transcripts, or Memory excerpts in an issue. Report
security vulnerabilities through [SECURITY.md](SECURITY.md) instead of a public issue.

## Control and deletion

Users choose the configured server, model provider, Context Sources, and consent scope.
They can clear local offline data and sign out in the app. The product owner can revoke an
Improvements Consent Grant and can use the separate archive, export, learning-reset, and
permanent Subject-purge controls defined by the Improvements contract. External Sessions,
Cards, server logs, provider records, GitHub issues, and third-party web requests follow
their own systems' retention rules.

## Contact

Use the fork-owned [issue tracker](https://github.com/ebreen/hermex/issues) for non-sensitive
questions. Use the private process in [SECURITY.md](SECURITY.md) for a
vulnerability.
