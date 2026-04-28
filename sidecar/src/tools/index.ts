import type { AgentTool } from "@mariozechner/pi-agent-core";
import { readFileTool } from "./readFile.js";
import { writeFileTool } from "./writeFile.js";
import { editFileTool } from "./editFile.js";
import { listDirTool } from "./listDir.js";
import { globTool } from "./glob.js";
import { grepTool } from "./grep.js";
import { bashTool } from "./bash.js";

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
