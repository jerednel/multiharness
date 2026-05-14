# Contributing to Multiharness

Thanks for your interest in contributing. Multiharness is early, so small, well-scoped pull requests are easiest to review.

## Before you start

- Read `README.md` for setup and build commands.
- Read `CLAUDE.md` for architecture, protocol, persistence, and common pitfalls.
- For larger changes, open an issue first so design and scope can be discussed.

## Development setup

```bash
# Sidecar dependencies
cd sidecar && bun install && cd ..

# Optional but recommended for stable local signing
bash scripts/setup-codesign.sh
```

## Verification

Run the commands relevant to your change before opening a PR:

| Area changed | Command |
| --- | --- |
| Sidecar TypeScript | `cd sidecar && bun run typecheck && bun test` |
| Swift package / Mac app code | `swift build && swift test` |
| Full Mac app bundle | `bash scripts/build-app.sh` |
| iOS app | `bash scripts/build-ios.sh` |
| iOS files added/removed | `bash scripts/build-ios.sh` to regenerate the Xcode project |

## Pull request expectations

- Keep PRs focused. Separate sidecar protocol, persistence migrations, UI polish, and iOS work when practical.
- Include tests for behavior changes.
- Update docs when changing setup, architecture, persistence, pairing, security, provider behavior, or wire protocol.
- Never commit secrets, API keys, OAuth tokens, local app data, built app bundles, or `node_modules`.

## Coding notes

- Preserve append-only database migrations in `Sources/MultiharnessCore/Persistence/Migrations.swift`.
- Preserve sidecar signing/JIT entitlements when touching app bundling.
- Be careful with remote-access changes: LAN exposure uses bearer-token auth and currently relies on trusted networks or Tailscale for encryption.

## Reporting bugs

Please include:

- macOS/iOS version and hardware architecture.
- Build method and commit SHA.
- Relevant Console.app logs or sidecar stderr, with secrets redacted.
- Steps to reproduce and expected/actual behavior.
