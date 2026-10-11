# Kiro-CLI Known Issues

## Session History Corruption on Large File Writes

**Status:** Waiting for upstream fix
**Upstream issue:** https://github.com/kirodotdev/Kiro/issues/6110
**Bead:** `oc-oeq`
**Affected versions:** kiro-cli ≤ 1.26.2

### Symptom

ACP sessions crash with:

```
{"code":-32603,"message":"Internal error","data":"invalid conversation history received"}
```

The user sees: "Session history became corrupted and auto-recovery failed."

### Root Cause

kiro-cli has a bug in session serialization. When the model emits a `write`
tool call with very large input (e.g., a full `.drawio` XML file), kiro-cli:

1. Replaces the tool input with a placeholder:
   `"SYSTEM NOTE: the actual tool use arguments were too complicated to be generated"`
2. Writes this as a **separate `AssistantMessage`** entry in the session file,
   breaking the expected alternating pattern (AssistantMessage → ToolResults)
3. The preceding tool call's `ToolResults` gets written after the orphaned
   `AssistantMessage`, creating an ID mismatch

This produces two consecutive `AssistantMessage` entries and an orphaned
`toolUse` with no matching `toolResult`. On the next prompt, kiro-cli
validates its history and rejects it.

### Trigger Pattern

Always the same sequence:

```
AssistantMessage → toolUse (read/web_fetch)     ← normal
AssistantMessage → toolUse (write, "too complicated")  ← CORRUPTION
ToolResults      → toolResult (for the read, not the write)
```

Confirmed in 6/6 corrupted session files. The `write` tool is always
targeting a large file (architecture diagrams in `.drawio` XML format).

### Workaround

Until the upstream fix lands:

- **Break large file writes into smaller steps.** Instead of asking the agent
  to generate an entire diagram in one shot, ask it to plan first, then write
  incrementally.
- **Avoid prompts that combine research + large file generation** in a single
  turn (e.g., "read the architecture docs and rewrite the diagram").
- **Use `/new` to reset** when the corruption message appears — the session
  cannot be recovered.

### Recovery Behavior

The proxy attempts two recovery strategies:

1. Kill the corrupted process, spawn fresh, replay the user message with a
   safety preamble steering away from large writes
2. If that fails, spawn again with a minimal no-tool prompt

Both currently fail because the model follows the same tool pattern on the
same task, reproducing the corruption. The proxy then returns a synthetic
reset notice.

### Proxy Diagnostics

Corruption events are logged to:

- `/tmp/kiro-proxy.log` (tagged `🔴 CORRUPTION DIAG`)
- `logs/corruption-events.jsonl` (structured, persistent)

Session files can be inspected at `~/.kiro/sessions/cli/<session-id>.jsonl`.

## Automatic Compaction (proxy-enforced at 60%)

**Status:** Supported / enabled by default
**Affected versions:** observed with kiro-cli 2.8.1 ACP sessions

### Background

kiro-cli 2.8.1 contains two compaction implementations. Its generic module uses
60%, while the ACP ChatAgent graph observed on this host uses 80% projected
usage / 95% truncation and has failed to repeat reliably in persistent sessions.
The proxy therefore enforces the operator policy directly: after every completed
turn, context at or above 60% queues native `/compact` against the **same ACP
child and session ID**. The compaction queue slot is reserved before the turn's
lock is released, so the response can finish promptly while every later turn
waits behind compaction. This does not replay or shorten Gateway history and
never resets the child.

### What the proxy does

The proxy observes Kiro's context-usage notifications and, after each completed
turn, reserves the next FIFO slot and invokes native `/compact` directly on the
same ACP child when usage is at or above 60%. The completed answer is not held
open for maintenance, but a later Gateway turn cannot race or replace the child
because it queues behind compaction. Kiro's own scheduler
remains enabled by its normal defaults and can compact earlier; the proxy does
not send an unverified capability override.

### Lifecycle events

The proxy listens for compaction lifecycle transitions from **two** event
families and de-duplicates them so each transition surfaces at most once:

- **Modern** (kiro-cli 2.8.1): `session_info_update` notifications carrying
  `_meta.kiro.kind` ∈ { `context_usage`, `summarization_started`,
  `summarization_completed`, `summarization_failed` }.
- **ACP wrapper compatibility** (also emitted by the installed kiro-cli 2.8.1):
  `_kiro.dev/metadata` (context %) and `_kiro.dev/compaction/status`
  (`started` | `completed` | `failed`).

Replayed `completed`/`failed` events with no matching live `started` (which can
happen on session load) are ignored. Notifications carrying another session ID
(such as a subagent's context update) are ignored so child usage cannot overwrite
the parent session's displayed percentage. A `failed` event clears the
in-progress "🧹 Compacting…" banner so it can never get stuck.

### Native scheduler proof and limitation (2026-08-29)

A persistent ACP session reported 76.2% context. On the next prompt, kiro-cli
emitted native compaction `started` and `completed`, wrote a 30,268-character
replacement summary, then reported 8.8% and continued the in-flight task. Its
JSONL contained a native `Compaction` record preserving the two most recent
message pairs; no reset, replacement session, or `loadSession` fallback occurred.

The same session later crossed 80.1% and 82.8% without another lifecycle event
event or context drop. This is why the proxy now owns the 60% guarantee instead
of relying on Kiro's internal scheduler to re-arm.

### Rollback switch

To disable the proxy safeguard as a rollback, start the proxy with:

```bash
openclaw kiro-proxy --no-auto-compaction
```

This disables only the proxy's 60% safeguard. Kiro CLI's independent native
scheduler is unchanged. Manual `/kcompact` remains available through the
dedicated same-session proxy endpoint.

### Manual fallback vs. reset

- `/kcompact` — dedicated `POST /compact/<sessionKey>` path that acquires the
  current session lock and invokes native `/compact` directly. It never sends a
  synthetic one-message OpenAI history and therefore cannot trigger history-
  shrink reset logic.
- There is no synchronous 95% context reset. It raced Kiro's own truncation path
  and could kill the ACP receiver while compaction was starting. High-context
  turns now get the same direct compaction safeguard instead.
