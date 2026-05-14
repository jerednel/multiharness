import { readdir } from "node:fs/promises";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  path: Type.String({ description: "Directory path relative to the worktree." }),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the action, e.g. 'List source directory'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

// Defensive cap. A flat directory with 100k+ entries (e.g. a build output
// tree the user pointed the agent at) shouldn't be allowed to drown the
// next LLM call.
export const MAX_LISTDIR_OUTPUT_BYTES = 50 * 1024;

export function listDirTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "list_dir",
    label: "List directory",
    description: "List entries (files and directories) in a directory inside the worktree.",
    parameters: Params,
    execute: async (_id, { path, description: _description }) => {
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
      let text = entries.map((e) => `${e.kind === "dir" ? "d " : "  "}${e.name}`).join("\n");
      const totalBytes = Buffer.byteLength(text, "utf8");
      if (totalBytes > MAX_LISTDIR_OUTPUT_BYTES) {
        text =
          Buffer.from(text, "utf8")
            .subarray(0, MAX_LISTDIR_OUTPUT_BYTES)
            .toString("utf8") +
          `\n…[truncated: ${entries.length} entries, ${totalBytes} bytes total, first ${MAX_LISTDIR_OUTPUT_BYTES} bytes shown]`;
      }
      return {
        content: [{ type: "text", text: text || "(empty)" }],
        // details preserves the full entry list for the UI.
        details: { path: full, entries },
      };
    },
  };
}
