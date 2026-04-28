import { unlinkSync, existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import type { ServerWebSocket } from "bun";
import { Dispatcher } from "./dispatcher.js";
import { AgentRegistry } from "./agentRegistry.js";
import { registerMethods } from "./methods.js";
import { parseFrame, formatEvent } from "./rpc.js";
import { log } from "./logger.js";

export type ServerOptions = {
  socketPath?: string;
  port?: number;
  dataDir: string;
};

export type ServerHandle = {
  stop: () => Promise<void>;
  port?: number;
};

export async function startServer(opts: ServerOptions): Promise<ServerHandle> {
  if (!opts.socketPath && opts.port == null) {
    throw new Error("startServer requires either socketPath or port");
  }
  if (opts.socketPath) {
    await mkdir(dirname(opts.socketPath), { recursive: true });
    if (existsSync(opts.socketPath)) {
      try {
        unlinkSync(opts.socketPath);
      } catch {
        // ignore
      }
    }
  }

  type WS = ServerWebSocket<undefined>;
  const clients = new Set<WS>();
  const sink = (workspaceId: string, ev: { type: string }) => {
    const frame = formatEvent(ev.type, { workspaceId, ...(ev as Record<string, unknown>) });
    for (const c of clients) {
      try {
        c.send(frame);
      } catch (e) {
        log.warn("send failed", { err: String(e) });
      }
    }
  };

  const registry = new AgentRegistry(opts.dataDir, sink);
  const dispatcher = new Dispatcher();
  registerMethods(dispatcher, registry);

  const serveOptions: any = {
    fetch(req: Request, server: any) {
      if (server.upgrade(req)) return;
      return new Response("multiharness-sidecar; use a WebSocket client", { status: 426 });
    },
    websocket: {
      open(ws: WS) {
        clients.add(ws);
        log.info("client connected", { count: clients.size });
      },
      close(ws: WS) {
        clients.delete(ws);
        log.info("client disconnected", { count: clients.size });
      },
      async message(ws: WS, raw: string | Buffer) {
        const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
        let req;
        try {
          req = parseFrame(text);
        } catch (e) {
          log.warn("bad frame", { err: String(e) });
          return;
        }
        const out = await dispatcher.dispatch(req.id, req.method, req.params);
        ws.send(out);
      },
    },
  };
  if (opts.socketPath) serveOptions.unix = opts.socketPath;
  if (opts.port != null) serveOptions.port = opts.port;

  const server = Bun.serve(serveOptions);

  // Signal readiness on stderr (SidecarManager watches for this exact line).
  console.error("READY");
  log.info("listening", {
    socket: opts.socketPath ?? null,
    port: opts.port ?? (server as any).port ?? null,
  });

  return {
    stop: async () => {
      await registry.disposeAll();
      server.stop(true);
      if (opts.socketPath) {
        try {
          unlinkSync(opts.socketPath);
        } catch {
          // ignore
        }
      }
    },
    port: (server as any).port,
  };
}
