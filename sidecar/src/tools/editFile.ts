import { readFile, writeFile } from "node:fs/promises";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";

const Params = Type.Object({
  path: Type.String(),
  old_string: Type.String(),
  new_string: Type.String(),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the change, e.g. 'Fix off-by-one in pager'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

export function editFileTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "edit_file",
    label: "Edit file",
    description:
      "Replace exactly one occurrence of old_string with new_string in the file. Fails if old_string is missing or appears more than once.",
    parameters: Params,
    execute: async (_id, { path, old_string, new_string, description: _description }) => {
      const full = resolveInside(worktreePath, path);
      const original = await readFile(full, "utf8");
      const idx = original.indexOf(old_string);
      if (idx === -1) throw new Error(`old_string not found in ${path}`);
      const second = original.indexOf(old_string, idx + old_string.length);
      if (second !== -1) throw new Error(`old_string appears multiple times in ${path}`);
      const updated =
        original.slice(0, idx) + new_string + original.slice(idx + old_string.length);
      await writeFile(full, updated, "utf8");
      return {
        content: [{ type: "text", text: `replaced 1 occurrence in ${path}` }],
        details: { path: full, replaced: 1 },
      };
    },
  };
}
