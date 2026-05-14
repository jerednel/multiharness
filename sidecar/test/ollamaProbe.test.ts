import { describe, it, expect } from "bun:test";
import { ollamaApiRoot, parseOllamaShow } from "../src/ollamaProbe.js";

describe("ollamaApiRoot", () => {
  it("strips trailing /v1", () => {
    expect(ollamaApiRoot("http://localhost:11434/v1")).toBe(
      "http://localhost:11434",
    );
  });

  it("strips trailing slashes before /v1 detection", () => {
    expect(ollamaApiRoot("http://localhost:11434/v1///")).toBe(
      "http://localhost:11434",
    );
  });

  it("leaves non-/v1 URLs alone", () => {
    expect(ollamaApiRoot("http://proxy/openai/")).toBe(
      "http://proxy/openai",
    );
  });

  it("works for tailnet hosts", () => {
    expect(ollamaApiRoot("http://gpu-box.tail-scale.ts.net:11434/v1")).toBe(
      "http://gpu-box.tail-scale.ts.net:11434",
    );
  });
});

describe("parseOllamaShow", () => {
  it("returns empty for malformed input", () => {
    expect(parseOllamaShow(null)).toEqual({});
    expect(parseOllamaShow({})).toEqual({});
    expect(parseOllamaShow({ foo: "bar" })).toEqual({});
  });

  it("extracts num_ctx from parameters string", () => {
    const body = {
      parameters: "num_ctx 8192\nnum_predict 256\ntemperature 0.7",
    };
    const r = parseOllamaShow(body);
    expect(r.numCtx).toBe(8192);
    expect(r.contextWindow).toBe(8192);
  });

  it("extracts architectureMax from model_info using general.architecture", () => {
    const body = {
      model_info: {
        "general.architecture": "llama",
        "llama.context_length": 131072,
      },
    };
    const r = parseOllamaShow(body);
    expect(r.architectureMax).toBe(131072);
    expect(r.contextWindow).toBe(131072);
  });

  it("prefers explicit num_ctx over architectural max", () => {
    const body = {
      parameters: "num_ctx 32768",
      model_info: {
        "general.architecture": "llama",
        "llama.context_length": 131072,
      },
    };
    const r = parseOllamaShow(body);
    expect(r.numCtx).toBe(32768);
    expect(r.architectureMax).toBe(131072);
    expect(r.contextWindow).toBe(32768);
  });

  it("falls back to scanning *.context_length when general.architecture missing", () => {
    const body = {
      model_info: {
        "qwen2.context_length": 262144,
      },
    };
    const r = parseOllamaShow(body);
    expect(r.architectureMax).toBe(262144);
    expect(r.contextWindow).toBe(262144);
  });

  it("ignores non-numeric or zero values", () => {
    const body = {
      parameters: "num_ctx abc",
      model_info: {
        "general.architecture": "llama",
        "llama.context_length": 0,
      },
    };
    const r = parseOllamaShow(body);
    expect(r.numCtx).toBeUndefined();
    expect(r.architectureMax).toBeUndefined();
    expect(r.contextWindow).toBeUndefined();
  });

  it("handles the real-world 262144 context Qwen3-Coder example", () => {
    // Shape captured from a Qwen3-Coder Ollama instance with the
    // user-reported 262144 effective window.
    const body = {
      modelfile: "FROM qwen3-coder:30b\n",
      parameters: "num_ctx 262144\nnum_predict -1",
      template: "...",
      details: { format: "gguf", family: "qwen3" },
      model_info: {
        "general.architecture": "qwen3",
        "qwen3.context_length": 262144,
        "qwen3.embedding_length": 5120,
      },
    };
    const r = parseOllamaShow(body);
    expect(r.contextWindow).toBe(262144);
  });
});
