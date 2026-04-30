import { startServer } from "./server.js";
import { startParentPidWatchdog } from "./watchdog.js";
import { log } from "./logger.js";
import { installAnthropicFetchInterceptor } from "./anthropicFetchInterceptor.js";

// Must run before any provider client is constructed: rewrites system
// blocks for Console-minted Anthropic requests so they pass the Claude
// Code rate-limit tier check.
installAnthropicFetchInterceptor();

const socketPath = process.env.MULTIHARNESS_SOCKET;
const portEnv = process.env.MULTIHARNESS_PORT;
const dataDir = process.env.MULTIHARNESS_DATA_DIR;

if (!socketPath && !portEnv) {
  console.error(
    "FATAL: set either MULTIHARNESS_SOCKET (Unix socket path) or MULTIHARNESS_PORT (TCP loopback port)",
  );
  process.exit(2);
}
if (!dataDir) {
  console.error("FATAL: MULTIHARNESS_DATA_DIR env var is required");
  process.exit(2);
}

startParentPidWatchdog();

// Defensive: never let an uncaught exception or unhandled rejection bring
// the sidecar down silently. Both still get logged so we can investigate.
process.on("uncaughtException", (err) => {
  log.error("uncaughtException", { err: String(err), stack: (err as Error).stack });
});
process.on("unhandledRejection", (reason) => {
  log.error("unhandledRejection", { reason: String(reason) });
});

// Log signal-driven exits. SIGKILL bypasses this, but anything else
// (SIGTERM, SIGINT, SIGABRT, SIGSEGV) leaves a breadcrumb.
for (const sig of ["SIGTERM", "SIGINT", "SIGABRT", "SIGSEGV"] as const) {
  process.on(sig, () => {
    log.error(`received ${sig}`, { sig });
  });
}

// SIGPIPE means our stdout/stderr pipe closed (parent died without
// cleanup, output got piped through `head -N` that exited, etc.). The
// kernel default is to terminate the process; installing any handler
// suppresses that. Previously we logged a breadcrumb and kept running,
// but the next log write also EPIPEs and re-fires SIGPIPE — infinite
// loop at 100% CPU, port stays bound, the sidecar can't reach READY
// again. Restore the terminate-on-SIGPIPE behavior; the breadcrumb
// is best-effort because the very pipe we'd write it to is the one
// that closed.
process.on("SIGPIPE", () => {
  try {
    log.error("received SIGPIPE — output pipe closed, exiting");
  } catch {
    // ignore — the pipe is the thing that broke
  }
  process.exit(0);
});

// Heartbeat every 2 seconds at warn level — we want this visible without
// elevating MULTIHARNESS_LOG_LEVEL. If the sidecar dies suddenly we'll see
// the time-of-last-beat and the trailing memory footprint.
let heartbeatSeq = 0;
setInterval(() => {
  heartbeatSeq++;
  const m = process.memoryUsage();
  log.warn("heartbeat", {
    seq: heartbeatSeq,
    rssMB: Math.round(m.rss / 1024 / 1024),
    heapUsedMB: Math.round(m.heapUsed / 1024 / 1024),
    extMB: Math.round((m.external ?? 0) / 1024 / 1024),
    uptimeS: Math.round(process.uptime()),
  });
}, 2_000).unref();

const port = portEnv ? Number.parseInt(portEnv, 10) : undefined;
if (portEnv && (port == null || Number.isNaN(port))) {
  console.error(`FATAL: MULTIHARNESS_PORT is not a number: ${portEnv}`);
  process.exit(2);
}

const bind = process.env.MULTIHARNESS_BIND;
const authToken = process.env.MULTIHARNESS_AUTH_TOKEN;

let handle;
try {
  handle = await startServer({ socketPath, port, bind, authToken, dataDir });
} catch (err) {
  const msg = err instanceof Error ? err.message : String(err);
  // EADDRINUSE — the pinned port is already taken (another sidecar still
  // shutting down, another tool grabbed it, etc.). Retry on a random port.
  if (port && (msg.includes("EADDRINUSE") || msg.includes("address already in use"))) {
    log.warn("preferred port in use; falling back to a random port", { port, msg });
    handle = await startServer({ socketPath, port: 0, bind, authToken, dataDir });
  } else {
    throw err;
  }
}

const shutdown = async () => {
  log.info("shutting down");
  await handle.stop();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
