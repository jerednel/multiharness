# Privacy and Security

This document explains what Multiharness stores, what it sends to model providers, and the security boundaries contributors should preserve.

## Local data

Multiharness stores application state under:

- `~/Library/Application Support/Multiharness/state.db` — projects, workspaces, provider metadata, and settings.
- `~/Library/Application Support/Multiharness/workspaces/<workspace_id>/messages.jsonl` — append-only agent event logs.
- `~/Library/Application Support/Multiharness/oauth/<provider>.json` — OAuth credential material used by the sidecar, written with restrictive file permissions.
- `~/.multiharness/workspaces/<project>/<workspace>/` — git worktrees created for agent runs.

Provider API keys and the remote-access pairing token are stored in Keychain, not plaintext app settings.

## Data sent to model providers

Agent prompts, selected context, tool results, file snippets, diffs, and conversation history may be sent to the configured model provider. The exact data depends on the provider and model selected by the user. Users should only run agents on repositories and data they are comfortable sending to that provider.

## Remote access

The iOS companion connects to the Mac sidecar with a bearer token. The project currently uses plaintext WebSocket transport and relies on trusted LANs or Tailscale/WireGuard for encryption. Do not expose the remote-access port to the public internet.

## Agent tool safety

The sidecar exposes file and shell tools scoped to a workspace. Contributors changing tool behavior should preserve path guards, avoid broadening filesystem access accidentally, and add tests for path traversal and boundary cases.

## Uninstall / cleanup

To remove local app data and generated worktrees, quit Multiharness and remove:

```bash
rm -rf "$HOME/Library/Application Support/Multiharness"
rm -rf "$HOME/.multiharness"
```

Also remove Multiharness entries from macOS Keychain if desired.
