// Tier 2.5 summarizer for context compaction.
//
// Takes a contiguous slice of messages (one full turn-pair: user →
// toolResults/assistants → up to but not including the next user message)
// and asks an LLM to compress it into a single short prose summary. The
// summary is then spliced into the transcript as a synthetic user message
// labeled "[Earlier conversation summary]".
//
// Strict isolation rules:
//
//   1. Never throws — `transformContext` contract forbids it. On any
//      failure (timeout, model error, empty output) we return `null` and
//      the compactor falls through to Tier 3 (hard drop).
//   2. Uses the *same* model/provider as the main agent, so cost/auth
//      semantics are predictable and there's no separate config to
//      manage. For a 200k-window model summarizing a single turn-pair
//      this is typically free (<1k input tokens, <200 output).
//   3. Aggressive timeout (10s default) so a slow Ollama can't stall the
//      next LLM call. If summarization is consistently slow on a given
//      provider, the user will still get sessions that work — they'll
//      just degrade to Tier 3 sooner.

import { complete, type Message } from "@mariozechner/pi-ai";
import { buildModel, type ProviderConfig } from "./providers.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";
import type { Summarizer } from "./contextCompactor.js";
import { log } from "./logger.js";

export type CompleteFn = typeof complete;

const SYSTEM_PROMPT = [
  "You compress prior conversation segments for an AI coding agent's working memory.",
  "Given a slice of messages (one user request and the agent's response, possibly including tool calls), return a SINGLE PARAGRAPH summary of:",
  "  - what the user asked,",
  "  - what the agent did (which tools it ran, what files/areas it touched),",
  "  - any concrete results, decisions, or open questions worth remembering.",
  "Be specific and terse. ≤300 words. No markdown, no lists, no preamble.",
  "If the segment is unimportant or unintelligible, return exactly: NIL",
].join("\n");

const MAX_OUTPUT_TOKENS = 400;
const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * Render a slice of messages into a compact text form the summarizer
 * model can read. We don't pass the raw `Message[]` because providers
 * differ on what content blocks they accept in arbitrary positions; a
 * plain text dump is universal and lets us include `toolCall.arguments`
 * which carry the semantic intent of each step.
 */
function renderSliceAsText(slice: Message[]): string {
  const lines: string[] = [];
  for (const m of slice) {
    if (m.role === "user") {
      const text =
        typeof m.content === "string"
          ? m.content
          : m.content
              .map((b) => (b.type === "text" ? b.text : `[${b.type}]`))
              .join("");
      lines.push(`USER: ${text}`);
    } else if (m.role === "assistant") {
      for (const block of m.content) {
        if (block.type === "text") {
          lines.push(`ASSISTANT: ${block.text}`);
        } else if (block.type === "toolCall") {
          const argsJson = safeStringify(block.arguments);
          lines.push(`TOOL_CALL ${block.name}(${argsJson})`);
        } else if (block.type === "thinking") {
          // Skip thinking blocks — they're internal, not part of the
          // user-visible interaction summary.
        }
      }
    } else if (m.role === "toolResult") {
      const text = m.content
        .map((b) => (b.type === "text" ? b.text : "[image]"))
        .join("");
      // Truncate huge tool results — we don't want to send 100KB of file
      // contents back through the summarizer; the *fact* of the result
      // is what matters, plus a small head.
      const truncated = text.length > 2000 ? text.slice(0, 2000) + "…[truncated]" : text;
      const flag = m.isError ? " [error]" : "";
      lines.push(`TOOL_RESULT ${m.toolName}${flag}: ${truncated}`);
    }
  }
  return lines.join("\n");
}

function safeStringify(v: unknown): string {
  try {
    const s = JSON.stringify(v);
    if (s.length <= 500) return s;
    return s.slice(0, 500) + "…";
  } catch {
    return "<unserializable>";
  }
}

export type SummarizerOptions = {
  providerConfig: ProviderConfig;
  oauthStore?: OAuthStore;
  timeoutMs?: number;
  /** Override for testing. */
  completeFn?: CompleteFn;
  /** Workspace id for logging context. */
  workspaceId?: string;
};

/**
 * Build a Summarizer closure suitable for passing to `compactMessagesAsync`
 * or `makeTransformContext`. Captures the agent's provider config so the
 * same model handles both the main turn and the summarization (no second
 * provider to authenticate or quota-manage).
 */
export function makeSummarizer(opts: SummarizerOptions): Summarizer {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const completeFn = opts.completeFn ?? complete;

  return async (slice, signal) => {
    try {
      const apiKey = await resolveApiKey(opts.providerConfig, opts.oauthStore);
      const model = buildModel(opts.providerConfig);

      const timeoutSignal = AbortSignal.timeout(timeoutMs);
      const sig = signal
        ? AbortSignal.any([signal, timeoutSignal])
        : timeoutSignal;

      const text = renderSliceAsText(slice);
      // Bound the *input* size too — if the slice is somehow gigantic
      // (e.g. a tool result of 500KB before our renderer truncates it,
      // shouldn't happen but defense-in-depth) we'd otherwise hand the
      // summarizer a request that overflows its own context. Cap at
      // ~40k chars (~10k tokens) which fits in any context window we
      // care about.
      const bounded =
        text.length > 40_000 ? text.slice(0, 40_000) + "\n…[input truncated]" : text;

      const result = await completeFn(
        model as any,
        {
          systemPrompt: SYSTEM_PROMPT,
          messages: [
            {
              role: "user",
              content: [{ type: "text", text: bounded }],
              timestamp: Date.now(),
            },
          ],
        },
        { apiKey, signal: sig, maxTokens: MAX_OUTPUT_TOKENS },
      );
      const out = extractText(result).trim();
      if (!out || out === "NIL") return null;
      return out;
    } catch (e) {
      log.warn("context summarizer failed", {
        workspaceId: opts.workspaceId,
        err: e instanceof Error ? e.message : String(e),
      });
      return null;
    }
  };
}

async function resolveApiKey(
  cfg: ProviderConfig,
  oauthStore?: OAuthStore,
): Promise<string | undefined> {
  if (cfg.kind === "anthropic-oauth") {
    if (!oauthStore) throw new Error("anthropic-oauth requires oauthStore");
    return await getAnthropicAccessToken(oauthStore);
  }
  if (cfg.kind === "openai-codex-oauth") {
    if (!oauthStore) throw new Error("openai-codex-oauth requires oauthStore");
    return await getOpenAICodexAccessToken(oauthStore);
  }
  return (cfg as any).apiKey;
}

function extractText(msg: { content: unknown[] }): string {
  return msg.content
    .filter((p): p is { type: string; text: string } => {
      return (
        !!p &&
        typeof p === "object" &&
        (p as { type?: string }).type === "text" &&
        typeof (p as { text?: unknown }).text === "string"
      );
    })
    .map((p) => p.text)
    .join("");
}

/** Exposed for testing. */
export const __testing = { renderSliceAsText };
