// Context compaction for long-running agent sessions.
//
// pi-agent-core keeps the full transcript in memory and re-sends every prior
// message on every LLM call. With small-window local models (Ollama, LM
// Studio, etc.) this overflows the context window within a handful of tool-
// heavy turns — `read_file` / `bash` / `grep` results balloon fast. The
// agent's `transformContext` hook lets us pre-process the transcript before
// each call; this module is what we plug in there.
//
// Strategy: progressive degradation in three tiers, applied oldest-first
// while always preserving:
//   - the first user message (sets task context),
//   - the most recent KEEP_RECENT messages verbatim (short-term coherence),
//   - toolCall ↔ toolResult pairing (providers reject orphaned ids).
//
// We escalate only as far as needed to fit the budget:
//
//   Tier 1: Elide tool-result content in the "old" region. Tool results are
//           usually the dominant cost; eliding them alone often suffices.
//   Tier 2: Elide assistant text/thinking content in the old region too.
//           Tool-call blocks stay (still paired with their results).
//   Tier 3: Drop entire oldest turn-pairs (user → toolResults → assistant)
//           until the budget is met or only the minimum survives.
//
// We never *remove* messages in tiers 1/2 — we only mutate their `content`
// arrays. Tier 3 only drops whole turn-pair units so pairing stays intact.

import type {
  AssistantMessage,
  Message,
  ToolResultMessage,
  UserMessage,
} from "@mariozechner/pi-ai";

/** Conservative chars-per-token estimate. Real value varies by tokenizer
 *  (cl100k ≈ 3.6, llama3 ≈ 3.8, gpt-4o ≈ 3.5) — 4.0 is a safe upper bound
 *  used only when we have no real `usage.input` to anchor against. */
export const CHARS_PER_TOKEN = 4;

/** How many trailing messages are always kept verbatim. The model needs
 *  the most recent tool results in full to make progress on the current
 *  task; eliding them defeats the purpose. */
export const KEEP_RECENT = 6;

/** Fraction of the model's context window we aim to stay under. Leaves
 *  room for the next response (maxTokens), the system prompt, and a
 *  safety buffer for tokenizer drift. */
export const TARGET_FRACTION = 0.75;

/** Hard minimum number of messages to retain after Tier 3 drops. Below
 *  this we stop dropping and just let the call fail — better than
 *  shipping a transcript with no usable history. */
const MIN_MESSAGES = 4;

/**
 * Compaction tiers, in order of increasing aggression:
 *
 *   0 — no-op, transcript fits in budget.
 *   1 — old toolResult contents replaced with elision stubs.
 *   2 — old assistant text/thinking replaced with elision stubs.
 *   2.5 — oldest turn-pair(s) collapsed into a synthetic summary message
 *         via an LLM. Distinct from tier 3 because it preserves semantic
 *         content; failures fall through to tier 3.
 *   3 — oldest turn-pair(s) dropped entirely.
 *
 * Tier 2.5 is reported as `2.5` so the UI can distinguish it from a hard
 * drop. Encoded as a number rather than the enum-y string so JSON round-
 * trips cleanly through the event sink.
 */
export type CompactionTier = 0 | 1 | 2 | 2.5 | 3;

export type CompactionReport = {
  tier: CompactionTier;
  beforeTokens: number;
  afterTokens: number;
  beforeMessages: number;
  afterMessages: number;
  elidedToolResults: number;
  elidedAssistantBlocks: number;
  /** Turn-pairs that were summarized (Tier 2.5). */
  summarizedTurnPairs: number;
  /** Messages dropped wholesale (Tier 3). */
  droppedMessages: number;
  budget: number;
};

/**
 * Async LLM-based summarizer for Tier 2.5. Receives a contiguous slice of
 * messages (one full turn-pair: user → toolResults/assistants → up to but
 * not including the next user message) and must return a short prose
 * summary, or `null` to signal "give up, fall through to Tier 3".
 *
 * Contract: must not throw. Return `null` on any failure.
 */
export type Summarizer = (
  turnPair: Message[],
  signal?: AbortSignal,
) => Promise<string | null>;

export type CompactOptions = {
  /** Model context window in tokens. */
  contextWindow: number;
  /**
   * Real input-token count from the most recent `message_end` event. When
   * supplied this anchors our estimate against the provider's tokenizer
   * instead of relying on the chars/4 heuristic — much more accurate for
   * non-Latin scripts and tool-result JSON.
   */
  lastKnownInputTokens?: number;
  /**
   * Snapshot of the message array at the time `lastKnownInputTokens` was
   * observed. Used to compute a delta-from-anchor estimate for newly
   * appended messages. When omitted we fall back to pure char estimation.
   */
  lastKnownMessages?: Message[];
};

/** Estimate token cost of a single message via its serialized content. */
export function estimateMessageTokens(message: Message): number {
  let chars = 0;
  if (message.role === "user") {
    if (typeof message.content === "string") {
      chars += message.content.length;
    } else {
      for (const block of message.content) {
        if (block.type === "text") chars += block.text.length;
        else if (block.type === "image") chars += 1500; // rough image token cost
      }
    }
  } else if (message.role === "assistant") {
    for (const block of message.content) {
      if (block.type === "text") chars += block.text.length;
      else if (block.type === "thinking") chars += block.thinking.length;
      else if (block.type === "toolCall") {
        chars += block.name.length;
        chars += JSON.stringify(block.arguments ?? {}).length;
      }
    }
  } else if (message.role === "toolResult") {
    chars += message.toolName.length;
    for (const block of message.content) {
      if (block.type === "text") chars += block.text.length;
      else if (block.type === "image") chars += 1500;
    }
  }
  // +20 char overhead per message for role/structure framing.
  return Math.ceil((chars + 20) / CHARS_PER_TOKEN);
}

export function estimateTotalTokens(messages: Message[]): number {
  let total = 0;
  for (const m of messages) total += estimateMessageTokens(m);
  return total;
}

/**
 * Best-available token estimate.
 *
 * When the caller passes `lastKnownInputTokens` and `lastKnownMessages`,
 * we anchor against the provider-reported count and add a chars/4
 * estimate for whatever has been appended since. This is materially
 * more accurate than estimating the whole transcript from scratch.
 */
export function estimateTokensWithAnchor(
  messages: Message[],
  opts: CompactOptions,
): number {
  if (
    opts.lastKnownInputTokens !== undefined &&
    opts.lastKnownMessages !== undefined &&
    opts.lastKnownMessages.length <= messages.length
  ) {
    // The agent transcript is append-only: messages[0..anchorLen-1] must
    // match the anchor. We trust that and only estimate the tail.
    const anchorLen = opts.lastKnownMessages.length;
    let tail = 0;
    for (let i = anchorLen; i < messages.length; i++) {
      tail += estimateMessageTokens(messages[i]!);
    }
    return opts.lastKnownInputTokens + tail;
  }
  return estimateTotalTokens(messages);
}

/** True for any AgentMessage we recognize as a standard LLM Message. */
function isLLMMessage(m: any): m is Message {
  return (
    m &&
    (m.role === "user" || m.role === "assistant" || m.role === "toolResult")
  );
}

/** Indices of user messages — used to find turn-pair boundaries. */
function userMessageIndices(messages: Message[]): number[] {
  const out: number[] = [];
  for (let i = 0; i < messages.length; i++) {
    if (messages[i]!.role === "user") out.push(i);
  }
  return out;
}

/**
 * Compute the "old region" boundary: indices [0, oldEnd) are eligible for
 * elision/dropping. Anything from oldEnd onward is sticky-recent.
 *
 * Rule: keep at least KEEP_RECENT trailing messages, but always cut on a
 * user-message boundary so a toolCall and its matching toolResult stay on
 * the same side of the line.
 */
function computeOldRegionEnd(messages: Message[]): number {
  if (messages.length <= KEEP_RECENT) return 0;
  const candidateCut = messages.length - KEEP_RECENT;
  // Walk backwards from candidateCut to the previous user message — we
  // want oldEnd to land on a user-message index so the recent region
  // starts with a complete turn.
  for (let i = candidateCut; i < messages.length; i++) {
    if (messages[i]!.role === "user") return i;
  }
  return candidateCut;
}

function elidedToolResult(message: ToolResultMessage): ToolResultMessage {
  // Preserve toolCallId / toolName / isError so the model still has a
  // coherent record of "this tool was called and produced something" —
  // only the bulky content gets shrunk.
  const originalBytes = JSON.stringify(message.content).length;
  return {
    ...message,
    content: [
      {
        type: "text",
        text: `[elided: ${message.toolName} result, ${originalBytes} bytes; full output dropped by context compaction]`,
      },
    ],
    details: undefined,
  };
}

function elidedAssistant(message: AssistantMessage): AssistantMessage {
  // Keep tool-call blocks (their ids are still referenced by following
  // toolResult messages, and most providers reject an assistant message
  // with zero content blocks). Replace text/thinking with a short stub.
  const newContent = message.content
    .map((block) => {
      if (block.type === "text") {
        return {
          type: "text" as const,
          text: `[elided: ${block.text.length} chars of assistant text]`,
        };
      }
      if (block.type === "thinking") {
        return {
          type: "text" as const,
          text: `[elided: ${block.thinking.length} chars of thinking]`,
        };
      }
      return block; // toolCall preserved verbatim
    })
    // Collapse consecutive elision stubs into one so we don't pay the
    // structure overhead for every elided block.
    .reduce<typeof message.content>((acc, block) => {
      const prev = acc[acc.length - 1];
      if (
        prev &&
        prev.type === "text" &&
        block.type === "text" &&
        prev.text.startsWith("[elided:") &&
        block.text.startsWith("[elided:")
      ) {
        return acc;
      }
      acc.push(block);
      return acc;
    }, []);
  return { ...message, content: newContent };
}

/**
 * Drop the oldest dropable turn-pair from `messages` and return the new
 * array. A turn-pair is `user → ...toolResults/assistants... → (next user)`.
 *
 * Rules:
 *   - The *first* user message is never dropped (it sets task context).
 *   - We drop entire user-to-next-user spans so toolCall/toolResult pairs
 *     are never split.
 *   - If the only droppable turn-pair would leave fewer than MIN_MESSAGES,
 *     we return `messages` unchanged.
 */
function dropOldestTurnPair(messages: Message[]): {
  messages: Message[];
  dropped: number;
} {
  const userIdx = userMessageIndices(messages);
  // Need at least 3 user messages so we can drop user #2's pair (between
  // userIdx[1] and userIdx[2]) while keeping the original task and the
  // current pair intact.
  if (userIdx.length < 3) return { messages, dropped: 0 };
  const dropStart = userIdx[1]!;
  const dropEnd = userIdx[2]!; // exclusive
  const dropped = dropEnd - dropStart;
  const next = [...messages.slice(0, dropStart), ...messages.slice(dropEnd)];
  if (next.length < MIN_MESSAGES) return { messages, dropped: 0 };
  return { messages: next, dropped };
}

/**
 * Apply Tier 1: elide tool-result content in the old region.
 * Returns the new array and the number of toolResults elided.
 */
function applyTier1(
  messages: Message[],
  oldEnd: number,
): { messages: Message[]; elided: number } {
  let elided = 0;
  const next = messages.map((m, i) => {
    if (i >= oldEnd) return m;
    if (m.role !== "toolResult") return m;
    // Skip already-elided ones (idempotent).
    if (
      m.content.length === 1 &&
      m.content[0]!.type === "text" &&
      m.content[0]!.text.startsWith("[elided:")
    ) {
      return m;
    }
    elided++;
    return elidedToolResult(m);
  });
  return { messages: next, elided };
}

/**
 * Apply Tier 2: elide assistant text/thinking in the old region.
 */
function applyTier2(
  messages: Message[],
  oldEnd: number,
): { messages: Message[]; elided: number } {
  let elided = 0;
  const next = messages.map((m, i) => {
    if (i >= oldEnd) return m;
    if (m.role !== "assistant") return m;
    const hasProse = m.content.some(
      (b) =>
        (b.type === "text" && !b.text.startsWith("[elided:")) ||
        b.type === "thinking",
    );
    if (!hasProse) return m;
    elided++;
    return elidedAssistant(m);
  });
  return { messages: next, elided };
}

/**
 * Compute the [start, end) range of the second-oldest turn-pair —
 * the next one Tier 2.5 / Tier 3 would compact away. Returns null when
 * nothing is droppable (fewer than 3 user messages).
 */
export function nextTurnPairRange(messages: Message[]): {
  start: number;
  end: number;
} | null {
  const userIdx = userMessageIndices(messages);
  if (userIdx.length < 3) return null;
  return { start: userIdx[1]!, end: userIdx[2]! };
}

/**
 * Replace the slice [start, end) in `messages` with a single synthetic
 * user message carrying `summary`. Used by Tier 2.5 to collapse a
 * summarized turn-pair into one message. The synthetic message is tagged
 * with role "user" rather than "assistant" because most providers
 * tolerate user messages in arbitrary positions and reject out-of-order
 * assistant ones (no preceding user turn, double-assistant, etc.).
 */
function spliceSummary(
  messages: Message[],
  start: number,
  end: number,
  summary: string,
): Message[] {
  const synthetic: UserMessage = {
    role: "user",
    content: [
      {
        type: "text",
        text: `[Earlier conversation summary] ${summary}`,
      },
    ],
    timestamp: Date.now(),
  };
  return [...messages.slice(0, start), synthetic, ...messages.slice(end)];
}

function emptyReport(
  beforeTokens: number,
  beforeMessages: number,
  budget: number,
): CompactionReport {
  return {
    tier: 0,
    beforeTokens,
    afterTokens: beforeTokens,
    beforeMessages,
    afterMessages: beforeMessages,
    elidedToolResults: 0,
    elidedAssistantBlocks: 0,
    summarizedTurnPairs: 0,
    droppedMessages: 0,
    budget,
  };
}

/**
 * Synchronous compaction. Applies tiers 1 → 2 → 3 only — Tier 2.5 needs
 * a network call to summarize and is only available via
 * `compactMessagesAsync`. Pure function — does not touch the input array.
 */
export function compactMessages(
  input: Message[],
  opts: CompactOptions,
): { messages: Message[]; report: CompactionReport } {
  const budget = Math.max(
    1024,
    Math.floor(opts.contextWindow * TARGET_FRACTION),
  );
  const beforeTokens = estimateTokensWithAnchor(input, opts);
  const beforeMessages = input.length;

  if (beforeTokens <= budget) {
    return {
      messages: input,
      report: emptyReport(beforeTokens, beforeMessages, budget),
    };
  }

  const state: CompactionState = {
    messages: input,
    tier: 0,
    elidedToolResults: 0,
    elidedAssistantBlocks: 0,
    summarizedTurnPairs: 0,
    droppedMessages: 0,
    budget,
  };

  applyElisionTiers(state);
  if (estimateTotalTokens(state.messages) <= budget) {
    return finishReport(state, beforeTokens, beforeMessages);
  }

  applyTier3DropLoop(state);
  return finishReport(state, beforeTokens, beforeMessages);
}

/**
 * Async compaction. Same as `compactMessages` but inserts Tier 2.5
 * (LLM summarization of oldest turn-pair) between Tier 2 and Tier 3.
 *
 * Contract: never throws; on summarizer failure, falls back to Tier 3.
 */
export async function compactMessagesAsync(
  input: Message[],
  opts: CompactOptions,
  summarizer: Summarizer | undefined,
  signal?: AbortSignal,
): Promise<{ messages: Message[]; report: CompactionReport }> {
  const budget = Math.max(
    1024,
    Math.floor(opts.contextWindow * TARGET_FRACTION),
  );
  const beforeTokens = estimateTokensWithAnchor(input, opts);
  const beforeMessages = input.length;

  if (beforeTokens <= budget) {
    return {
      messages: input,
      report: emptyReport(beforeTokens, beforeMessages, budget),
    };
  }

  const state: CompactionState = {
    messages: input,
    tier: 0,
    elidedToolResults: 0,
    elidedAssistantBlocks: 0,
    summarizedTurnPairs: 0,
    droppedMessages: 0,
    budget,
  };

  applyElisionTiers(state);
  if (estimateTotalTokens(state.messages) <= budget) {
    return finishReport(state, beforeTokens, beforeMessages);
  }

  // Tier 2.5: try to summarize oldest turn-pairs one at a time. Bail to
  // Tier 3 if the summarizer returns null or throws.
  if (summarizer) {
    for (let i = 0; i < 20; i++) {
      const range = nextTurnPairRange(state.messages);
      if (!range) break;
      const slice = state.messages.slice(range.start, range.end);
      let summary: string | null = null;
      try {
        summary = await summarizer(slice, signal);
      } catch {
        summary = null;
      }
      if (!summary || !summary.trim()) {
        // Summarizer gave up — fall through to Tier 3.
        break;
      }
      state.messages = spliceSummary(
        state.messages,
        range.start,
        range.end,
        summary.trim(),
      );
      state.summarizedTurnPairs++;
      state.tier = 2.5;
      // Re-apply elision in case the new shorter messages exposed older
      // ones to the "old region".
      applyElisionTiers(state);
      if (estimateTotalTokens(state.messages) <= budget) {
        return finishReport(state, beforeTokens, beforeMessages);
      }
    }
  }

  // Tier 3 fallback: hard drops.
  applyTier3DropLoop(state);
  return finishReport(state, beforeTokens, beforeMessages);
}

/** Shared mutable state used by both sync and async compaction paths. */
type CompactionState = {
  messages: Message[];
  tier: CompactionTier;
  elidedToolResults: number;
  elidedAssistantBlocks: number;
  summarizedTurnPairs: number;
  droppedMessages: number;
  budget: number;
};

function applyElisionTiers(state: CompactionState): void {
  // Tier 1.
  {
    const oldEnd = computeOldRegionEnd(state.messages);
    if (oldEnd > 0) {
      const r = applyTier1(state.messages, oldEnd);
      state.messages = r.messages;
      if (r.elided > 0) {
        state.elidedToolResults += r.elided;
        if (state.tier < 1) state.tier = 1;
      }
    }
  }
  if (estimateTotalTokens(state.messages) <= state.budget) return;

  // Tier 2.
  {
    const oldEnd = computeOldRegionEnd(state.messages);
    if (oldEnd > 0) {
      const r = applyTier2(state.messages, oldEnd);
      state.messages = r.messages;
      if (r.elided > 0) {
        state.elidedAssistantBlocks += r.elided;
        if (state.tier < 2) state.tier = 2;
      }
    }
  }
}

function applyTier3DropLoop(state: CompactionState): void {
  state.tier = 3;
  for (let i = 0; i < 100; i++) {
    const r = dropOldestTurnPair(state.messages);
    if (r.dropped === 0) break;
    state.messages = r.messages;
    state.droppedMessages += r.dropped;
    // Re-elide newly-exposed old region.
    const oldEnd = computeOldRegionEnd(state.messages);
    if (oldEnd > 0) {
      const r1 = applyTier1(state.messages, oldEnd);
      state.messages = r1.messages;
      state.elidedToolResults += r1.elided;
      const r2 = applyTier2(state.messages, oldEnd);
      state.messages = r2.messages;
      state.elidedAssistantBlocks += r2.elided;
    }
    if (estimateTotalTokens(state.messages) <= state.budget) break;
  }
}

function finishReport(
  state: CompactionState,
  beforeTokens: number,
  beforeMessages: number,
): { messages: Message[]; report: CompactionReport } {
  return {
    messages: state.messages,
    report: {
      tier: state.tier,
      beforeTokens,
      afterTokens: estimateTotalTokens(state.messages),
      beforeMessages,
      afterMessages: state.messages.length,
      elidedToolResults: state.elidedToolResults,
      elidedAssistantBlocks: state.elidedAssistantBlocks,
      summarizedTurnPairs: state.summarizedTurnPairs,
      droppedMessages: state.droppedMessages,
      budget: state.budget,
    },
  };
}

/**
 * Adapter for use as pi-agent-core's `transformContext`. Wraps
 * `compactMessages` and:
 *
 *  - Filters non-LLM AgentMessages through to the caller's
 *    `convertToLlm` pipeline unchanged (we only compact things we
 *    actually understand as LLM messages).
 *  - Catches any throw and returns the original input. The
 *    transformContext contract is "must not throw" — falling back to
 *    no-compaction is strictly safer than corrupting the run.
 */
export function makeTransformContext(
  getOptions: () => CompactOptions,
  onCompact?: (report: CompactionReport) => void,
  summarizer?: Summarizer,
): (messages: any[], signal?: AbortSignal) => Promise<any[]> {
  return async (messages: any[], signal?: AbortSignal) => {
    try {
      const llmIdxs: number[] = [];
      const llmMessages: Message[] = [];
      for (let i = 0; i < messages.length; i++) {
        if (isLLMMessage(messages[i])) {
          llmIdxs.push(i);
          llmMessages.push(messages[i] as Message);
        }
      }
      if (llmMessages.length === 0) return messages;
      const opts = getOptions();
      const { messages: compacted, report } = summarizer
        ? await compactMessagesAsync(llmMessages, opts, summarizer, signal)
        : compactMessages(llmMessages, opts);
      if (report.tier === 0) return messages;
      onCompact?.(report);
      // Splice the compacted LLM messages back into the original array,
      // preserving any non-LLM custom messages at their original
      // positions. (pi-agent-core supports custom message types via the
      // CustomAgentMessages declaration-merging hook; we don't use them
      // today, but this keeps the door open.)
      //
      // If compaction dropped messages we also drop the corresponding
      // slots from the host array. We map index-by-index and only emit
      // the LLM slots that survived.
      const out: any[] = [];
      let llmCursor = 0;
      const llmIdxSet = new Set(llmIdxs);
      const droppedFromStart = llmMessages.length - compacted.length;
      // Heuristic: when Tier 3 drops, it removes a contiguous span starting
      // at userIdx[1]. We can't perfectly recover the original positions
      // for arbitrary CustomAgentMessages interleaved with the dropped
      // span; the safe move is to keep custom messages in place and emit
      // surviving LLM messages in order at their original LLM slot
      // positions, skipping LLM slots until we've absorbed the
      // droppedFromStart count.
      let toSkip = droppedFromStart;
      for (let i = 0; i < messages.length; i++) {
        if (!llmIdxSet.has(i)) {
          out.push(messages[i]);
          continue;
        }
        if (toSkip > 0) {
          toSkip--;
          // skip this LLM slot — corresponds to a dropped message
          continue;
        }
        out.push(compacted[llmCursor++]);
      }
      // Any unconsumed compacted entries (shouldn't happen given the
      // accounting above, but be defensive) get appended.
      while (llmCursor < compacted.length) out.push(compacted[llmCursor++]);
      return out;
    } catch {
      // Contract says we must not throw. Fall back to no-op.
      return messages;
    }
  };
}
