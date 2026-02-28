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
