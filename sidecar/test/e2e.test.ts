import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, existsSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer, type ServerHandle } from "../src/server.js";

let dataDir: string;
let worktree: string;
let serverHandle: ServerHandle | null = null;
let mockServer: { stop: (closeActive?: boolean) => void; port: number | undefined } | null =
  null;
let mockBaseUrl = "";

beforeAll(async () => {
  dataDir = realpathSync(mkdtempSync(join(tmpdir(), "mh-e2e-data-")));
  worktree = realpathSync(mkdtempSync(join(tmpdir(), "mh-e2e-wt-")));
  mkdirSync(join(dataDir, "sock"), { recursive: true });

  // Mock OpenAI-compatible streaming endpoint.
  mockServer = Bun.serve({
    port: 0,
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/chat/completions" || url.pathname === "/v1/chat/completions") {
        const stream = new ReadableStream({
          start(c) {
            const enc = new TextEncoder();
            const id = "chatcmpl-mock";
            const created = Math.floor(Date.now() / 1000);
            const baseChunk = (delta: object, finishReason: string | null) => ({
              id,
              object: "chat.completion.chunk",
              created,
              model: "mock-model",
              choices: [{ index: 0, delta, finish_reason: finishReason }],
            });
            c.enqueue(enc.encode(`data: ${JSON.stringify(baseChunk({ role: "assistant", content: "" }, null))}\n\n`));
            c.enqueue(enc.encode(`data: ${JSON.stringify(baseChunk({ content: "hi" }, null))}\n\n`));
            c.enqueue(enc.encode(`data: ${JSON.stringify(baseChunk({}, "stop"))}\n\n`));
            c.enqueue(enc.encode("data: [DONE]\n\n"));
            c.close();
          },
        });
        return new Response(stream, {
          headers: { "content-type": "text/event-stream" },
        });
      }
      return new Response("not found", { status: 404 });
    },
  });
  mockBaseUrl = `http://127.0.0.1:${mockServer!.port}/v1`;

  serverHandle = await startServer({ port: 0, dataDir });
});

afterAll(async () => {
  await serverHandle?.stop();
  mockServer?.stop(true);
});

describe("e2e: server + websocket + mock provider", () => {
  it("creates an agent and streams events from a prompt", async () => {
    const port = serverHandle!.port!;
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    await new Promise<void>((res, rej) => {
      const t = setTimeout(() => rej(new Error("ws open timeout")), 3000);
      ws.addEventListener(
        "open",
        () => {
          clearTimeout(t);
          res();
        },
        { once: true },
      );
      ws.addEventListener(
        "error",
        (e) => {
          clearTimeout(t);
          rej(new Error(`ws error: ${String(e)}`));
        },
        { once: true },
      );
    });

    const events: any[] = [];
    ws.addEventListener("message", (m) => {
      const obj = JSON.parse(typeof m.data === "string" ? m.data : "");
      events.push(obj);
    });

    function call(method: string, params: object): Promise<any> {
      return new Promise((res, rej) => {
        const id = crypto.randomUUID();
        const handler = (m: MessageEvent) => {
          const obj = JSON.parse(typeof m.data === "string" ? m.data : "");
          if (obj.id === id) {
            ws.removeEventListener("message", handler as any);
            obj.error ? rej(new Error(obj.error.message)) : res(obj.result);
          }
        };
        ws.addEventListener("message", handler as any);
        ws.send(JSON.stringify({ id, method, params }));
      });
    }

    const ping = await call("health.ping", {});
    expect(ping).toMatchObject({ pong: true });

    await call("agent.create", {
      workspaceId: "w1",
      projectId: "p1",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: {
        kind: "openai-compatible",
        modelId: "mock-model",
        baseUrl: mockBaseUrl,
        apiKey: "sk-mock",
      },
    });

    await call("agent.prompt", { workspaceId: "w1", message: "say hi" });

    // Wait for agent_end
    await new Promise<void>((res, rej) => {
      const t = setTimeout(() => rej(new Error("timeout waiting for agent_end")), 8000);
      const i = setInterval(() => {
        if (events.some((e) => e.event === "agent_end")) {
          clearInterval(i);
          clearTimeout(t);
          res();
        }
      }, 50);
    });

    expect(events.find((e) => e.event === "agent_start")).toBeDefined();
    expect(events.find((e) => e.event === "message_end")).toBeDefined();

    expect(existsSync(join(dataDir, "workspaces", "w1", "messages.jsonl"))).toBe(true);
    const log = readFileSync(join(dataDir, "workspaces", "w1", "messages.jsonl"), "utf8");
    expect(log).toMatch(/agent_end/);

    await call("agent.dispose", { workspaceId: "w1" });
    ws.close();
  }, 15_000);
});
