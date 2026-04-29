export type BuildMode = "primary" | "shadowed";

const BASE = "You are a helpful coding agent operating inside a git worktree. Use the available tools to read and modify files.";

const SHADOWED_ADDENDUM =
  "\n\nBuilds and tests for this project are run by the user against a different checkout, not this worktree. Do not run build, test, or run commands (e.g. `swift build`, `xcodebuild`, `npm test`, `bun run dev`) — you will not get useful feedback from them. Reason carefully from the code; the user will verify.";

export function buildSystemPrompt(mode: BuildMode): string {
  switch (mode) {
    case "primary":
      return BASE;
    case "shadowed":
      return BASE + SHADOWED_ADDENDUM;
    default:
      throw new Error(`unknown build mode: ${String(mode)}`);
  }
}
