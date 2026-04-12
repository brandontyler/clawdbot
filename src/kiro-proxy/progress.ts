/**
 * ProgressReporter — sends incremental Discord updates during long ACP tool runs.
 *
 * Design informed by best practices from Claude Code, Codex CLI, Cursor, and Kiro:
 *
 * 1. **Phase-based display** (Cursor/Codex): Show what phase the agent is in
 *    (reading → planning → editing → verifying) not just raw tool names.
 * 2. **Smart grouping** (Claude Code): Collapse consecutive reads/edits into
 *    summaries like "📖 Read 4 files" instead of listing each one.
 * 3. **Progressive disclosure** (Bench/Intent): Keep the live view compact,
 *    expand detail in the final summary.
 * 4. **Thinking indicator** (all tools): Show when the agent is reasoning
 *    between tool calls — the "dead air" gap is the worst UX.
 * 5. **Context bar** (Claude Code status line): Visual progress bar for
 *    context window usage.
 */

import { postMessage, editMessage } from "./discord-api.js";

const FIRST_UPDATE_MS = 6_000;
const UPDATE_INTERVAL_MS = 60_000;
const MIN_TOOLS_BEFORE_REPORT = 1;
const MAX_DISPLAY_GROUPS = 5;
const MAX_TITLE_LEN = 55;
const MAX_FILES_IN_SUMMARY = 6;

type CompletedTool = { title: string; kind: string; durationMs?: number };

// --- Phase detection ---

type Phase = "exploring" | "planning" | "editing" | "running" | "verifying" | "working";

function detectPhase(kind: string): Phase {
  switch (kind) {
    case "read":
    case "search":
    case "web_search":
    case "fetch":
      return "exploring";
    case "think":
      return "planning";
    case "edit":
    case "delete":
      return "editing";
    case "execute":
    case "shell":
      return "running";
    default:
      return "working";
  }
}

const PHASE_LABELS: Record<Phase, string> = {
  exploring: "🔍 Exploring",
  planning: "🧠 Planning",
  editing: "📝 Editing",
  running: "▶️ Running",
  verifying: "✅ Verifying",
  working: "🔧 Working",
};

/** Emoji for a tool kind. */
function kindEmoji(kind: string): string {
  switch (kind) {
    case "edit":
    case "delete":
      return "📝";
    case "execute":
    case "shell":
      return "▶️";
    case "search":
    case "web_search":
      return "🔍";
    case "read":
      return "📖";
    case "fetch":
      return "🌐";
    case "think":
      return "🧠";
    default:
      return "🔧";
  }
}

/** Shorten a tool title for display. */
function formatTitle(title: string): string {
  let t = title.replace(/\n/g, " ").replace(/^Running:\s*/i, "");
  t = t.replace(/\/home\/[^/]+\/code\/[^/]+\/[^/]+\//g, "");
  const curlMatch = /curl\s.*?(https?:\/\/[^\s]+)/.exec(t);
  if (curlMatch?.[1]) {
    try {
      const url = new URL(curlMatch[1]);
      t = `curl ${url.pathname.slice(0, 40)}`;
    } catch {
      /* keep original */
    }
  }
  if (t.length > MAX_TITLE_LEN) {
    t = `${t.slice(0, MAX_TITLE_LEN - 1)}…`;
  }
  return t;
}

function elapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) {
    return `${s}s`;
  }
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return rem > 0 ? `${m}m ${rem}s` : `${m}m`;
}

/** Extract a short filename from a tool title. */
function extractFile(title: string): string | null {
  const cleaned = title.replace(/\/home\/[^/]+\/code\/[^/]+\/[^/]+\//, "");
  // Must look like a file path (no spaces, has extension or slash).
  if (cleaned && !cleaned.includes(" ") && (cleaned.includes("/") || cleaned.includes("."))) {
    return cleaned;
  }
  return null;
}

// --- Smart grouping (Claude Code style) ---

type DisplayGroup = { kind: string; items: CompletedTool[]; label: string };

/**
 * Group completed tools by kind for compact display.
 * Consecutive tools of the same kind get collapsed:
 *   📖 Read 4 files (src/foo.ts, src/bar.ts, +2)
 *   📝 Edited 2 files (progress.ts, server.ts)
 *   ▶️ pnpm build (45s)
 */
function buildDisplayGroups(history: CompletedTool[]): DisplayGroup[] {
  const groups: DisplayGroup[] = [];
  let i = 0;
  while (i < history.length) {
    const tool = history[i];
    if (!tool) {
      i++;
      continue;
    }
    const phase = detectPhase(tool.kind);
    // Collect consecutive tools in the same phase.
    const items: CompletedTool[] = [tool];
    while (i + items.length < history.length) {
      const next = history[i + items.length];
      if (!next || detectPhase(next.kind) !== phase) {
        break;
      }
      items.push(next);
    }
    i += items.length;

    // Build the label.
    if (items.length === 1) {
      // Single tool — show its title directly.
      const dur =
        tool.durationMs != null && tool.durationMs >= 2000 ? ` ${elapsed(tool.durationMs)}` : "";
      groups.push({
        kind: tool.kind,
        items,
        label: `${kindEmoji(tool.kind)} ${formatTitle(tool.title)}${dur}`,
      });
    } else {
      // Multiple tools — collapse into a summary.
      const files = items.map((t) => extractFile(t.title)).filter(Boolean) as string[];
      const uniqueFiles = [...new Set(files)];
      const emoji = kindEmoji(items[0]?.kind ?? "");
      let noun: string;
      let verb: string;
      if (phase === "exploring") {
        verb = "Read";
        noun = items.length === 1 ? "file" : "files";
      } else if (phase === "editing") {
        verb = "Edited";
        noun = items.length === 1 ? "file" : "files";
      } else {
        verb = "Ran";
        noun = items.length === 1 ? "command" : "commands";
      }
      let detail = "";
      if (uniqueFiles.length > 0) {
        const shown = uniqueFiles.slice(0, 3).map((f) => f.split("/").pop() ?? f);
        const extra = uniqueFiles.length > 3 ? `, +${uniqueFiles.length - 3}` : "";
        detail = ` (${shown.join(", ")}${extra})`;
      }
      groups.push({
        kind: items[0]?.kind ?? "",
        items,
        label: `${emoji} ${verb} ${items.length} ${noun}${detail}`,
      });
    }
  }
  return groups;
}

/** Compact context indicator for Discord (block chars render too wide). */
function contextBar(pct: number): string {
  const warn = pct >= 60 ? " ⚠️" : "";
  return `${pct.toFixed(0)}% ctx${warn}`;
}

export class ProgressReporter {
  private channelId: string | null = null;
  private messageId: string | null = null;
  private timer: NodeJS.Timeout | null = null;
  private firstTimer: NodeJS.Timeout | null = null;
  private started = false;
  private promptStartedAt = 0;
  private toolCount = 0;
  private currentTool: { title: string; kind: string; startedAt: number } | null = null;
  private history: CompletedTool[] = [];
  private allHistory: CompletedTool[] = [];
  private contextPct = 0;
  private lastToolEndAt = 0;
  private readonly log: (msg: string) => void;

  constructor(log: (msg: string) => void) {
    this.log = log;
  }

  start(channelId: string, contextPct: number): void {
    this.stop();
    this.channelId = channelId;
    this.promptStartedAt = Date.now();
    this.toolCount = 0;
    this.currentTool = null;
    this.history = [];
    this.allHistory = [];
    this.contextPct = contextPct;
    this.lastToolEndAt = 0;
    this.started = true;
    this.log(`progress-diag: start channelId=${channelId} ctx=${contextPct}`);

    this.firstTimer = setTimeout(() => {
      this.firstTimer = null;
      this.log(
        `progress-diag: firstTimer fired started=${this.started} toolCount=${this.toolCount}`,
      );
      if (!this.started || this.toolCount < MIN_TOOLS_BEFORE_REPORT) {
        this.scheduleInterval();
        return;
      }
      void this.sendOrEdit();
      this.scheduleInterval();
    }, FIRST_UPDATE_MS);
  }

  private scheduleInterval(): void {
    if (this.timer) {
      return;
    }
    this.timer = setInterval(() => {
      if (!this.started || this.toolCount < MIN_TOOLS_BEFORE_REPORT) {
        return;
      }
      void this.sendOrEdit();
    }, UPDATE_INTERVAL_MS);
  }

  onToolCall(title: string, kind: string, status: string, isNew: boolean): void {
    if (!this.started) {
      this.log(`progress-diag: onToolCall SKIPPED (not started) status=${status} kind=${kind}`);
      return;
    }
    this.log(
      `progress-diag: onToolCall isNew=${isNew} status=${status} kind=${kind} toolCount=${this.toolCount}`,
    );

    if (isNew) {
      // tool_call event — a new tool has started.
      // Complete the previous tool if one was in flight.
      if (this.currentTool) {
        const dur = Date.now() - this.currentTool.startedAt;
        this.history.push({
          title: this.currentTool.title,
          kind: this.currentTool.kind,
          durationMs: dur,
        });
        this.allHistory.push({
          title: this.currentTool.title,
          kind: this.currentTool.kind,
          durationMs: dur,
        });
      }
      this.currentTool = { title, kind: kind || "other", startedAt: Date.now() };
      this.toolCount++;
      this.lastToolEndAt = 0;
    } else if (status === "completed" || status === "failed") {
      // tool_call_update with terminal status — tool finished.
      if (this.currentTool) {
        const dur = Date.now() - this.currentTool.startedAt;
        this.history.push({
          title: this.currentTool.title,
          kind: this.currentTool.kind,
          durationMs: dur,
        });
        this.allHistory.push({
          title: this.currentTool.title,
          kind: this.currentTool.kind,
          durationMs: dur,
        });
        this.currentTool = null;
        this.lastToolEndAt = Date.now();
      }
    }
  }

  updateContext(pct: number): void {
    this.contextPct = pct;
  }

  async finish(): Promise<void> {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.clearTimers();

    if (!this.messageId || !this.channelId) {
      return;
    }

    const dt = elapsed(Date.now() - this.promptStartedAt);
    const parts: string[] = [];
    parts.push(`✅ **Done** (${dt}, ${this.toolCount} tool${this.toolCount !== 1 ? "s" : ""})`);

    // Summarize by category.
    const reads = this.allHistory.filter((t) => detectPhase(t.kind) === "exploring").length;
    const edits = this.allHistory.filter((t) => detectPhase(t.kind) === "editing").length;
    const runs = this.allHistory.filter((t) => detectPhase(t.kind) === "running").length;
    const counts: string[] = [];
    if (reads > 0) {
      counts.push(`📖 ${reads} read`);
    }
    if (edits > 0) {
      counts.push(`📝 ${edits} edit`);
    }
    if (runs > 0) {
      counts.push(`▶️ ${runs} cmd`);
    }
    if (counts.length > 0) {
      parts.push(`  ${counts.join("  ·  ")}`);
    }

    // List files touched.
    const files = new Set<string>();
    for (const tool of this.allHistory) {
      const f = extractFile(tool.title);
      if (f) {
        files.add(f);
      }
    }
    const editedFiles = [...files];
    if (editedFiles.length > 0) {
      const shown = editedFiles.slice(0, MAX_FILES_IN_SUMMARY).map((f) => f.split("/").pop() ?? f);
      const extra =
        editedFiles.length > MAX_FILES_IN_SUMMARY
          ? ` +${editedFiles.length - MAX_FILES_IN_SUMMARY} more`
          : "";
      parts.push(`  📁 ${shown.join(", ")}${extra}`);
    }

    await editMessage(this.channelId, this.messageId, parts.join("\n"));
    this.messageId = null;
  }

  stop(): void {
    this.started = false;
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.firstTimer) {
      clearTimeout(this.firstTimer);
      this.firstTimer = null;
    }
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  private async sendOrEdit(): Promise<void> {
    if (!this.channelId) {
      this.log("progress-diag: sendOrEdit SKIPPED (no channelId)");
      return;
    }
    const content = this.buildMessage();
    this.log(
      `progress-diag: sendOrEdit messageId=${this.messageId ?? "NEW"} channelId=${this.channelId}`,
    );
    if (this.messageId) {
      await editMessage(this.channelId, this.messageId, content);
    } else {
      this.messageId = await postMessage(this.channelId, content);
      if (this.messageId) {
        this.log(`progress message posted: ${this.messageId}`);
      } else {
        this.log("progress-diag: postMessage returned null");
      }
    }
  }

  private buildMessage(): string {
    const dt = elapsed(Date.now() - this.promptStartedAt);
    const lines: string[] = [];

    // Phase-aware header (like Cursor's "Planning Next Moves" / "Applying Changes").
    const currentPhase = this.currentTool ? detectPhase(this.currentTool.kind) : "working";
    const phaseLabel = this.currentTool
      ? PHASE_LABELS[currentPhase]
      : this.lastToolEndAt > 0
        ? "💭 Thinking"
        : "🔧 Working";
    lines.push(
      `${phaseLabel}**...** (${dt}, ${this.toolCount} tool${this.toolCount !== 1 ? "s" : ""})`,
    );

    // Smart-grouped completed tools (Claude Code style).
    const groups = buildDisplayGroups(this.history);
    // Show only the last N groups to keep it compact.
    const displayGroups = groups.slice(-MAX_DISPLAY_GROUPS);
    if (groups.length > MAX_DISPLAY_GROUPS) {
      const hidden = groups.length - MAX_DISPLAY_GROUPS;
      lines.push(`  ··· ${hidden} earlier step${hidden !== 1 ? "s" : ""}`);
    }
    for (const group of displayGroups) {
      lines.push(`  ✅ ${group.label}`);
    }

    // Current active tool with live duration.
    if (this.currentTool) {
      const emoji = kindEmoji(this.currentTool.kind);
      const toolDur = elapsed(Date.now() - this.currentTool.startedAt);
      lines.push(`  ⏳ ${emoji} ${formatTitle(this.currentTool.title)} (${toolDur})`);
    } else if (this.lastToolEndAt > 0) {
      const thinkDur = elapsed(Date.now() - this.lastToolEndAt);
      lines.push(`  💭 Reasoning... (${thinkDur})`);
    }

    // Context bar (Claude Code status line style).
    if (this.contextPct > 0) {
      lines.push(`  📊 ${contextBar(this.contextPct)}`);
    }

    return lines.join("\n");
  }
}
