import type { AgentTool } from "@mariozechner/pi-agent-core";
import { readFileTool } from "./readFile.js";
import { writeFileTool } from "./writeFile.js";
import { editFileTool } from "./editFile.js";
import { listDirTool } from "./listDir.js";
import { globTool } from "./glob.js";
import { grepTool } from "./grep.js";
import { bashTool } from "./bash.js";
import { postQaFindingsTool, type QaFindingsSink } from "./postQaFindings.js";

export function buildTools(worktreePath: string): AgentTool<any>[] {
  return [
    readFileTool(worktreePath),
    writeFileTool(worktreePath),
    editFileTool(worktreePath),
    listDirTool(worktreePath),
    globTool(worktreePath),
    grepTool(worktreePath),
    bashTool(worktreePath),
  ];
}

/// Read-only tool set used by the QA reviewer agent (see
/// docs/superpowers/specs/2026-05-14-qa-agent-design.md §6). Excludes
/// `write_file` and `edit_file`; keeps `bash` because the reviewer
/// often needs to run tests, but the QA system prompt instructs it to
/// avoid mutating commands. The terminating `post_qa_findings` tool is
/// always included — it's how the reviewer signals "I'm done."
export function buildReadOnlyTools(
  worktreePath: string,
  findingsSink: QaFindingsSink,
): AgentTool<any>[] {
  return [
    readFileTool(worktreePath),
    listDirTool(worktreePath),
    globTool(worktreePath),
    grepTool(worktreePath),
    bashTool(worktreePath),
    postQaFindingsTool(findingsSink),
  ];
}
