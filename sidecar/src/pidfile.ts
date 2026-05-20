import { existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { log } from "./logger.js";

export function pidFilePath(dataDir: string): string {
  return join(dataDir, "sidecar.pid");
}

export function writePidFile(dataDir: string): void {
  const path = pidFilePath(dataDir);
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, `${process.pid}\n`, { mode: 0o600 });
  } catch (err) {
    log.warn("failed to write pid file", { path, err: String(err) });
  }
}

export function removePidFile(dataDir: string): void {
  const path = pidFilePath(dataDir);
  try {
    if (existsSync(path)) unlinkSync(path);
  } catch (err) {
    log.warn("failed to remove pid file", { path, err: String(err) });
  }
}
