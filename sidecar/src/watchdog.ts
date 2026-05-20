import { log } from "./logger.js";

export function startParentPidWatchdog(intervalMs = 1000): void {
  const initial = process.ppid;
  setInterval(() => {
    const current = process.ppid;
    if (current === 1 || current !== initial) {
      log.warn("parent pid changed; exiting", { initial, current });
      process.exit(0);
    }
    // Belt-and-suspenders: process.ppid has been observed to stay stale in
    // compiled Bun builds (the Monday-orphan incident). Signal 0 is the
    // authoritative liveness probe — ESRCH means the parent is gone.
    try {
      process.kill(initial, 0);
    } catch (err) {
      const code = (err as { code?: string }).code;
      if (code === "ESRCH") {
        log.warn("parent process gone; exiting", { initial });
        process.exit(0);
      }
      // EPERM means the parent exists but we can't signal it — still alive.
    }
  }, intervalMs).unref();
}
