import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mintAnthropicApiKey } from "../src/oauthStore.js";

describe("mintAnthropicApiKey", () => {
  const realFetch = globalThis.fetch;
  let calls: Array<{ url: string; init: RequestInit | undefined }> = [];

  beforeEach(() => {
    calls = [];
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  function mockFetch(response: { status: number; body: string }) {
    globalThis.fetch = (async (url: string, init?: RequestInit) => {
      calls.push({ url: String(url), init });
      return new Response(response.body, { status: response.status });
    }) as typeof fetch;
  }

  it("returns the minted key when the response uses raw_key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ raw_key: "sk-ant-api03-abc" }) });
    const key = await mintAnthropicApiKey("access-token-123");
    expect(key).toBe("sk-ant-api03-abc");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(
      "https://api.anthropic.com/api/oauth/claude_cli/create_api_key",
    );
    const headers = calls[0]!.init?.headers as Record<string, string> | undefined;
    expect(headers?.["Authorization"]).toBe("Bearer access-token-123");
  });

  it("returns the minted key when the response uses key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ key: "sk-ant-api03-xyz" }) });
    const key = await mintAnthropicApiKey("tok");
    expect(key).toBe("sk-ant-api03-xyz");
  });

  it("throws with the response body included on a 4xx", async () => {
    mockFetch({ status: 401, body: '{"error":"unauthorized"}' });
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/401/);
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/unauthorized/);
  });

  it("throws when the response body has no key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ unrelated: "field" }) });
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/unexpected payload/);
  });

  it("throws when the key does not look like an Anthropic key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ raw_key: "not-an-anthropic-key" }) });
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/unexpected payload/);
  });
});
