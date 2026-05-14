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
  output_mode: Type.Optional(
    Type.Union(
      [
        Type.Literal("files_with_matches"),
        Type.Literal("content"),
        Type.Literal("count"),
      ],
      {
        description:
          "How to format results. `files_with_matches` (default) lists one path per matched file — compact, ideal for an initial scan. `content` shows each matching line with `path:line: text` (use only after narrowing). `count` shows `path: N` per matched file.",
      },
    ),
  ),
  head_limit: Type.Optional(
    Type.Number({
      description:
        "Cap on output rows. In files_with_matches/count mode this caps the number of paths; in content mode it caps the number of match lines. Defaults to a generous internal limit.",
    }),
  ),
  description: Type.Optional(
    Type.String({
      description:
        "Short imperative phrase describing the search, e.g. 'Search for handleEvent'. Shown to the user as the step label. 5–8 words.",
    }),
  ),
});

const MAX_FILE_BYTES = 5 * 1024 * 1024;
// Default cap when the caller doesn't pass `head_limit`. Different per
// mode so the compact modes can return many more rows before truncating.
const DEFAULT_HEAD_LIMIT_PATHS = 500;
const DEFAULT_HEAD_LIMIT_CONTENT = 200;
// Per-match line cap. A single match against minified JS / bundled assets
// can be hundreds of KB on its own; 1 KB is enough to convey what was
// matched without flooding the LLM with line noise.
export const MAX_MATCH_LINE_BYTES = 1024;
// Safety-net byte cap on the rendered summary, in case head_limit was set
// very high. Should almost never fire in files_with_matches/count modes.
export const MAX_GREP_OUTPUT_BYTES = 100 * 1024;

function capLine(s: string): string {
  if (Buffer.byteLength(s, "utf8") <= MAX_MATCH_LINE_BYTES) return s;
  return (
    Buffer.from(s, "utf8").subarray(0, MAX_MATCH_LINE_BYTES).toString("utf8") +
    "…[match line truncated]"
  );
}

function capBytes(s: string, suffixHint: string): string {
  const bytes = Buffer.byteLength(s, "utf8");
  if (bytes <= MAX_GREP_OUTPUT_BYTES) return s;
  return (
    Buffer.from(s, "utf8").subarray(0, MAX_GREP_OUTPUT_BYTES).toString("utf8") +
    `\n…[truncated: ${suffixHint}, ${bytes} bytes total, first ${MAX_GREP_OUTPUT_BYTES} bytes shown — narrow the pattern, path, or glob]`
  );
}

export function grepTool(worktreePath: string): AgentTool<typeof Params> {
  return {
    name: "grep",
    label: "Grep",
    description:
      "Search for a regular expression across files in the worktree. " +
      "Default output is just the matching file paths (compact, like ripgrep -l). " +
      "Use `output_mode: \"content\"` after you've narrowed the search to a small set of files; " +
      "use `output_mode: \"count\"` to see per-file match totals.",
    parameters: Params,
    execute: async (
      _id,
      { pattern, path, glob, output_mode, head_limit, description: _description },
    ) => {
      const mode = output_mode ?? "files_with_matches";
      const root = resolve(worktreePath);
      const re = new RegExp(pattern);
      const startRel = path ?? ".";
      const start = resolveInside(root, startRel);

      const headLimit =
        head_limit ?? (mode === "content" ? DEFAULT_HEAD_LIMIT_CONTENT : DEFAULT_HEAD_LIMIT_PATHS);

      // Walk every file; collect either per-file hit counts or per-line
      // matches depending on mode. We collect into `details` in full and
      // build the LLM-visible summary at the end so head_limit only
      // affects the LLM view, not the UI's tool-call detail panel.
      const files = await collectFiles(start, root, glob);
      const allMatches: { path: string; line: number; text: string }[] = [];
      const perFileCount = new Map<string, number>();

      for (const file of files) {
        try {
          const s = await stat(file);
          if (!s.isFile() || s.size > MAX_FILE_BYTES) continue;
          const text = await readFile(file, "utf8");
          const lines = text.split("\n");
          const rel = relative(root, file);
          let fileHits = 0;
          for (let i = 0; i < lines.length; i++) {
            const line = lines[i] ?? "";
            if (re.test(line)) {
              fileHits++;
              // Always record matches in details; the LLM-visible content
              // is shaped separately below.
              allMatches.push({ path: rel, line: i + 1, text: line });
            }
          }
          if (fileHits > 0) perFileCount.set(rel, fileHits);
        } catch {
          // unreadable / binary; skip
        }
      }

      const totalMatches = allMatches.length;
      const matchedFiles = [...perFileCount.keys()].sort();

      let summary: string;
      if (totalMatches === 0) {
        summary = "(no matches)";
      } else if (mode === "files_with_matches") {
        const shown = matchedFiles.slice(0, headLimit);
        summary = shown.join("\n");
        if (matchedFiles.length > headLimit) {
          summary += `\n…[${matchedFiles.length - headLimit} more files omitted; raise head_limit or narrow the search]`;
        }
      } else if (mode === "count") {
        const shown = matchedFiles.slice(0, headLimit);
        summary = shown.map((p) => `${p}: ${perFileCount.get(p)}`).join("\n");
        if (matchedFiles.length > headLimit) {
          summary += `\n…[${matchedFiles.length - headLimit} more files omitted; raise head_limit or narrow the search]`;
        }
      } else {
        // content mode
        const shown = allMatches.slice(0, headLimit);
        summary = shown
          .map((m) => `${m.path}:${m.line}: ${capLine(m.text)}`)
          .join("\n");
        if (allMatches.length > headLimit) {
          summary += `\n…[${allMatches.length - headLimit} more matches omitted; raise head_limit or narrow the search]`;
        }
      }

      summary = capBytes(
        summary,
        `${matchedFiles.length} files, ${totalMatches} matches`,
      );

      return {
        content: [{ type: "text", text: summary }],
        // details preserves the unredacted per-match data for the UI.
        details: {
          pattern,
          mode,
          totalFiles: matchedFiles.length,
          totalMatches,
          matches: allMatches,
        },
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
