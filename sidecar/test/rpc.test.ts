import { describe, it, expect } from "bun:test";
import { parseFrame, formatResponse, formatErrorResponse, formatEvent } from "../src/rpc.js";

describe("rpc framing", () => {
  it("parses a valid request frame", () => {
    const raw = JSON.stringify({ id: "1", method: "health.ping", params: {} });
    const f = parseFrame(raw);
    expect(f.kind).toBe("request");
    if (f.kind === "request") {
      expect(f.id).toBe("1");
      expect(f.method).toBe("health.ping");
      expect(f.params).toEqual({});
    }
  });

  it("rejects non-JSON", () => {
    expect(() => parseFrame("not json")).toThrow(/parse/i);
  });

  it("rejects frame without id or method", () => {
    expect(() => parseFrame(JSON.stringify({ foo: 1 }))).toThrow(/method|id/i);
  });

  it("formats a success response", () => {
    expect(formatResponse("1", { ok: true })).toBe(
      JSON.stringify({ id: "1", result: { ok: true } }),
    );
  });

  it("formats an error response", () => {
    expect(formatErrorResponse("1", "INVALID", "bad input")).toBe(
      JSON.stringify({ id: "1", error: { code: "INVALID", message: "bad input" } }),
    );
  });

  it("formats an event", () => {
    expect(formatEvent("turn_start", { workspaceId: "w1" })).toBe(
      JSON.stringify({ event: "turn_start", params: { workspaceId: "w1" } }),
    );
  });
});
