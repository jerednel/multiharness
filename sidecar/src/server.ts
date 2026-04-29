import { unlinkSync, existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import type { ServerWebSocket } from "bun";
import { Dispatcher } from "./dispatcher.js";
import { AgentRegistry } from "./agentRegistry.js";
import { registerMethods } from "./methods.js";
import { parseFrame, formatEvent } from "./rpc.js";
import { log } from "./logger.js";
import { Relay } from "./relay.js";
import { OAuthStore } from "./oauthStore.js";
import { WorkspaceActivityTracker } from "./workspaceActivity.js";

export type ServerOptions = {
  socketPath?: string;
  port?: number;
  /**
   * Hostname / IP to bind. Defaults to "127.0.0.1" so the server is loopback-
   * only unless the operator explicitly opens it (e.g. "0.0.0.0" for LAN).
   * Ignored when socketPath is set.
   */
  bind?: string;
  /**
   * Optional bearer token. If set, every WebSocket upgrade must carry
   * `Authorization: Bearer <token>`. Required when bind is non-loopback.
   */
  authToken?: string;
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
  const tracker = new WorkspaceActivityTracker(opts.dataDir);

  function broadcast(frame: string): void {
    for (const c of clients) {
      try {
        c.send(frame);
      } catch (e) {
        log.warn("send failed", { err: String(e) });
      }
    }
  }

  const sink = (workspaceId: string, ev: { type: string }) => {
    // Fan out the original event to all clients first so order-of-events
    // observed by clients matches what AgentSession produced.
    const frame = formatEvent(ev.type, { workspaceId, ...(ev as Record<string, unknown>) });
    broadcast(frame);

    // Mirror agent start/end into the tracker, then push a workspace.activity
    // event so iOS workspace lists update without polling.
    if (workspaceId && (ev.type === "agent_start" || ev.type === "agent_end")) {
      tracker.observe(workspaceId, ev.type);
      const activity = formatEvent("workspace.activity", {
        workspaceId,
        isStreaming: tracker.isStreaming(workspaceId),
        // unseen is recomputed against per-workspace lastViewedAt by the
        // recipient — sidecar can't know lastViewedAt without re-querying
        // SQLite, and clients already cache it from their last
        // remote.workspaces snapshot. So just send isStreaming and the
        // latest lastAssistantAt, letting the client decide.
        lastAssistantAt: tracker.lastAssistantAt(workspaceId),
      });
      broadcast(activity);
    }
  };

  const oauthStore = new OAuthStore(opts.dataDir);
  const relay = new Relay();
  const dispatcher = new Dispatcher();
  // The registry needs a way to rename workspaces (used by the AI-naming
  // task on first prompt). Route it through the dispatcher so it shares
  // the workspace.rename handler's broadcast side effect; the closure
  // captures `dispatcher`, which is constructed above this line and
  // populated by registerMethods below.
  const registry = new AgentRegistry(
    opts.dataDir,
    sink,
    oauthStore,
    async (workspaceId: string, name: string) => {
      await dispatcher.invoke("workspace.rename", { workspaceId, name });
    },
  );
  registerMethods(dispatcher, registry, opts.dataDir, relay, oauthStore, sink, tracker);

  const expectedAuth = opts.authToken ? `Bearer ${opts.authToken}` : null;
  const isPrivateBind =
    !opts.port || !opts.bind || opts.bind === "127.0.0.1" || opts.bind === "localhost";
  if (!isPrivateBind && !expectedAuth) {
    throw new Error("non-loopback bind requires authToken (refusing to expose unauthenticated control API)");
  }

  const serveOptions: any = {
    fetch(req: Request, server: any) {
      if (expectedAuth) {
        const got = req.headers.get("authorization");
        if (got !== expectedAuth) {
          log.warn("rejected upgrade — bad token");
          return new Response("unauthorized", { status: 401 });
        }
      }
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
        relay.unsetHandlerIfMatches(ws);
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
        // Special-case the two relay-control methods so they hit the per-
        // connection relay state directly.
        if (req.method === "client.register") {
          const role = (req.params as { role?: string }).role;
          if (role === "handler") {
            relay.setHandler(ws);
            ws.send(JSON.stringify({ id: req.id, result: { ok: true } }));
            return;
          }
        }
        if (req.method === "relay.respond") {
          const { relayId, result, error } = req.params as {
            relayId: string;
            result?: unknown;
            error?: { code: string; message: string };
          };
          relay.acceptResponse(relayId, result, error);
          ws.send(JSON.stringify({ id: req.id, result: { ok: true } }));
          return;
        }
        const paramsStr = JSON.stringify(req.params);
        log.warn("dispatch", {
          method: req.method,
          id: req.id,
          paramsBytes: paramsStr.length,
          paramsPreview: paramsStr.slice(0, 80),
        });
        const out = await dispatcher.dispatch(req.id, req.method, req.params);
        ws.send(out);
        log.warn("dispatched", { method: req.method, id: req.id, replyBytes: out.length });
      },
    },
  };
  if (opts.socketPath) serveOptions.unix = opts.socketPath;
  if (opts.port != null) {
    serveOptions.port = opts.port;
    serveOptions.hostname = opts.bind ?? "127.0.0.1";
  }

  const server = Bun.serve(serveOptions);

  const actualPort: number | null = (server as any).port ?? null;
  // Signal readiness on stderr (SidecarManager watches for this exact line).
  console.error("READY");
  log.info("listening", {
    socket: opts.socketPath ?? null,
    port: actualPort,
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
    port: actualPort ?? undefined,
  };
}
