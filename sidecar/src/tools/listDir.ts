import { readdir } from "node:fs/promises";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  path: Type.String({ description: "Directory path relative to the worktree." }),
});

export function listDirTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "list_dir",
    label: "List directory",
    description: "List entries (files and directories) in a directory inside the worktree.",
    parameters: Params,
    execute: async (_id, { path }) => {
      const full = resolveInside(worktreePath, path);
      const items = await readdir(full, { withFileTypes: true });
      const entries = items.map((d) => ({
        name: d.name,
        kind: d.isDirectory()
          ? "dir"
          : d.isFile()
            ? "file"
            : d.isSymbolicLink()
              ? "symlink"
              : "other",
      }));
      const text = entries.map((e) => `${e.kind === "dir" ? "d " : "  "}${e.name}`).join("\n");
      return {
        content: [{ type: "text", text: text || "(empty)" }],
        details: { path: full, entries },
      };
    },
  };
}
