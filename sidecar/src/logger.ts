type Level = "debug" | "info" | "warn" | "error";

const LEVELS: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const threshold =
  LEVELS[(process.env.MULTIHARNESS_LOG_LEVEL as Level) ?? "info"] ?? LEVELS.info;

function emit(level: Level, msg: string, extra?: Record<string, unknown>): void {
  if (LEVELS[level] < threshold) return;
  const ts = new Date().toISOString();
  const payload = extra ? ` ${JSON.stringify(extra)}` : "";
  console.error(`${ts} ${level} ${msg}${payload}`);
}

export const log = {
  debug: (m: string, e?: Record<string, unknown>) => emit("debug", m, e),
  info: (m: string, e?: Record<string, unknown>) => emit("info", m, e),
  warn: (m: string, e?: Record<string, unknown>) => emit("warn", m, e),
  error: (m: string, e?: Record<string, unknown>) => emit("error", m, e),
};
