export type RpcRequest = {
  kind: "request";
  id: string;
  method: string;
  params: Record<string, unknown>;
};

export type ParsedFrame = RpcRequest;

export function parseFrame(raw: string): ParsedFrame {
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch (e) {
    throw new Error(`parse error: ${(e as Error).message}`);
  }
  if (!obj || typeof obj !== "object") throw new Error("frame must be an object");
  const o = obj as Record<string, unknown>;
  if (typeof o.id !== "string") throw new Error("frame missing string id");
  if (typeof o.method !== "string") throw new Error("frame missing string method");
  const params =
    o.params && typeof o.params === "object" ? (o.params as Record<string, unknown>) : {};
  return { kind: "request", id: o.id, method: o.method, params };
}

export function formatResponse(id: string, result: unknown): string {
  return JSON.stringify({ id, result });
}

export function formatErrorResponse(id: string, code: string, message: string): string {
  return JSON.stringify({ id, error: { code, message } });
}

export function formatEvent(event: string, params: Record<string, unknown>): string {
  return JSON.stringify({ event, params });
}
