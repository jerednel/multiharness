type Level = "debug" | "info" | "warn" | "error";

const LEVELS: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const threshold =
  LEVELS[(process.env.MULTIHARNESS_LOG_LEVEL as Level) ?? "info"] ?? LEVELS.info;

// Once stderr's pipe breaks, every console.error throws EPIPE — and any
// retries (e.g., from a SIGPIPE handler) just re-fire the same error in
// a tight loop. After the first EPIPE we silently drop further writes;
// the SIGPIPE handler in index.ts will exit the process shortly after.
let writesEnabled = true;

function emit(level: Level, msg: string, extra?: Record<string, unknown>): void {
  if (!writesEnabled) return;
  if (LEVELS[level] < threshold) return;
  const ts = new Date().toISOString();
  const payload = extra ? ` ${JSON.stringify(extra)}` : "";
  try {
    console.error(`${ts} ${level} ${msg}${payload}`);
  } catch (err) {
    // EPIPE / EBADF / etc. — output is gone. Stop trying.
    if (
      err &&
      typeof err === "object" &&
      "code" in err &&
      (err as { code?: string }).code === "EPIPE"
    ) {
      writesEnabled = false;
      return;
    }
    // Any other error: also disable to avoid loops, but rethrow once so
    // the uncaughtException handler can record it.
    writesEnabled = false;
    throw err;
  }
}

export const log = {
  debug: (m: string, e?: Record<string, unknown>) => emit("debug", m, e),
  info: (m: string, e?: Record<string, unknown>) => emit("info", m, e),
  warn: (m: string, e?: Record<string, unknown>) => emit("warn", m, e),
  error: (m: string, e?: Record<string, unknown>) => emit("error", m, e),
};
