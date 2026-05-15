export type BuildMode = "primary" | "shadowed";

/// Distinguishes the two kinds of agent sessions this sidecar can spin
/// up against a single workspace. `build` is the existing primary agent;
/// `qa` is the transient secondary agent that reviews the primary's
/// work. Modeled as a string enum (rather than a boolean) so a future
/// `assist` mode can slot in without redoing the prompt-construction
/// path — see `docs/superpowers/specs/2026-05-14-qa-agent-design.md` §11.
export type SessionMode = "build" | "qa";

const BASE = "You are a helpful coding agent operating inside a git worktree. Use the available tools to read and modify files.";

const SHADOWED_ADDENDUM =
  "\n\nBuilds and tests for this project are run by the user against a different checkout, not this worktree. Do not run build, test, or run commands (e.g. `swift build`, `xcodebuild`, `npm test`, `bun run dev`) — you will not get useful feedback from them. Reason carefully from the code; the user will verify.";

/// Sentinel token the primary agent emits at the end of a message when
/// it believes the requested feature is complete. The Mac watches for
/// this on `agent_end` and, when seen, automatically kicks off a QA
/// review. Kept distinctive enough that the model is unlikely to emit
/// it accidentally and uncommon enough that a normal codebase isn't
/// going to contain the literal string. Must match
/// `qaReadySentinel` on the Mac side (see
/// `Sources/MultiharnessCore/Worktree/QaFirstMessageBuilder.swift`).
export const QA_READY_SENTINEL = "<<MULTIHARNESS_QA_READY>>";

const QA_SENTINEL_ADDENDUM =
  "\n\nWhen you believe the user's requested feature is complete and ready for review, end your final message with the exact token `" +
  QA_READY_SENTINEL +
  "` on its own line. Emit it only when you consider the work done — not for partial progress, status updates, or clarifying questions. Do not emit it more than once per message. A QA reviewer will be automatically dispatched when the token appears.";

const QA_PROMPT = [
  "You are a QA reviewer. The primary coding agent just finished work on the user's task. Your job:",
  "",
  "1. Read the diff vs the base branch.",
  "2. Spot bugs, missing edge cases, broken tests, or anything the primary agent claimed but didn't actually do.",
  "3. Run tests if a test runner is obvious from the project layout.",
  "4. Call the `post_qa_findings` tool with your verdict (pass / minor_issues / blocking_issues) and a short report.",
  "",
  "You are READ-ONLY. Do not edit files. Do not commit. Do not push. Use only the inspection tools provided.",
  "",
  "Call `post_qa_findings` exactly once when your review is complete. After that, stop.",
].join("\n");

export function buildSystemPrompt(
  mode: BuildMode,
  opts?: { qaSentinelEnabled?: boolean },
): string {
  let body: string;
  switch (mode) {
    case "primary":
      body = BASE;
      break;
    case "shadowed":
      body = BASE + SHADOWED_ADDENDUM;
      break;
    default:
      throw new Error(`unknown build mode: ${String(mode)}`);
  }
  if (opts?.qaSentinelEnabled) {
    body += QA_SENTINEL_ADDENDUM;
  }
  return body;
}

/// QA reviewer system prompt. Deliberately doesn't take a `BuildMode` —
/// the reviewer never builds, tests-or-no-tests doesn't matter, and
/// keeping the QA prompt independent makes the read-only contract clear.
export function buildQaSystemPrompt(): string {
  return QA_PROMPT;
}
