import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  command: Type.String(),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the action, e.g. 'Show working tree status' or 'Run unit tests'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
  working_dir: Type.Optional(
    Type.String({ description: "Optional path inside the worktree to use as cwd." }),
  ),
  timeout_ms: Type.Optional(Type.Number({ description: "Default 120000 ms." })),
});

const DEFAULT_TIMEOUT_MS = 120_000;

// 100 KB each for stdout and stderr. A single `cat huge.log` or `find /`
// could otherwise return megabytes and push the next LLM request past the
// model's context window.
export const MAX_STREAM_BYTES = 100 * 1024;

function capStream(s: string): string {
  const bytes = Buffer.byteLength(s, "utf8");
  if (bytes <= MAX_STREAM_BYTES) return s;
  return (
    Buffer.from(s, "utf8").subarray(0, MAX_STREAM_BYTES).toString("utf8") +
    `\n…[truncated: ${bytes} bytes total, first ${MAX_STREAM_BYTES} bytes shown]`
  );
}

export function bashTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "bash",
    label: "Run shell command",
    description:
      "Run a shell command in /bin/zsh inside the workspace's worktree. Captures stdout, stderr, and exit code.",
    parameters: Params,
    execute: async (_id, { command, working_dir, timeout_ms, description: _description }) => {
      const cwd = working_dir ? resolveInside(worktreePath, working_dir) : worktreePath;
      const proc = Bun.spawn(["/bin/zsh", "-c", command], {
        cwd,
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env },
      });

      const timeout = timeout_ms ?? DEFAULT_TIMEOUT_MS;
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        proc.kill();
      }, timeout);

      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      clearTimeout(timer);

      const stdoutCapped = capStream(stdout);
      const stderrCapped = capStream(stderr);

      const summary = [
        `exit ${exitCode}${timedOut ? " (timed out)" : ""}`,
        stdoutCapped ? `stdout:\n${stdoutCapped}` : "",
        stderrCapped ? `stderr:\n${stderrCapped}` : "",
      ]
        .filter(Boolean)
        .join("\n");

      return {
        content: [{ type: "text", text: summary }],
        // details keeps the full streams for the UI; only the LLM-visible
        // `content` summary is capped.
        details: { exitCode, stdout, stderr, timedOut, command, cwd },
      };
    },
  };
}
