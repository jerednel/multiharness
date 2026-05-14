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

// Cap LLM-visible output. A `**/*` glob in a vendored or node_modules-heavy
// repo can return 100k+ paths and easily exceed model context windows.
export const MAX_GLOB_OUTPUT_BYTES = 100 * 1024;

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
      let text = matches.length === 0 ? "(no matches)" : matches.join("\n");
      const totalBytes = Buffer.byteLength(text, "utf8");
      if (totalBytes > MAX_GLOB_OUTPUT_BYTES) {
        text =
          Buffer.from(text, "utf8")
            .subarray(0, MAX_GLOB_OUTPUT_BYTES)
            .toString("utf8") +
          `\n…[truncated: ${matches.length} paths, ${totalBytes} bytes total, first ${MAX_GLOB_OUTPUT_BYTES} bytes shown]`;
      }
      return {
        content: [{ type: "text", text }],
        // details keeps the full match list for the UI.
        details: { pattern, matches },
      };
    },
  };
}
