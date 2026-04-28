import { resolve, sep } from "node:path";

export function resolveInside(worktreePath: string, candidate: string): string {
  const root = resolve(worktreePath);
  const full = resolve(root, candidate);
  if (full !== root && !full.startsWith(root + sep)) {
    throw new Error(`path is outside worktree: ${candidate}`);
  }
  return full;
}
