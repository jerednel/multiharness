import { readFile, stat } from "node:fs/promises";
import { Type } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";
import { resolveInside } from "../pathGuard.js";
import { resolve, relative } from "node:path";

const Params = Type.Object({
  pattern: Type.String({ description: "JavaScript-flavored regular expression." }),
  path: Type.Optional(
    Type.String({
      description: "Optional file or directory inside the worktree to search; defaults to the worktree root.",
    }),
  ),
  glob: Type.Optional(
    Type.String({ description: "Optional glob filter (e.g. '**/*.ts')." }),
  ),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the search, e.g. 'Search for handleEvent'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_TOTAL_MATCHES = 1000;

export function grepTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "grep",
    label: "Grep",
    description: "Search for a regular expression across files in the worktree.",
    parameters: Params,
    execute: async (_id, { pattern, path, glob, description: _description }) => {
      const root = resolve(worktreePath);
      const re = new RegExp(pattern);
      const matches: { path: string; line: number; text: string }[] = [];
      const startRel = path ?? ".";
      const start = resolveInside(root, startRel);

      const files = await collectFiles(start, root, glob);
      outer: for (const file of files) {
        try {
          const s = await stat(file);
          if (!s.isFile() || s.size > MAX_FILE_BYTES) continue;
          const text = await readFile(file, "utf8");
          const lines = text.split("\n");
          for (let i = 0; i < lines.length; i++) {
            const line = lines[i] ?? "";
            if (re.test(line)) {
              matches.push({ path: relative(root, file), line: i + 1, text: line });
              if (matches.length >= MAX_TOTAL_MATCHES) break outer;
            }
          }
        } catch {
          // unreadable / binary; skip
        }
      }

      const summary =
        matches.length === 0
          ? "(no matches)"
          : matches.map((m) => `${m.path}:${m.line}: ${m.text}`).join("\n");
      return {
        content: [{ type: "text", text: summary }],
        details: { pattern, matches },
      };
    },
  };
}

async function collectFiles(start: string, root: string, glob?: string): Promise<string[]> {
  const out: string[] = [];
  let s;
  try {
    s = await stat(start);
  } catch {
    return out;
  }
  if (s.isFile()) {
    out.push(start);
    return out;
  }
  // directory walk
  const g = glob ? new Bun.Glob(glob) : new Bun.Glob("**/*");
  for await (const m of g.scan({ cwd: start, onlyFiles: true })) {
    out.push(resolve(start, m));
  }
  // when start is the worktree root, paths in `out` are absolute under root — fine.
  void root;
  return out;
}
