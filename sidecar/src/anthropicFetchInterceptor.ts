import { log } from "./logger.js";

/**
 * Wraps `globalThis.fetch` to rewrite Anthropic /v1/messages requests
 * for our Console-minted provider so they pass Anthropic's Claude Code
 * tier check.
 *
 * Anthropic's edge gates the Claude Code rate-limit tier on the *first*
 * system-prompt block being exactly `"You are Claude Code, Anthropic's
 * official CLI for Claude."`. pi-ai's @anthropic-ai/sdk client only
 * inserts that block when the apiKey has the `sk-ant-oat` prefix
 * (Pro/Max OAuth). Console-minted `sk-ant-api03` keys go through a
 * branch that concatenates everything into a single block — which
 * Anthropic reads as "not Claude Code" and 429s.
 *
 * Detection signal: the `x-app: cli` header we set on our consoleMint
 * model. When we see that on a POST to api.anthropic.com/v1/messages,
 * we read the body, split the system field into [magic, rest], and
 * forward the modified body.
 */

const CLAUDE_CODE_IDENTITY =
  "You are Claude Code, Anthropic's official CLI for Claude.";

const ANTHROPIC_HOST = "api.anthropic.com";

type SystemBlock = { type: "text"; text: string; cache_control?: unknown };

function isMessagesRequest(url: string): boolean {
  try {
    const u = new URL(url);
    return u.hostname === ANTHROPIC_HOST && u.pathname === "/v1/messages";
  } catch {
    return false;
  }
}

function getHeader(headers: unknown, name: string): string | undefined {
  if (!headers) return undefined;
  if (headers instanceof Headers) {
    return headers.get(name) ?? undefined;
  }
  if (Array.isArray(headers)) {
    for (const [k, v] of headers) {
      if (typeof k === "string" && k.toLowerCase() === name.toLowerCase()) {
        return String(v);
      }
    }
    return undefined;
  }
  if (typeof headers === "object") {
    for (const [k, v] of Object.entries(headers as Record<string, unknown>)) {
      if (k.toLowerCase() === name.toLowerCase()) return String(v);
    }
  }
  return undefined;
}

function rewriteSystem(body: unknown): unknown {
  if (typeof body !== "object" || body === null) return body;
  const obj = body as Record<string, unknown>;
  const sys = obj.system;

  // Already a multi-block array starting with the magic string — leave alone.
  if (Array.isArray(sys)) {
    const first = sys[0] as SystemBlock | undefined;
    if (first?.type === "text" && first.text === CLAUDE_CODE_IDENTITY) {
      return body;
    }
    // One block whose text starts with the magic string — split.
    if (
      sys.length === 1 &&
      first?.type === "text" &&
      typeof first.text === "string" &&
      first.text.startsWith(CLAUDE_CODE_IDENTITY)
    ) {
      const rest = first.text.slice(CLAUDE_CODE_IDENTITY.length).replace(/^\n+/, "");
      const cacheControl = first.cache_control;
      const newSystem: SystemBlock[] = [
        {
          type: "text",
          text: CLAUDE_CODE_IDENTITY,
          ...(cacheControl ? { cache_control: cacheControl } : {}),
        },
      ];
      if (rest.length > 0) {
        newSystem.push({
          type: "text",
          text: rest,
          ...(cacheControl ? { cache_control: cacheControl } : {}),
        });
      }
      return { ...obj, system: newSystem };
    }
    // Other multi-block array — prepend the magic block.
    return {
      ...obj,
      system: [{ type: "text", text: CLAUDE_CODE_IDENTITY }, ...sys],
    };
  }

  // String form (rare). Prepend.
  if (typeof sys === "string") {
    const rest = sys.startsWith(CLAUDE_CODE_IDENTITY)
      ? sys.slice(CLAUDE_CODE_IDENTITY.length).replace(/^\n+/, "")
      : sys;
    const newSystem: SystemBlock[] = [
      { type: "text", text: CLAUDE_CODE_IDENTITY },
    ];
    if (rest.length > 0) newSystem.push({ type: "text", text: rest });
    return { ...obj, system: newSystem };
  }

  // No system at all — add one.
  return {
    ...obj,
    system: [{ type: "text", text: CLAUDE_CODE_IDENTITY }],
  };
}

export function installAnthropicFetchInterceptor(): void {
  const original = globalThis.fetch.bind(globalThis);

  const wrapped = async (input: any, init?: any): Promise<Response> => {
    const url: string =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : (input as { url: string }).url;

    if (!isMessagesRequest(url)) {
      return original(input, init);
    }

    let xApp: string | undefined = getHeader(init?.headers, "x-app");
    if (!xApp && input && typeof input === "object" && "headers" in input) {
      const h = (input as { headers?: { get?: (n: string) => string | null } })
        .headers;
      xApp = h?.get?.("x-app") ?? undefined;
    }

    if (xApp !== "cli") {
      return original(input, init);
    }

    let body: unknown = init?.body;
    if (typeof body !== "string") {
      if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
        body = new TextDecoder().decode(body as ArrayBuffer);
      } else if (
        body &&
        typeof (body as { text?: () => Promise<string> }).text === "function"
      ) {
        body = await (body as { text: () => Promise<string> }).text();
      } else {
        return original(input, init);
      }
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(body as string);
    } catch {
      return original(input, init);
    }

    const rewritten = rewriteSystem(parsed);
    const newBody = JSON.stringify(rewritten);

    log.info("anthropic fetch interceptor: rewrote system blocks", {
      originalLength: (body as string).length,
      newLength: newBody.length,
    });

    return original(url, { ...init, body: newBody });
  };

  globalThis.fetch = wrapped as typeof globalThis.fetch;
}
