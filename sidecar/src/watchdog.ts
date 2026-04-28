import { log } from "./logger.js";

export function startParentPidWatchdog(intervalMs = 1000): void {
  const initial = process.ppid;
  setInterval(() => {
    const current = process.ppid;
    if (current === 1 || current !== initial) {
      log.warn("parent pid changed; exiting", { initial, current });
      process.exit(0);
    }
  }, intervalMs).unref();
}
