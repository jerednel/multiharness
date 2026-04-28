import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  command: Type.String(),
  working_dir: Type.Optional(
    Type.String({ description: "Optional path inside the worktree to use as cwd." }),
  ),
  timeout_ms: Type.Optional(Type.Number({ description: "Default 120000 ms." })),
});

const DEFAULT_TIMEOUT_MS = 120_000;

export function bashTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "bash",
    label: "Run shell command",
    description:
      "Run a shell command in /bin/zsh inside the workspace's worktree. Captures stdout, stderr, and exit code.",
    parameters: Params,
    execute: async (_id, { command, working_dir, timeout_ms }) => {
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

      const summary = [
        `exit ${exitCode}${timedOut ? " (timed out)" : ""}`,
        stdout ? `stdout:\n${stdout}` : "",
        stderr ? `stderr:\n${stderr}` : "",
      ]
        .filter(Boolean)
        .join("\n");

      return {
        content: [{ type: "text", text: summary }],
        details: { exitCode, stdout, stderr, timedOut, command, cwd },
      };
    },
  };
}
