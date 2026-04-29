import type { ServerWebSocket } from "bun";
import { log } from "./logger.js";

type WS = ServerWebSocket<undefined>;

/**
 * The relay lets clients ask the sidecar to forward a method call to a
 * privileged client (the macOS app) that has registered itself as the
 * handler. Used for actions the sidecar can't do itself: workspace
 * creation (needs git + SQLite + the user's worktree path conventions),
 * project addition, etc.
 *
 * Wire shape:
 *
 *   iPhone → sidecar:   { id, method: "workspace.create", params }
 *   sidecar → handler:  { event: "relay_request",
 *                         params: { relayId, method, params } }
 *   handler → sidecar:  { method: "relay.respond",
 *                         params: { relayId, result | error } }
 *   sidecar → iPhone:   { id, result | error }
 *
 * The sidecar correlates by `relayId`. Requests time out so a missing or
 * crashed handler can't pin a request open forever.
 */
export class Relay {
  private handler: WS | null = null;
  private pending = new Map<string, {
    resolve: (v: unknown) => void;
    reject: (e: Error) => void;
    timeout: ReturnType<typeof setTimeout>;
  }>();

  setHandler(ws: WS): void {
    this.handler = ws;
    log.info("relay handler registered");
  }

  unsetHandlerIfMatches(ws: WS): void {
    if (this.handler === ws) {
      this.handler = null;
      log.info("relay handler dropped");
      // Cancel any in-flight requests — handler is gone.
      for (const [id, p] of this.pending) {
        clearTimeout(p.timeout);
        p.reject(new Error("handler disconnected"));
        this.pending.delete(id);
      }
    }
  }

  /// Send a relayed request and await the handler's response.
  async dispatch(method: string, params: Record<string, unknown>, timeoutMs = 30_000): Promise<unknown> {
    const handler = this.handler;
    if (!handler) {
      throw new Error("no relay handler connected (Mac app must be running)");
    }
    const relayId = crypto.randomUUID();
    return await new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(relayId);
        reject(new Error(`relayed ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(relayId, { resolve, reject, timeout });
      const frame = JSON.stringify({
        event: "relay_request",
        params: { relayId, method, params },
      });
      try {
        handler.send(frame);
      } catch (e) {
        this.pending.delete(relayId);
        clearTimeout(timeout);
        reject(e instanceof Error ? e : new Error(String(e)));
      }
    });
  }

  /// Called from the dispatcher when the handler sends `relay.respond`.
  acceptResponse(relayId: string, result: unknown | undefined, error: { code: string; message: string } | undefined): void {
    const p = this.pending.get(relayId);
    if (!p) {
      log.warn("relay.respond for unknown id", { relayId });
      return;
    }
    clearTimeout(p.timeout);
    this.pending.delete(relayId);
    if (error) {
      p.reject(new Error(`[${error.code}] ${error.message}`));
    } else {
      p.resolve(result);
    }
  }
}
