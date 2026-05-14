import { readFile } from "node:fs/promises";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  path: Type.String({
    description: "Path relative to the worktree, or an absolute path inside the worktree.",
  }),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing why you're reading this file, e.g. 'Read agent store'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

// 200 KB — fits comfortably under any context window while still letting the
// agent read most real source files in full. A single uncapped read of a
// vendored bundle or log file could otherwise push the next request past the
// model's limit (Anthropic 1M-context: "prompt is too long: N > 1000000").
export const MAX_READ_BYTES = 200 * 1024;

export function readFileTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "read_file",
    label: "Read file",
    description: "Read the UTF-8 contents of a file inside the workspace's worktree.",
    parameters: Params,
    execute: async (_id, { path, description: _description }) => {
      const full = resolveInside(worktreePath, path);
      const content = await readFile(full, "utf8");
      const totalBytes = Buffer.byteLength(content, "utf8");
      const text =
        totalBytes > MAX_READ_BYTES
          ? Buffer.from(content, "utf8").subarray(0, MAX_READ_BYTES).toString("utf8") +
            `\n…[truncated: ${totalBytes} bytes total, first ${MAX_READ_BYTES} bytes shown]`
          : content;
      return {
        content: [{ type: "text", text }],
        // details carries the full content for the UI; only the LLM-visible
        // `content` array is capped.
        details: { path: full, content, bytes: totalBytes },
      };
    },
  };
}
