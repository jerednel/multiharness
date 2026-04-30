import { writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  path: Type.String(),
  content: Type.String(),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the action, e.g. 'Add migration file'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

export function writeFileTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "write_file",
    label: "Write file",
    description: "Create or overwrite a file inside the workspace's worktree.",
    parameters: Params,
    execute: async (_id, { path, content, description: _description }) => {
      const full = resolveInside(worktreePath, path);
      await mkdir(dirname(full), { recursive: true });
      await writeFile(full, content, "utf8");
      const bytes = Buffer.byteLength(content, "utf8");
      return {
        content: [{ type: "text", text: `wrote ${bytes} bytes to ${path}` }],
        details: { path: full, bytes },
      };
    },
  };
}
