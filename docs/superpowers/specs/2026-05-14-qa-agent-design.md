# QA agent (secondary review pass)

**Status:** spec
**Date:** 2026-05-14

## Goal

Let a workspace opt in to having a **second agent** — typically a stronger
cloud model — review the **primary agent's** work after the user judges it
"ready." Two motivating shapes:

1. *Local build, cloud QA.* The user runs Qwen in LM Studio (cheap, private,
   slow) as the primary agent. When it claims to be done, a Claude Sonnet QA
   agent reads the diff and the transcript and reports issues. The user
   triages from there.
2. *Cheap build, expensive review.* Same shape, different models — e.g. a
   smaller OpenRouter model for grinding tool calls, a flagship model for the
   final sanity check.

The QA agent runs **in the same worktree** so it sees the live files the
primary agent wrote, and **in the same transcript** so the review lands where
the user is already looking.

## Non-goals

- **Auto-trigger on every `agent_end`.** That fires after every turn,
  including clarifying questions and timeouts. Wrong signal. See *Triggering*
  below.
- **Per-tool turn counting / "stuck detection."** That's the sibling
  *big-bro-assist* feature (deferred — see §11). This spec is about
  post-completion review only.
- **QA-fixes-it-itself loops.** The QA agent is read-only by default. It
  reports findings; the user (or another build-pass) acts on them. Avoiding a
  fix-loop keeps the cost ceiling predictable and the conversation linear.
- **iOS UI in v1.** iOS already shows the transcript; QA findings will appear
  there for free. iOS-initiated "Run QA" can come later.
- **Per-workspace cost tracking / budgets.** Out of scope; the
  user already controls cost by choosing the QA model.

## Design

### 1. The conceptual model

A workspace now has **two** notional agent roles, both optional in a sense:

| Role     | Required | Provider/model            | Tools             | System prompt mode |
|----------|----------|---------------------------|-------------------|--------------------|
| primary  | yes      | `providerId` / `modelId`  | full              | `build`            |
| qa       | no       | `qaProviderId` / `qaModelId` | read-only + `post_qa_findings` | `qa`        |

The primary role is exactly what exists today. The QA role is new, optional,
and only instantiated when the user actually runs a QA pass. We do **not**
create a long-lived `AgentSession` for QA up front — it's spun up on demand
(see §4) so workspaces that never run QA pay zero overhead.

`secondary` rather than `qa` is tempting at the schema level so the same
fields can host *big bro assist* (§11) later. We deliberately use the explicit
`qa` name for now — it matches the UI label and keeps the v1 mental model
crisp. If/when big bro lands, it gets its own fields rather than overloading
these.

### 2. Schema (migration v7)

Append to `Sources/MultiharnessCore/Persistence/Migrations.swift`:

```sql
ALTER TABLE projects   ADD COLUMN default_qa_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE projects   ADD COLUMN default_qa_provider_id TEXT;
ALTER TABLE projects   ADD COLUMN default_qa_model_id TEXT;

ALTER TABLE workspaces ADD COLUMN qa_enabled INTEGER;     -- nullable: inherit
ALTER TABLE workspaces ADD COLUMN qa_provider_id TEXT;
ALTER TABLE workspaces ADD COLUMN qa_model_id TEXT;
```

Inheritance — explicit opt-in/opt-out with project default as the
fallback for both the toggle and the model pick:

```
effectiveQaEnabled = workspace.qaEnabled ?? project.defaultQaEnabled
prefilledProvider  = workspace.qaProviderId ?? project.defaultQaProviderId
prefilledModel     = workspace.qaModelId    ?? project.defaultQaModelId
```

Three points worth being explicit about:

- **`qa_enabled` is nullable on `workspaces`.** NULL means "use the
  project default." Non-NULL is an explicit user-level decision (either
  "yes, override the project's off → on" or "yes, override the project's
  on → off"). The UI exposes a "Use project default" affordance that
  resets the column back to NULL.
- **Project default off + workspace explicit on** is a real, supported
  state. The user can opt-in a single workspace without flipping the
  whole project.
- **Project default on + workspace explicit off** is also a real,
  supported state. The user can opt-out a workspace they don't want QA on
  even if the project enables it broadly.

Model picks (`qa_provider_id`, `qa_model_id`) are independent of the
enabled toggle — a project can have a default model configured even
when its default is "off" (so when a user opts a workspace in, there's
still a sensible pre-fill). Toggling QA off does **not** clear the
model picks; they persist for the next opt-in.

### 3. Wire model

Add three optional fields to `Project` and `Workspace` in
`Sources/MultiharnessClient/Models/Models.swift`:

```swift
// Project
public var defaultQaEnabled: Bool          // false unless set
public var defaultQaProviderId: UUID?
public var defaultQaModelId: String?

// Workspace
public var qaEnabled: Bool?                // nil = unset
public var qaProviderId: UUID?
public var qaModelId: String?
```

Helpers on `Workspace`:

```swift
/// Resolves the effective QA-enabled flag using
/// `workspace.qaEnabled ?? project.defaultQaEnabled`.
public func effectiveQaEnabled(in project: Project) -> Bool {
    qaEnabled ?? project.defaultQaEnabled
}

/// Returns the (provider, model) pair the QA popover should pre-select
/// when opened. Falls back to project defaults when the workspace
/// hasn't recorded its own picks yet.
public func qaPopoverInitialSelection(in project: Project) -> (UUID?, String?) {
    (
      qaProviderId ?? project.defaultQaProviderId,
      qaModelId    ?? project.defaultQaModelId
    )
}

/// True iff the workspace has an explicit override (either direction)
/// for the enabled flag. Used by the popover to surface a "Use project
/// default" button only when it would actually do something.
public func qaEnabledIsOverridden(in project: Project) -> Bool {
    qaEnabled != nil
}
```

There's no `QaConfig` struct — the fields are flat on the models, mirroring
how `buildMode` already lives flat on `Workspace` / `Project` rather than
in a nested config struct.

### 4. The QA session lifecycle

Adding a long-lived second `AgentSession` per workspace would force
`AgentRegistry`'s shape to change (`Map<workspaceId, {build, qa?}>`) and
complicate every existing call site. Instead:

**QA is a transient, single-prompt agent.** When the user clicks "Run QA,"
the sidecar:

1. Resolves the QA provider config the same way `agent.create` resolves the
   primary one (Keychain lookup happens on the Mac side; the resolved
   `providerConfig` is sent over the wire).
2. Constructs a **fresh `AgentSession`** with:
   - `workspaceId` — the same workspace.
   - `worktreePath` — the same path. The QA agent reads the same files.
   - `providerConfig` — the QA one.
   - **Tool set** — read-only subset (`read_file`, `list_dir`, `glob`,
     `grep`, plus a non-mutating `bash` that runs in a "no side effects"
     mode — but a strict tool whitelist is simpler and easier to enforce;
     see §6) plus a new `post_qa_findings` tool.
   - **System prompt mode** — `qa` (new; see §5).
   - **JSONL writer** — the same `messages.jsonl`. Events from the QA run
     land in the same log.
   - `nameSource: "named"` — no AI rename, this isn't a build pass.
3. Prompts it once with a constructed message (see §5).
4. On `agent_end` for this session, disposes it.

This means **`AgentRegistry` does not learn about QA sessions at all.** A
new `QaRunner` class in the sidecar owns the lifecycle:

```ts
// sidecar/src/qaRunner.ts
export class QaRunner {
  constructor(
    private readonly dataDir: string,
    private readonly sink: EventSink,
    private readonly oauthStore?: OAuthStore,
  ) {}

  async run(opts: QaRunOptions): Promise<void> {
    const session = new AgentSession({
      ...opts,
      jsonlPath: join(this.dataDir, "workspaces", opts.workspaceId, "messages.jsonl"),
      sink: this.sink,
      nameSource: "named",
      // tool set + system-prompt mode hooked in via new AgentSessionOptions
      // fields (see §6).
    });
    try {
      await session.prompt(opts.qaPromptText);
    } finally {
      await session.dispose();
    }
  }
}
```

**Why same `JsonlWriter` path is safe:** the writer appends; both sessions
serialize through the file system. The risk is interleaved events if the
primary agent is still streaming when QA starts — which we prevent by gating
the Run QA button on `!isStreaming`. The agent is "between turns" by
definition when QA can start, so concurrent writes don't happen.

**Why we don't simply reuse the existing `AgentSession`'s `Agent` with a
swapped system prompt + tool set:** pi-agent-core's `Agent` retains
conversation state. Reusing it would either (a) leak the build transcript
into the QA model's context as if it were "what we just discussed,"
producing weird role confusion, or (b) require a reset method on the Agent
that doesn't exist. A fresh `AgentSession` is the smaller change.

### 5. The QA system prompt + first message

Add a new build-mode-ish enum to `sidecar/src/prompts.ts`:

```ts
export type SessionMode = "build" | "qa";
```

`buildSystemPrompt(mode: BuildMode)` already exists; add a sibling
`buildQaSystemPrompt()` that produces something like:

```
You are a QA reviewer. The primary coding agent just finished work on
the user's task. Your job:

1. Read the diff vs the base branch.
2. Spot bugs, missing edge cases, broken tests, or anything the
   primary agent claimed but didn't actually do.
3. Run tests if a test runner is obvious from the project layout.
4. Call the `post_qa_findings` tool with your verdict
   (pass / minor_issues / blocking_issues) and a short report.

You are READ-ONLY. Do not edit files. Do not commit. Do not push.
Use only the inspection tools provided.
```

The composed system prompt is `<qa system prompt> + <orientation block>`.
The `<project_instructions>` and `<workspace_instructions>` blocks are
**deliberately omitted** from QA — those are build-time guidance ("use these
patterns when implementing X") and feeding them to the reviewer creates a
self-confirming loop where the reviewer rubber-stamps anything that follows
the instructions, even when the instructions themselves were wrong.

The **first message** the Mac sends to the QA agent is built locally and
contains everything the QA agent needs without having to dig:

```
The primary agent just finished work in this workspace.

Branch: <branchName>
Base:   <baseBranch>

Most recent user request:
<the last user prompt>

Primary agent's final summary (its last assistant turn):
<the last assistant message's text>

Diff vs <baseBranch>:
<output of `git diff <baseBranch>...HEAD` truncated to ~50k chars>

Please review.
```

Diff truncation: cap at ~50k characters; if the diff is larger we include
the file list + first 50k chars + a note that more was truncated, and the QA
agent can pull more via `read_file`. The build-pass produced a smallish
change in the median case; huge diffs are the exception, and even then a
50k-char window is enough to find structural issues.

### 6. Read-only tool whitelist

The build-mode tool list is constructed in `sidecar/src/tools/index.ts` via
`buildTools(worktreePath)`. Add a sibling `buildReadOnlyTools(worktreePath)`
that returns only:

- `read_file`
- `list_dir`
- `glob`
- `grep`
- A constrained `bash` that runs commands but is documented in its
  description as "for running tests and read-only inspection — do not write
  files, commit, push, or modify the working tree." We don't enforce this at
  the tool layer in v1; relying on the system prompt + the QA description is
  enough because:
  - The QA agent is short-lived (one prompt, ends with `post_qa_findings`).
  - Any damage is bounded to the worktree, which already has a primary
    agent making real changes — adding a guard against the QA agent
    misbehaving is lower priority than other things.
  - Strict sandboxing is a follow-up if it becomes a problem in practice.
- `post_qa_findings` — new tool whose definition is:

```ts
{
  name: "post_qa_findings",
  description: "Call exactly once when your review is complete. After this, stop.",
  inputSchema: {
    type: "object",
    required: ["verdict", "summary"],
    properties: {
      verdict: { enum: ["pass", "minor_issues", "blocking_issues"] },
      summary: { type: "string", description: "1-3 paragraph plain-text summary." },
      findings: {
        type: "array",
        items: {
          type: "object",
          required: ["severity", "message"],
          properties: {
            severity: { enum: ["info", "warning", "blocker"] },
            file:     { type: "string" },
            line:     { type: "integer" },
            message:  { type: "string" },
          },
        },
      },
    },
  },
}
```

The tool's implementation **emits a synthetic event** so the UI can render
the findings as a structured card (see §8) rather than the user having to
read through them in a tool-result blob:

```ts
emit({
  type: "qa_findings",
  workspaceId,
  verdict,
  summary,
  findings,
});
```

…and returns `{ ok: true }` so the agent stops cleanly.

`AgentSessionOptions` grows two optional fields:

```ts
toolsOverride?: ReturnType<typeof buildTools>;
systemPromptMode?: "build" | "qa";
```

When `systemPromptMode === "qa"`, `composeSystemPrompt()` uses
`buildQaSystemPrompt()` instead of `buildSystemPrompt(buildMode)` and skips
the `<project_instructions>` / `<workspace_instructions>` blocks.

### 7. RPC: `qa.run`

Register in `sidecar/src/methods.ts`:

```ts
d.register("qa.run", async (p) => {
  const workspaceId = requireString(p, "workspaceId");
  const providerConfig = p.providerConfig as ProviderConfig | undefined;
  if (!providerConfig || typeof providerConfig !== "object") {
    throw new Error("providerConfig must be an object");
  }
  const firstMessage = requireString(p, "firstMessage");
  // Pull worktree path / project / branch info from the existing
  // primary session so we don't need the Mac to send them again. If
  // there's no primary session (e.g. workspace was never opened this
  // session) reject — the caller should agent.create first.
  if (!registry.has(workspaceId)) {
    throw new Error(`no primary session for workspace ${workspaceId}`);
  }
  const primary = registry.get(workspaceId);
  qaRunner.run({
    workspaceId,
    projectId: primary.projectId,
    worktreePath: primary.worktreePath,    // new public getter
    providerConfig,
    qaPromptText: firstMessage,
    oauthStore,
  }).catch((err) => {
    const reason = err instanceof Error ? err.message : String(err);
    log.error("qa.run failed", { workspaceId, err: reason });
    registry.emitError(workspaceId, reason);
  });
  return { ok: true };
});
```

Returns immediately; events stream as the QA agent runs. The `agent_start`
event for the QA run carries an extra `kind: "qa"` field (new) so the Mac
UI can render its conversation group with a distinct header.

To plumb `kind`, `AgentSession.handle()` injects it on `agent_start` events
when `opts.systemPromptMode === "qa"`. Doing it inside `AgentSession` keeps
the QA-specific knowledge out of `AgentRegistry` and out of `methods.ts`.

### 8. Mac UI

#### 8a. Workspace detail view: QA control

The QA control lives **right next to the existing model selector** above
the input field — same row, same dropdown style. Today's composer header
is (`WorkspaceDetailView.Composer`):

```
[ provider · model ▾ ]                                      [ Streaming… ]
```

After this feature:

```
[ provider · model ▾ ]   [ 🔍 QA · … ▾ ]                    [ Streaming… ]
```

The QA control is **always present** when the workspace exists, even if
QA is opted out — the button doubles as the discoverability entry point
for turning QA on. Its label reflects the current effective state:

| Effective state                                           | Label                                | Style                  |
|-----------------------------------------------------------|--------------------------------------|------------------------|
| `effectiveQaEnabled == false`                             | `🔍 QA off ▾`                        | muted secondary        |
| Enabled, no model configured at workspace or project      | `🔍 QA: pick a model ▾`              | normal secondary       |
| Enabled, model resolvable from workspace+project fallback | `🔍 QA · <provider> · <model> ▾`     | normal secondary       |
| QA run currently streaming                                | `🔍 QA running…` + small `ProgressView` | disabled            |

Clicking the button opens a `QaSwitcher` popover. Workspace archived →
button hidden (matches how the composer hides other controls in archived
workspaces).

**The popover (`QaSwitcher`):**

Modeled on the existing `ModelSwitcher` but with three sections:

1. **Header toggle row.**

   ```
   QA review for this workspace                       [ Toggle ]
   Project default: on  ·  [Use project default]
   ```

   The toggle binds to a local `@State enabled: Bool` initialized to
   `workspace.effectiveQaEnabled(in: project)`. Below the toggle, a
   small caption tells the user the project default ("on" / "off") so
   they understand what their override is overriding.

   "Use project default" button appears only when
   `workspace.qaEnabledIsOverridden(in:)` is true; clicking it clears
   `workspace.qaEnabled` (sets to NULL) and re-reads the inherited
   value to re-initialize the toggle.

2. **Provider + model pickers** (always visible, but the **Run QA**
   button at the bottom is disabled when the toggle is off). Same
   `Provider` picker + `ModelPicker` controls as `ModelSwitcher`.

   This layout lets the user configure a model *before* enabling QA if
   they want to set things up without firing a run yet. Conversely,
   they can enable the toggle and pick a model in the same popover
   visit.

3. **Bottom action row:**
   - **Cancel** — closes the popover, applies no changes.
   - **Save** — persists the toggle state + model picks (writes
     `qaEnabled`, `qaProviderId`, `qaModelId` to the workspace).
     Available whenever any field has changed from its initial value.
   - **Run QA** (`.borderedProminent`, default action) — saves *and*
     kicks off a QA run. Disabled when:
     - Toggle is off, OR
     - No model is selected, OR
     - Primary agent or QA is currently streaming.

The split between "Save" and "Run QA" matters because the user might
want to toggle QA off (an explicit override) without running anything.
Without a "Save" button, the only way to persist a toggle change would
be to also run QA, which is wrong.

**The "Run QA" action:**

1. Persists the popover's state to the workspace: writes `qaEnabled`,
   `qaProviderId`, `qaModelId`.
2. Resolves the picked provider's `providerConfig` (Keychain lookup,
   same path as the primary model switcher uses).
3. Builds the QA first message locally (diff + last turns — see §9).
4. Calls `qa.run` over the control client.
5. Sets `workspace.lifecycleState = .inReview` if it was `.inProgress`.
6. Closes the popover.

**Enable/disable rules for the composer's QA button itself** (not the
"Run QA" button *inside* the popover):

| Condition                                | Button state                                  |
|------------------------------------------|-----------------------------------------------|
| Workspace archived                       | Hidden                                        |
| QA currently running                     | Disabled, label "🔍 QA running…"              |
| Primary agent streaming (and QA enabled) | **Enabled** — user can configure but Run QA inside is disabled |
| Otherwise                                | Enabled                                       |

The composer button stays clickable during primary streaming because
opening the popover to *configure* QA shouldn't be blocked by the
primary running; only the actual *Run QA* action inside the popover
gates on idle.

#### 8b. No separate workspace QA settings sheet in v1

The popover **is** the workspace's QA settings. It carries the toggle,
the inheritance display, the "use project default" escape hatch, and
the model picks. There is no separate "workspace settings → QA review"
UI; that would duplicate the popover with worse discoverability.

#### 8c. Project settings sheet: QA defaults

In `Sources/Multiharness/Views/ProjectSettingsSheet.swift`, add a "QA
review" section. Controls:

- **Enable QA by default for new workspaces** — toggle that controls
  `default_qa_enabled`. Caption underneath: "Workspaces in this project
  start with QA review on. Each workspace can still opt out
  individually." (Flipped wording when off.)
- **Default QA provider** — provider picker. Available even when the
  toggle is off (so users can pre-configure a model that kicks in if
  someone later opts an individual workspace in).
- **Default QA model** — `ModelPicker` bound to the chosen provider.

These three controls are independent: turning the toggle off does **not**
clear the model picks, and setting a model does **not** flip the toggle.

#### 8d. Transcript rendering: QA group

`AgentStore` already groups turns by `groupId` derived from
`agent_start`/`agent_end`. Extend `ConversationTurn` (or its group
metadata) to carry a `groupKind: "build" | "qa"`. On `agent_start` with
`kind: "qa"`, set the next group's kind to `"qa"`.

The renderer shows a different header for QA groups:

```
🔍 QA review · Claude 3.7 Sonnet
```

And the `qa_findings` event renders as a structured card with:

- A verdict badge (✅ pass / ⚠️ minor / 🛑 blocker).
- The summary text (markdown).
- A collapsible list of findings (file:line + severity icon + message).

`handleEvent` learns a new branch:

```swift
case "qa_findings":
    let verdict = event.payload["verdict"] as? String ?? "info"
    let summary = event.payload["summary"] as? String ?? ""
    let findings = event.payload["findings"] as? [[String: Any]] ?? []
    turns.append(ConversationTurn(
        role: .qaFindings,           // new case
        text: summary,
        qaVerdict: verdict,
        qaFindings: findings.compactMap(QaFindings.parse),
        groupId: currentGroupId
    ))
```

History rehydration in `loadHistory()` handles the same event type the
same way — both qa_findings and the qa-tagged agent_start are persisted via
`PERSIST_EVENTS` (must add `qa_findings` to the sidecar's persist list).

#### 8e. Project settings + workspace settings: provider/model resolution

The QA provider/model pickers reuse the existing pickers from the workspace
create flow. No new model-listing code is needed.

### 9. Why build the QA first message Mac-side, not sidecar-side

The QA first message includes `git diff <baseBranch>...HEAD`. We could
compute this in the sidecar (it has bash via tools, and `worktreePath`),
but doing it on the Mac:

- Reuses the existing worktree shell helper that already knows about
  security-scoped bookmarks for TCC-protected paths.
- Keeps the sidecar's `qa.run` method simple and testable — it takes a
  message string, doesn't shell out itself.
- Lets the Mac decide on truncation policy without round-tripping.
- Mirrors how `auth.anthropic.console.start` and other "needs system
  access" work happens on the Mac side and the sidecar handles only the
  agent loop.

### 10. Event flow recap

```
User clicks Run QA
   ↓
Mac builds first-message string (diff + last user + last assistant)
   ↓
Mac → sidecar: qa.run { workspaceId, providerConfig, firstMessage }
   ↓
sidecar QaRunner constructs transient AgentSession (qa system prompt,
read-only tools, post_qa_findings tool, jsonl writer aimed at same file)
   ↓
session.prompt(firstMessage)
   ↓
events stream as usual:
   agent_start (kind: "qa") → tool_execution_start/end (read_file, grep, …)
      → message_update (assistant) → tool_execution_start (post_qa_findings)
      → qa_findings emitted → tool_execution_end → message_end → agent_end
   ↓
QaRunner disposes session
   ↓
Mac sets workspace.lifecycleState = .inReview if it was .inProgress
```

### 11. Relationship to big-bro-assist (deferred)

A sibling feature would let the user click a "🆘 Ask cloud for help" button
while the primary agent is mid-flail, sending the transcript + diff + last
user prompt to a cloud model for a *nudge* (advice the local agent can
follow on its next prompt) rather than a *replacement*.

This spec is deliberately scoped to QA only, but several decisions here
explicitly leave room:

- The `QaRunner` abstraction (transient secondary `AgentSession` in the
  same workspace, scoped tools, distinct system prompt mode) generalizes
  to "assist runner" trivially — same shape, different prompt + different
  output handling (the assist agent's reply goes into the primary agent's
  context as a system note rather than being rendered as findings).
- `SessionMode` is an enum, not a boolean, precisely so `"assist"` can be
  added as a third value without redoing the prompt-construction path.
- The schema's `qa_*` columns are NOT generalized to `secondary_*` because
  big-bro-assist will likely want its own provider/model (so the user can
  pick "Claude for QA, GPT-5 for assist"). Keeping the columns specific
  avoids a future renaming migration.
- The transient-session approach means we can layer assist in without ever
  touching `AgentRegistry`'s shape — same as QA.

Token-economics caveat for the eventual assist feature: in most "stuck"
scenarios, having the cloud model *do* the task from scratch costs less
than having it review the local model's failed attempts (because the
failed-attempt transcript is pure noise to the reviewer). Assist's
value is narrower than QA's and lives mainly in the "almost right, needs
a nudge" case. That's a UX decision for that spec, not this one.

### 12. Error handling & edge cases

- **No primary session.** `qa.run` errors with
  `no primary session for workspace <id>`. The Mac UI never sends `qa.run`
  in this state because the Run QA button requires the workspace be open
  (which forces session creation), but the sidecar still rejects defensively.
- **Primary agent starts streaming during QA.** Shouldn't happen because
  the Run QA button is disabled while `isStreaming`, but if a race occurs
  (e.g. iOS prompts the primary while QA is running) both sessions write to
  the same `messages.jsonl`. The `JsonlWriter` queues appends, so events
  remain individually intact but **interleave** in the file — the JSON
  schema (each line has a `seq` and a `ts`) plus the `groupId` on the
  client side keeps the UI rendering coherent. We do **not** lock the
  workspace during QA — the cost (a stuck workspace if QA hangs) outweighs
  the benefit.
- **QA agent never calls `post_qa_findings`.** The agent_end still fires;
  we render the transcript without a findings card. The verdict in the
  workspace lifecycle stays whatever the user set manually. Acceptable
  failure mode.
- **QA provider not configured.** Run QA button disabled. Tooltip explains.
- **QA provider rate-limits / errors mid-run.** Same path as primary agent
  errors: `agent_error` + `agent_end` synthesized; the user sees a `⚠️`
  assistant turn. QaRunner's `finally` still disposes the session.
- **User clicks Run QA twice.** The QA agent's `agent_start` flips
  `AgentStore.isStreaming` to true (QA events share the workspace's
  `AgentStore` and use the same `agent_start`/`agent_end` envelopes as
  primary). The composer's QA button reads `store.isStreaming` and
  disables itself.
  - There's a small window between the user clicking **Run QA** in the
    popover and the sidecar's `agent_start` reaching the Mac. To close
    it, the Composer keeps a local `@State qaLaunching: Bool` that flips
    true the instant the popover's Run QA button is clicked and back to
    false on the next `agent_end` (or on a `qa.run` error). The QA
    button is disabled when `qaLaunching || store.isStreaming`.
- **Distinguishing primary streaming from QA streaming in the UI.** Both
  flip `isStreaming`. The composer header label "🔍 QA running…" only
  appears when the *last* `agent_start` we saw had `kind == "qa"`.
  Track this as a new `lastGroupKind: GroupKind?` on `AgentStore`, set
  on `agent_start` and not cleared on `agent_end` (so the label stays
  meaningful between runs — once a QA finishes, isStreaming is false and
  the button returns to its idle label regardless).
- **Workspace archived during QA.** The session was already disposed when
  archive happened (via existing teardown), and QA's transient session
  has no special teardown beyond what `dispose()` already does.
- **Migration on existing installs.** v7 ALTERs are additive with safe
  defaults (`default_qa_enabled = 0`, others NULL). No existing workspace
  becomes QA-enabled by surprise.

### 13. Test plan

**Sidecar (`bun test`):**

- `qaRunner.test.ts` — constructs a `QaRunner` with a mock provider,
  asserts:
  - It instantiates an `AgentSession` with `systemPromptMode: "qa"`,
    read-only tools, and the supplied first message.
  - `agent_start` emitted with `kind: "qa"`.
  - On the post-prompt `agent_end`, the session is disposed.
- `prompts.test.ts` — `buildQaSystemPrompt()` produces stable text,
  does **not** include `<project_instructions>` / `<workspace_instructions>`
  even when set, and includes the orientation block.
- `methods.qa.test.ts` — `qa.run` rejects without `providerConfig`,
  rejects when no primary session exists, returns `{ok:true}` and emits
  events on the happy path.
- `agentSession.qaPersist.test.ts` — `qa_findings` is in `PERSIST_EVENTS`
  and lands in the JSONL.

**Mac (`swift test`):**

- `QaInheritanceTests` — `Workspace.effectiveQaEnabled(in:)`:
  - Workspace NULL + project on → true.
  - Workspace NULL + project off → false.
  - Workspace explicit true + project off → true (explicit opt-in).
  - Workspace explicit false + project on → false (explicit opt-out).
  - `qaEnabledIsOverridden(in:)` true iff `workspace.qaEnabled != nil`.
- `QaSelectionFallbackTests` — `Workspace.qaPopoverInitialSelection(in:)`
  returns workspace overrides when present, falls back to project
  defaults when the workspace fields are NULL, returns `(nil, nil)` when
  neither is set. Independent of the enabled flag (model picks persist
  through toggle changes).
- `QaFirstMessageBuilderTests` — given a fake last-user-turn / last-
  assistant-turn / diff, produces the expected message format, truncates
  diffs over 50k chars.
- `MigrationsTests` — v7 applies cleanly on top of v6, adds the new
  columns, doesn't break existing-row reads.

**Manual:**

1. **Project default off, workspace opt-in.** Create a workspace using a
   local model (LM Studio + a small model is fine). Composer shows
   `🔍 QA off ▾`. Click it; popover shows the toggle off and "Project
   default: off." Flip the toggle on, pick Anthropic OAuth + Sonnet,
   click **Save**. Composer label changes to `🔍 QA · Sonnet ▾`. Send a
   build prompt and let the agent finish. Click the QA button → popover
   re-opens pre-filled. Click **Run QA**. Expect a QA group with
   findings, workspace flips to `in_review`.
2. **Workspace opt-out from a project that opts in.** In project
   settings, toggle "Enable QA by default" on. Create a new workspace —
   composer shows `🔍 QA · <project default model> ▾` immediately
   (inherited). Open the popover, flip the toggle off, click **Save**.
   Composer changes to `🔍 QA off ▾`. The "Use project default" button
   appears (since workspace is now explicitly overriding); clicking it
   restores the inherited "on" state.
3. **Model picks survive toggle changes.** Configure a model in the
   popover, save with toggle off, reopen — the model is still pre-filled.
4. **Pre-configured model with toggle off.** Set a project default model
   but leave "Enable QA by default" off. New workspace shows `🔍 QA off ▾`
   in the composer, but opening the popover shows the project default
   model pre-selected. Flipping the toggle on + Run QA uses that model.
5. **Concurrent streaming.** While the primary agent is streaming, the
   composer's QA button stays enabled (so the user can prep the popover)
   but the "Run QA" button *inside* the popover is disabled with a "Wait
   for the agent to finish" tooltip.
6. **Run QA running state.** Click Run QA. Composer button becomes
   `🔍 QA running…` with a spinner; reopening the popover during the
   run also disables its Run QA button.
7. **Multiple QA passes.** After the first QA finishes, click Run QA
   again. New `🔍 QA review` group appended; no special handling needed.
8. **No QA model anywhere.** Project default model unset, workspace
   never picked. Composer shows `🔍 QA: pick a model ▾`. Popover Run QA
   disabled until model picked.

## File-level changes (preview)

**Schema / migration:**

- `Sources/MultiharnessCore/Persistence/Migrations.swift` — v7 ALTERs.
- `Sources/MultiharnessCore/Persistence/PersistenceService.swift` — read +
  write the new columns.

**Models:**

- `Sources/MultiharnessClient/Models/Models.swift` — new flat fields on
  `Project` (`defaultQaEnabled`, `defaultQaProviderId`,
  `defaultQaModelId`) and `Workspace` (`qaEnabled`, `qaProviderId`,
  `qaModelId`), plus `Workspace.qaPopoverInitialSelection(in:)` helper.

**Mac stores:**

- `Sources/MultiharnessCore/Stores/AppStore.swift` — setters for project
  QA defaults.
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — setter for
  workspace QA override.
- `Sources/MultiharnessCore/Stores/AgentStore.swift` — handle the
  `qa_findings` event; learn `groupKind` on the current group.

**Mac UI:**

- `Sources/Multiharness/Views/WorkspaceDetailView.swift` — add the **🔍 QA**
  button to the composer header row (next to the existing model button),
  plus a new `QaSwitcher` popover modeled on `ModelSwitcher`. Wire
  enable-state logic to `store.isStreaming`, in-flight QA tracking, and
  workspace archival.
- `Sources/Multiharness/Views/ProjectSettingsSheet.swift` — add a "QA
  review (default for new workspaces)" section: provider picker, model
  picker, "Enable QA by default" toggle.
- New `Sources/Multiharness/Views/QaFindingsCard.swift` — verdict badge +
  summary + collapsible findings list. Rendered by `TurnCard` (or a
  sibling) when `turn.role == .qaFindings`.

(There is intentionally **no** workspace-settings panel for QA in v1 —
the popover doubles as workspace-level QA settings and persists picks
automatically.)

**Sidecar:**

- `sidecar/src/prompts.ts` — `buildQaSystemPrompt()`, `SessionMode`.
- `sidecar/src/agentSession.ts` — `systemPromptMode`, `toolsOverride`
  options; inject `kind: "qa"` on `agent_start` when in qa mode; expose
  `worktreePath` (and confirm `projectId` is public, which it already is).
- `sidecar/src/tools/index.ts` — `buildReadOnlyTools()`, `postQaFindings`
  tool.
- New `sidecar/src/qaRunner.ts`.
- `sidecar/src/methods.ts` — `qa.run` registration.
- `sidecar/src/agentSession.ts` — `qa_findings` added to `PERSIST_EVENTS`.

**Mac control plumbing:**

- `Sources/MultiharnessCore/Control/...` — a typed `runQA(...)` helper on
  the control client, plus the first-message builder (probably as a free
  function under `Sources/MultiharnessCore/Worktree/`).

**Tests:**

- `Tests/MultiharnessCoreTests/QaConfigInheritanceTests.swift`
- `Tests/MultiharnessCoreTests/QaFirstMessageBuilderTests.swift`
- `Tests/MultiharnessCoreTests/MigrationsV7Tests.swift`
- `sidecar/test/qaRunner.test.ts`
- `sidecar/test/methods.qa.test.ts`
- `sidecar/test/prompts.qa.test.ts`

## Open questions

1. **Should QA findings auto-flip the workspace to `done` on `pass`
   verdict?** Tempting, but probably overreach — the user might want to
   review the findings first. Leave the verdict purely advisory; the user
   moves the workspace state. (Easy to add later; hard to take back.)
2. **Markdown in findings.** The `summary` is plain text in v1. If users
   start putting markdown in there organically we can teach the renderer.
3. **Should `qa.run` be available over the relay (iOS)?** Not in v1. Add
   to the relay list once the Mac UI is solid and iOS gets a QA button
   of its own.
4. **Multiple QA passes in a row.** Nothing stops the user from clicking
   Run QA again after the first finishes — and that's actually useful
   (re-review after fixes). Each pass produces a new `🔍 QA review`
   group in the transcript. No special handling needed beyond what's
   already specified.
