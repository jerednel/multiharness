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

export function readFileTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "read_file",
    label: "Read file",
    description: "Read the UTF-8 contents of a file inside the workspace's worktree.",
    parameters: Params,
    execute: async (_id, { path, description: _description }) => {
      const full = resolveInside(worktreePath, path);
      const content = await readFile(full, "utf8");
      return {
        content: [{ type: "text", text: content }],
        details: { path: full, content, bytes: Buffer.byteLength(content, "utf8") },
      };
    },
  };
}
