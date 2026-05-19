# Changelog

## 0.2.0 - 2026-05-19

QA autopilot.

- Auto-trigger QA review when the primary agent finishes. The build system prompt now instructs the agent to emit a `<<MULTIHARNESS_QA_READY>>` token when it considers work complete; the Mac watches for it on `agent_end` and fires the configured QA review automatically. Token is stripped from the visible transcript.
- Opt-in auto-apply loop for blocking QA findings. When QA returns `blocking_issues`, the findings can be fed back to the primary as a new prompt. Bounded at 3 cycles per task; the cap surfaces a visible notice in the transcript. Configurable per-workspace and per-project.
- New "Project settings…" entry in the single-project sidebar's project picker.
- Fix: `WorktreeService.runGit` now drains stdout/stderr concurrently with `waitUntilExit`, so the Mac main thread no longer deadlocks on git output larger than the pipe buffer (~64 KB) — previously froze the app on long-lived base branches.
- Fix: `AppStore.runQA` builds the QA seed message off the main actor.

## 0.1.0 - 2026-05-14

First release of Multiharness.

Included in this release:

- Mac app that runs multiple isolated coding agents in parallel worktrees.
- Bundled sidecar server with provider abstraction and JSON-RPC-ish control API.
- iOS companion app for remote control over LAN or Tailscale.
- Persistent workspace state, event logs, and local code-signing support.
