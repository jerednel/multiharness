import { describe, it, expect } from "bun:test";
import type {
  AssistantMessage,
  Message,
  ToolResultMessage,
  UserMessage,
} from "@mariozechner/pi-ai";
import {
  CHARS_PER_TOKEN,
  KEEP_RECENT,
  compactMessages,
  compactMessagesAsync,
  estimateMessageTokens,
  estimateTokensWithAnchor,
  estimateTotalTokens,
  makeTransformContext,
  nextTurnPairRange,
} from "../src/contextCompactor.js";

// ---- builders ----------------------------------------------------------

function u(text: string, ts = Date.now()): UserMessage {
  return { role: "user", content: text, timestamp: ts };
}

function a(text: string, opts: Partial<AssistantMessage> = {}): AssistantMessage {
  return {
    role: "assistant",
    content: [{ type: "text", text }],
    api: "anthropic-messages" as any,
    provider: "anthropic" as any,
    model: "test",
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp: Date.now(),
    ...opts,
  };
}

function aWithToolCall(callId: string, toolName: string, args: any = {}): AssistantMessage {
  return a("", {
    content: [
      { type: "toolCall", id: callId, name: toolName, arguments: args },
    ],
  });
}

function aWithTextAndCall(text: string, callId: string, toolName: string): AssistantMessage {
  return a(text, {
    content: [
      { type: "text", text },
      { type: "toolCall", id: callId, name: toolName, arguments: {} },
    ],
  });
}

function tr(callId: string, toolName: string, payload: string): ToolResultMessage {
  return {
    role: "toolResult",
    toolCallId: callId,
    toolName,
    content: [{ type: "text", text: payload }],
    isError: false,
    timestamp: Date.now(),
  };
}

// A turn-pair: user → assistant(toolCall) → toolResult → assistant(text)
function turnPair(userText: string, callId: string, toolPayload: string, finalText: string): Message[] {
  return [
    u(userText),
    aWithToolCall(callId, "read_file"),
    tr(callId, "read_file", toolPayload),
    a(finalText),
  ];
}

// Big string used to inflate token counts.
function bloat(kb: number): string {
  return "x".repeat(kb * 1024);
}

// ---- estimation --------------------------------------------------------

describe("estimateMessageTokens", () => {
  it("uses chars/4 with structural overhead", () => {
    const msg = u("hello"); // 5 chars + 20 overhead = 25 → ceil(25/4) = 7
    expect(estimateMessageTokens(msg)).toBe(Math.ceil((5 + 20) / CHARS_PER_TOKEN));
  });

  it("accounts for tool result payload size", () => {
    const big = tr("c1", "read_file", "x".repeat(4000));
    const small = tr("c1", "read_file", "x");
    expect(estimateMessageTokens(big)).toBeGreaterThan(
      estimateMessageTokens(small) + 500,
    );
  });

  it("counts toolCall arguments", () => {
    const withArgs = aWithToolCall("c1", "bash", { command: "ls -la /very/long/path/here" });
    const empty = aWithToolCall("c1", "bash", {});
    expect(estimateMessageTokens(withArgs)).toBeGreaterThan(estimateMessageTokens(empty));
  });
});

describe("estimateTokensWithAnchor", () => {
  it("falls back to full estimate when no anchor provided", () => {
    const msgs = [u("hello"), a("world")];
    expect(
      estimateTokensWithAnchor(msgs, { contextWindow: 8000 }),
    ).toBe(estimateTotalTokens(msgs));
  });

  it("anchors against lastKnownInputTokens and only estimates the tail", () => {
    const anchor = [u("first"), a("reply")];
    const live = [...anchor, u("follow up"), tr("c1", "read_file", "data")];
    const anchored = estimateTokensWithAnchor(live, {
      contextWindow: 8000,
      lastKnownInputTokens: 1000,
      lastKnownMessages: anchor,
    });
    // Anchored should be ~ 1000 + tail estimate (small), and strictly
    // less than the full estimate (which would re-count the anchor).
    expect(anchored).toBeGreaterThan(1000);
    expect(anchored).toBeLessThan(1000 + estimateTotalTokens(live));
  });

  it("falls back to full estimate when anchor is longer than live (shouldn't happen but is defensive)", () => {
    const anchor = [u("a"), a("b"), u("c")];
    const live = [u("a"), a("b")];
    const result = estimateTokensWithAnchor(live, {
      contextWindow: 8000,
      lastKnownInputTokens: 1000,
      lastKnownMessages: anchor,
    });
    expect(result).toBe(estimateTotalTokens(live));
  });
});

// ---- compaction --------------------------------------------------------

describe("compactMessages — tier 0 (pass-through)", () => {
  it("returns input unchanged when under budget", () => {
    const msgs = [u("hi"), a("hello")];
    const { messages, report } = compactMessages(msgs, { contextWindow: 200_000 });
    expect(report.tier).toBe(0);
    expect(messages).toBe(msgs); // identity — no copy needed
    expect(report.elidedToolResults).toBe(0);
    expect(report.droppedMessages).toBe(0);
  });
});

describe("compactMessages — tier 1 (elide old tool results)", () => {
  it("elides old tool result content but preserves toolCallId and toolName", () => {
    // Build many old turn-pairs with a single huge tool result each so
    // we blow the budget but tier 1 alone can rescue us.
    const oldPairs: Message[] = [];
    for (let i = 0; i < 8; i++) {
      oldPairs.push(...turnPair(`old ${i}`, `call-${i}`, bloat(8), `done ${i}`));
    }
    // Recent KEEP_RECENT messages (small, kept verbatim).
    const recent: Message[] = [];
    for (let i = 0; i < 3; i++) {
      recent.push(u(`recent ${i}`), a(`reply ${i}`));
    }
    const all = [...oldPairs, ...recent];
    const cw = 4000; // very small window to force tier 1
    const { messages, report } = compactMessages(all, { contextWindow: cw });

    expect(report.tier).toBeGreaterThanOrEqual(1);
    expect(report.elidedToolResults).toBeGreaterThan(0);

    // Find an elided tool result and check it preserves the id.
    const elidedTRs = messages.filter(
      (m): m is ToolResultMessage => m.role === "toolResult"
        && m.content.length === 1
        && m.content[0]!.type === "text"
        && m.content[0]!.text.startsWith("[elided:"),
    );
    expect(elidedTRs.length).toBeGreaterThan(0);
    for (const e of elidedTRs) {
      expect(e.toolCallId).toMatch(/^call-\d+$/);
      expect(e.toolName).toBe("read_file");
    }

    // Recent messages (last KEEP_RECENT) should be byte-identical to input.
    const tailStart = messages.length - KEEP_RECENT;
    for (let i = 0; i < KEEP_RECENT; i++) {
      expect(messages[tailStart + i]).toBe(all[all.length - KEEP_RECENT + i]);
    }
  });

  it("preserves toolCall ↔ toolResult pairing after elision", () => {
    const msgs: Message[] = [];
    for (let i = 0; i < 6; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(6), `a${i}`));
    }
    const { messages } = compactMessages(msgs, { contextWindow: 3000 });

    // Every toolCall id in any assistant message must have a matching
    // toolResult later in the array.
    const seenCallIds = new Set<string>();
    for (const m of messages) {
      if (m.role === "assistant") {
        for (const b of m.content) {
          if (b.type === "toolCall") seenCallIds.add(b.id);
        }
      }
    }
    const seenResultIds = new Set<string>();
    for (const m of messages) {
      if (m.role === "toolResult") seenResultIds.add(m.toolCallId);
    }
    for (const id of seenCallIds) {
      expect(seenResultIds.has(id)).toBe(true);
    }
    for (const id of seenResultIds) {
      expect(seenCallIds.has(id)).toBe(true);
    }
  });

  it("is idempotent — re-compacting an already-compacted transcript does nothing new", () => {
    const msgs: Message[] = [];
    for (let i = 0; i < 6; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(6), `a${i}`));
    }
    const first = compactMessages(msgs, { contextWindow: 3000 });
    const second = compactMessages(first.messages, { contextWindow: 3000 });
    // Second pass might still trigger tier > 0 (if still over budget) but
    // it shouldn't re-elide the same tool results — they're already
    // marked. The elidedToolResults count should be 0 on the second
    // pass for the same old slots.
    expect(second.report.elidedToolResults).toBe(0);
  });
});

describe("compactMessages — tier 2 (elide assistant prose)", () => {
  it("elides old assistant text when tool-result elision wasn't enough", () => {
    // Build pairs where the assistant final message is huge but tool
    // results are small. Tier 1 won't help much; tier 2 must kick in.
    const msgs: Message[] = [];
    for (let i = 0; i < 6; i++) {
      msgs.push(
        u(`q${i}`),
        aWithToolCall(`id-${i}`, "noop"),
        tr(`id-${i}`, "noop", "ok"),
        a(bloat(8)), // huge assistant prose
      );
    }
    // Add recent tail.
    for (let i = 0; i < 3; i++) {
      msgs.push(u(`recent ${i}`), a(`small ${i}`));
    }

    const { messages, report } = compactMessages(msgs, { contextWindow: 3000 });
    expect(report.tier).toBeGreaterThanOrEqual(2);
    expect(report.elidedAssistantBlocks).toBeGreaterThan(0);

    // Recent assistant messages should still have their original prose.
    const tail = messages.slice(messages.length - KEEP_RECENT);
    for (const m of tail) {
      if (m.role === "assistant") {
        for (const b of m.content) {
          if (b.type === "text") {
            expect(b.text.startsWith("[elided:")).toBe(false);
          }
        }
      }
    }
  });

  it("preserves toolCall blocks when eliding assistant prose", () => {
    // Assistant message with both prose AND a tool call. After tier 2
    // the toolCall must survive (pairing) while the text is replaced.
    const msgs: Message[] = [
      u("q0"),
      aWithTextAndCall(bloat(8), "id-0", "do_thing"),
      tr("id-0", "do_thing", "ok"),
      a("done"),
      // pad with more turn-pairs to push over budget
      ...turnPair("q1", "id-1", bloat(8), "done"),
      ...turnPair("q2", "id-2", bloat(8), "done"),
      // recent
      u("recent"),
      a("ok"),
      u("recent2"),
      a("ok"),
      u("recent3"),
      a("ok"),
    ];
    const { messages } = compactMessages(msgs, { contextWindow: 2500 });
    // Find the surviving assistant message that originally had the
    // toolCall id-0 — the toolCall block must still be there.
    const survivor = messages.find(
      (m) => m.role === "assistant"
        && m.content.some((b) => b.type === "toolCall" && b.id === "id-0"),
    );
    expect(survivor).toBeDefined();
  });
});

describe("compactMessages — tier 3 (drop oldest turn-pair)", () => {
  it("drops the second-oldest turn-pair, preserves the first user message", () => {
    // Build a lot of turn-pairs that even fully-elided exceed budget.
    const msgs: Message[] = [];
    for (let i = 0; i < 20; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(20), bloat(20)));
    }
    const { messages, report } = compactMessages(msgs, { contextWindow: 4000 });
    expect(report.tier).toBe(3);
    expect(report.droppedMessages).toBeGreaterThan(0);

    // The first user message must survive.
    const firstUser = messages.find((m) => m.role === "user");
    expect(firstUser).toBeDefined();
    expect((firstUser as UserMessage).content).toBe("q0");
  });

  it("never produces fewer than MIN_MESSAGES when budget is unachievable", () => {
    // Even with a 1k window and giant messages, we should bottom out
    // gracefully rather than infinite-loop or empty the transcript.
    const msgs: Message[] = [];
    for (let i = 0; i < 5; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(40), bloat(40)));
    }
    const { messages, report } = compactMessages(msgs, { contextWindow: 100 });
    expect(messages.length).toBeGreaterThanOrEqual(4);
    expect(report.tier).toBe(3);
  });
});

describe("compactMessages — invariants", () => {
  it("never breaks toolCall ↔ toolResult pairing across all tiers", () => {
    const msgs: Message[] = [];
    for (let i = 0; i < 15; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(10), `done ${i}`));
    }
    for (const cw of [200_000, 50_000, 10_000, 4_000, 2_000, 800]) {
      const { messages } = compactMessages(msgs, { contextWindow: cw });
      const calls = new Set<string>();
      const results = new Set<string>();
      for (const m of messages) {
        if (m.role === "assistant") {
          for (const b of m.content) {
            if (b.type === "toolCall") calls.add(b.id);
          }
        } else if (m.role === "toolResult") {
          results.add(m.toolCallId);
        }
      }
      // For every surviving toolCall there must be a matching result,
      // and vice versa.
      for (const id of calls) {
        expect(results.has(id)).toBe(true);
      }
      for (const id of results) {
        expect(calls.has(id)).toBe(true);
      }
    }
  });

  it("does not mutate the input array", () => {
    const msgs: Message[] = [];
    for (let i = 0; i < 8; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(8), `done ${i}`));
    }
    const snapshot = JSON.parse(JSON.stringify(msgs));
    compactMessages(msgs, { contextWindow: 2000 });
    expect(JSON.parse(JSON.stringify(msgs))).toEqual(snapshot);
  });
});

// ---- compactMessagesAsync (Tier 2.5 summarization) --------------------

describe("compactMessagesAsync — tier 2.5 (summarization)", () => {
  it("summarizes oldest turn-pair when elision wasn't enough", async () => {
    // Force Tier 2.5 by putting bulk in toolCall arguments — those are
    // NOT elided by tiers 1/2 (toolCall blocks are preserved so the
    // pairing stays valid). Only summarization (which replaces whole
    // turn-pairs) or Tier 3 (drop) can shrink them.
    const bigArgs = { command: bloat(4) };
    const pair = (i: number): Message[] => [
      u(`q${i}`),
      a("", {
        content: [
          { type: "toolCall", id: `id-${i}`, name: "bash", arguments: bigArgs },
        ],
      }),
      tr(`id-${i}`, "bash", "ok"),
      a(`done ${i}`),
    ];
    const oldPairs: Message[] = [];
    for (let i = 0; i < 6; i++) {
      oldPairs.push(...pair(i));
    }
    const recent: Message[] = [];
    for (let i = 0; i < 3; i++) {
      recent.push(u(`r${i}`), a(`small ${i}`));
    }
    const msgs = [...oldPairs, ...recent];

    const summarizer = async (_pair: Message[]) => "ok";
    const { messages, report } = await compactMessagesAsync(
      msgs,
      { contextWindow: 8000 },
      summarizer,
    );
    expect(report.tier).toBe(2.5);
    expect(report.summarizedTurnPairs).toBeGreaterThan(0);
    expect(report.droppedMessages).toBe(0);
    // First user message survives.
    expect((messages.find((m) => m.role === "user") as UserMessage).content)
      .toBe("q0");
    // Some synthetic summary message exists.
    const summaryMsg = messages.find(
      (m) =>
        m.role === "user" &&
        typeof m.content !== "string" &&
        Array.isArray(m.content) &&
        m.content.some(
          (b) => b.type === "text" && b.text.includes("[Earlier conversation summary]"),
        ),
    );
    expect(summaryMsg).toBeDefined();
  });

  it("falls back to Tier 3 when summarizer returns null", async () => {
    // Same toolCall-args bulk pattern so elision can't recover and Tier
    // 2.5 is the next stop. The summarizer bails → we end at Tier 3.
    const bigArgs = { command: bloat(4) };
    const pair = (i: number): Message[] => [
      u(`q${i}`),
      a("", {
        content: [
          { type: "toolCall", id: `id-${i}`, name: "bash", arguments: bigArgs },
        ],
      }),
      tr(`id-${i}`, "bash", "ok"),
      a(`done ${i}`),
    ];
    const msgs: Message[] = [];
    for (let i = 0; i < 6; i++) msgs.push(...pair(i));
    let calls = 0;
    const summarizer = async () => {
      calls++;
      return null;
    };
    const { report } = await compactMessagesAsync(
      msgs,
      { contextWindow: 8000 },
      summarizer,
    );
    expect(calls).toBeGreaterThan(0); // summarizer was at least asked
    expect(report.tier).toBe(3);
    expect(report.summarizedTurnPairs).toBe(0);
    expect(report.droppedMessages).toBeGreaterThan(0);
  });

  it("falls back to Tier 3 when summarizer throws", async () => {
    const bigArgs = { command: bloat(4) };
    const pair = (i: number): Message[] => [
      u(`q${i}`),
      a("", {
        content: [
          { type: "toolCall", id: `id-${i}`, name: "bash", arguments: bigArgs },
        ],
      }),
      tr(`id-${i}`, "bash", "ok"),
      a(`done ${i}`),
    ];
    const msgs: Message[] = [];
    for (let i = 0; i < 6; i++) msgs.push(...pair(i));
    const summarizer = async () => {
      throw new Error("network down");
    };
    const { report } = await compactMessagesAsync(
      msgs,
      { contextWindow: 8000 },
      summarizer,
    );
    expect(report.tier).toBe(3);
  });

  it("works without a summarizer (sync semantics)", async () => {
    const msgs: Message[] = [];
    for (let i = 0; i < 8; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(8), `done ${i}`));
    }
    const { report: syncReport } = compactMessages(msgs, { contextWindow: 3000 });
    const { report: asyncReport } = await compactMessagesAsync(
      msgs,
      { contextWindow: 3000 },
      undefined,
    );
    expect(asyncReport.tier).toBe(syncReport.tier);
    expect(asyncReport.afterMessages).toBe(syncReport.afterMessages);
  });

  it("nextTurnPairRange returns null when only two user messages exist", () => {
    const msgs: Message[] = [u("first"), a("reply"), u("second"), a("reply2")];
    expect(nextTurnPairRange(msgs)).toBeNull();
  });

  it("nextTurnPairRange points at the second user message span", () => {
    const msgs: Message[] = [
      u("first"),
      a("a1"),
      u("second"),
      a("a2"),
      u("third"),
      a("a3"),
    ];
    const r = nextTurnPairRange(msgs);
    expect(r).toEqual({ start: 2, end: 4 });
  });

  it("passes the abort signal through to the summarizer", async () => {
    const ctrl = new AbortController();
    const bigArgs = { command: bloat(4) };
    const pair = (i: number): Message[] => [
      u(`q${i}`),
      a("", {
        content: [
          { type: "toolCall", id: `id-${i}`, name: "bash", arguments: bigArgs },
        ],
      }),
      tr(`id-${i}`, "bash", "ok"),
      a(`done ${i}`),
    ];
    const msgs: Message[] = [];
    for (let i = 0; i < 6; i++) msgs.push(...pair(i));
    let observedSignal: AbortSignal | undefined;
    const summarizer = async (_pair: Message[], sig?: AbortSignal) => {
      observedSignal = sig;
      return "summary";
    };
    await compactMessagesAsync(
      msgs,
      { contextWindow: 8000 },
      summarizer,
      ctrl.signal,
    );
    expect(observedSignal).toBe(ctrl.signal);
  });
});

// ---- transformContext adapter -----------------------------------------

describe("makeTransformContext", () => {
  it("returns input unchanged when under budget (no callback fired)", async () => {
    let called = false;
    const xform = makeTransformContext(
      () => ({ contextWindow: 200_000 }),
      () => {
        called = true;
      },
    );
    const msgs: Message[] = [u("hi"), a("hello")];
    const out = await xform(msgs);
    expect(out).toBe(msgs);
    expect(called).toBe(false);
  });

  it("fires the callback with a report when compaction occurs", async () => {
    const reports: any[] = [];
    const xform = makeTransformContext(
      () => ({ contextWindow: 3000 }),
      (r) => reports.push(r),
    );
    const msgs: Message[] = [];
    for (let i = 0; i < 8; i++) {
      msgs.push(...turnPair(`q${i}`, `id-${i}`, bloat(8), `done ${i}`));
    }
    const out = await xform(msgs);
    expect(reports.length).toBe(1);
    expect(reports[0].tier).toBeGreaterThanOrEqual(1);
    expect(estimateTotalTokens(out as Message[])).toBeLessThanOrEqual(
      reports[0].budget,
    );
  });

  it("does not throw — falls back to input on getOptions failure", async () => {
    const xform = makeTransformContext(() => {
      throw new Error("boom");
    });
    const msgs: Message[] = [u("hi"), a("hello")];
    const out = await xform(msgs);
    expect(out).toBe(msgs);
  });

  it("passes through non-LLM messages without inspection", async () => {
    // Pretend there's a custom UI-only message mixed in. The compactor
    // should leave it alone and only touch real LLM messages.
    const custom = { role: "notification" as any, text: "ui only", timestamp: 0 };
    const msgs: any[] = [u("hi"), custom, a("hello")];
    const xform = makeTransformContext(() => ({ contextWindow: 200_000 }));
    const out = await xform(msgs);
    expect(out).toBe(msgs); // pass-through identity
  });
});
