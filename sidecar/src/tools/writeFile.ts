import { writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  path: Type.String(),
  content: Type.String(),
});

export function writeFileTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "write_file",
    label: "Write file",
    description: "Create or overwrite a file inside the workspace's worktree.",
    parameters: Params,
    execute: async (_id, { path, content }) => {
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
