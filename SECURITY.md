# Security Policy

Multiharness controls local git worktrees, invokes AI coding agents with file and shell tools, stores provider credentials, and can expose a control WebSocket to an iOS companion over the local network. Please treat security reports seriously and avoid public disclosure before maintainers can investigate.

## Supported versions

Security fixes target the current `main` branch until formal releases exist.

## Reporting a vulnerability

If you find a vulnerability:

1. Do **not** open a public issue with exploit details.
2. Contact the maintainers privately. If no private contact has been configured for this repository yet, open a public issue asking for a security contact and include no sensitive details.
3. Include affected commit/version, reproduction steps, impact, and any logs with secrets redacted.

## Areas of special concern

- Provider API keys and OAuth refresh/access tokens.
- macOS and iOS Keychain storage and access control.
- Remote access bearer-token handling and pairing URLs.
- Plaintext WebSocket use on LAN/Tailscale.
- Agent shell/file tools and path isolation.
- Worktree creation, branch operations, merge/reconcile behavior.
- App signing, hardened runtime, and bundled sidecar entitlements.

## Current remote-access threat model

Remote access is intended for trusted local networks or encrypted overlays such as Tailscale. The sidecar supports bearer-token authentication but does not currently provide TLS itself. Do not expose the remote-access port directly to the public internet.
