import { startServer } from "./server.js";
import { startParentPidWatchdog } from "./watchdog.js";
import { log } from "./logger.js";

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

const port = portEnv ? Number.parseInt(portEnv, 10) : undefined;
if (portEnv && (port == null || Number.isNaN(port))) {
  console.error(`FATAL: MULTIHARNESS_PORT is not a number: ${portEnv}`);
  process.exit(2);
}

const handle = await startServer({ socketPath, port, dataDir });

const shutdown = async () => {
  log.info("shutting down");
  await handle.stop();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
