import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolve } from "node:path";

const Params = Type.Object({
  pattern: Type.String({
    description: "Glob pattern, e.g. 'src/**/*.ts'.",
  }),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the search, e.g. 'Find Swift sources'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

export function globTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "glob",
    label: "Glob",
    description: "Find files matching a glob pattern within the worktree.",
    parameters: Params,
    execute: async (_id, { pattern, description: _description }) => {
      const root = resolve(worktreePath);
      const glob = new Bun.Glob(pattern);
      const matches: string[] = [];
      for await (const m of glob.scan({ cwd: root, onlyFiles: true })) {
        matches.push(m);
      }
      matches.sort();
      const text = matches.length === 0 ? "(no matches)" : matches.join("\n");
      return {
        content: [{ type: "text", text }],
        details: { pattern, matches },
      };
    },
  };
}
