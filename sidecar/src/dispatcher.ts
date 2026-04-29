import { formatErrorResponse, formatResponse } from "./rpc.js";

export type Handler = (params: Record<string, unknown>) => Promise<unknown> | unknown;

export class Dispatcher {
  private readonly handlers = new Map<string, Handler>();

  register(method: string, handler: Handler): void {
    this.handlers.set(method, handler);
  }

  async dispatch(id: string, method: string, params: Record<string, unknown>): Promise<string> {
    const h = this.handlers.get(method);
    if (!h) return formatErrorResponse(id, "METHOD_NOT_FOUND", `unknown method: ${method}`);
    try {
      const result = await h(params);
      return formatResponse(id, result ?? null);
    } catch (e) {
      const err = e as Error;
      return formatErrorResponse(id, "HANDLER_ERROR", err.message ?? String(err));
    }
  }

  /// Invoke a registered handler in-process and return its raw result. Used
  /// by sidecar-internal callers (e.g. the workspace-name AI task) that
  /// need the same side effects a wire-level call would trigger but don't
  /// have a request id to reply to.
  async invoke(method: string, params: Record<string, unknown>): Promise<unknown> {
    const h = this.handlers.get(method);
    if (!h) throw new Error(`unknown method: ${method}`);
    return await h(params);
  }
}
