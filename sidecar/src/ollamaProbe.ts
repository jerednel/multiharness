// Auto-detection of an Ollama instance's effective context window for a
// given model. The user-facing OpenAI-compatible endpoint (/v1/chat/...)
// doesn't expose `num_ctx`; Ollama's native /api/show does.
//
// We make this best-effort: if the probe fails (network, non-Ollama
// server, model not pulled, etc.) the caller falls back to whatever
// `contextWindow` was on the provider config or its default.

import { log } from "./logger.js";

/**
 * Convert an OpenAI-compatible base URL into the Ollama native /api root.
 *
 * Ollama exposes:
 *   - OpenAI-compatible: http://host:11434/v1
 *   - Native API:        http://host:11434/api/...
 *
 * Other OpenAI-compatible servers (vLLM, LM Studio, llama.cpp's server)
 * generally don't have a sibling /api/show endpoint, so probing them is
 * harmless — they'll return 404 and we'll fall back to the configured
 * window.
 */
export function ollamaApiRoot(openaiCompatibleBaseUrl: string): string {
  const trimmed = openaiCompatibleBaseUrl.replace(/\/+$/, "");
  // Strip a trailing /v1 segment if present. Anything else (e.g. a
  // proxy path) is left alone — the probe will simply return 404.
  if (trimmed.endsWith("/v1")) {
    return trimmed.slice(0, -3);
  }
  return trimmed;
}

/** Detect-result heuristics shape. */
export type OllamaProbeResult = {
  /** Effective `num_ctx` for the running model (modelfile/env override). */
  numCtx?: number;
  /** Architectural max context length (from model_info). */
  architectureMax?: number;
  /** Best single number to use — `numCtx` if known, else architectureMax. */
  contextWindow?: number;
};

/**
 * Probe `<root>/api/show` for the given model and pull whatever
 * context-window signal we can find. Resolves with an empty object on any
 * failure — never throws.
 */
export async function probeOllamaContextWindow(
  openaiCompatibleBaseUrl: string,
  modelId: string,
  timeoutMs = 3_000,
): Promise<OllamaProbeResult> {
  try {
    const root = ollamaApiRoot(openaiCompatibleBaseUrl);
    const url = `${root}/api/show`;
    const ctrl = AbortSignal.timeout(timeoutMs);
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: modelId }),
      signal: ctrl,
    });
    if (!res.ok) {
      log.info("ollama probe non-ok status", {
        url,
        modelId,
        status: res.status,
      });
      return {};
    }
    const body: any = await res.json();
    return parseOllamaShow(body);
  } catch (e) {
    log.info("ollama probe failed (likely non-ollama or unreachable)", {
      baseUrl: openaiCompatibleBaseUrl,
      modelId,
      err: e instanceof Error ? e.message : String(e),
    });
    return {};
  }
}

/**
 * Pure parser exposed for testing. The /api/show response shape Ollama
 * returns looks roughly like:
 *
 *   {
 *     "modelfile": "...",
 *     "parameters": "num_ctx 8192\nnum_predict 256\n...",   // optional
 *     "template": "...",
 *     "details": {...},
 *     "model_info": {
 *       "general.architecture": "llama",
 *       "llama.context_length": 131072,
 *       ...
 *     }
 *   }
 *
 * - `parameters` is a newline-separated, space-delimited list of
 *   modelfile overrides. `num_ctx <int>` is the per-model `num_ctx` set
 *   by the user via `FROM ... PARAMETER num_ctx ...` in a Modelfile.
 *   When present, this is the *effective* runtime window — that's what
 *   we want.
 * - `model_info["<arch>.context_length"]` is the architecturally
 *   advertised maximum (e.g. 131072 for llama3). We use it as a
 *   fallback when no explicit override exists.
 *
 * Note: Ollama's *default* runtime `num_ctx` is 2048 unless overridden
 * by the modelfile OR by the request body's `num_ctx`. The OpenAI-
 * compatible endpoint does NOT currently pass `num_ctx` through, so a
 * model with a 131k architectural ceiling but no modelfile override
 * will run at 2048 unless the user has set `OLLAMA_NUM_CTX` globally.
 *
 * Our heuristic: prefer the explicit modelfile `num_ctx`. When absent,
 * fall back to architectureMax — this is optimistic (assumes the user
 * has configured Ollama to use the full window), and if they haven't,
 * compaction will simply never fire (the model will silently truncate,
 * which is a different problem).
 */
export function parseOllamaShow(body: any): OllamaProbeResult {
  const result: OllamaProbeResult = {};

  // 1. Modelfile `num_ctx` override.
  if (typeof body?.parameters === "string") {
    const m = body.parameters.match(/^\s*num_ctx\s+(\d+)\s*$/m);
    if (m) {
      const n = parseInt(m[1]!, 10);
      if (Number.isFinite(n) && n > 0) result.numCtx = n;
    }
  }

  // 2. Architectural max from model_info.
  const info = body?.model_info;
  if (info && typeof info === "object") {
    const arch = info["general.architecture"];
    if (typeof arch === "string") {
      const key = `${arch}.context_length`;
      const v = info[key];
      if (typeof v === "number" && Number.isFinite(v) && v > 0) {
        result.architectureMax = v;
      }
    }
    // Some Ollama versions stash it under a different key — try a few.
    if (result.architectureMax === undefined) {
      for (const k of Object.keys(info)) {
        if (k.endsWith(".context_length")) {
          const v = info[k];
          if (typeof v === "number" && Number.isFinite(v) && v > 0) {
            result.architectureMax = v;
            break;
          }
        }
      }
    }
  }

  result.contextWindow = result.numCtx ?? result.architectureMax;
  return result;
}
