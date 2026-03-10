/**
 * ProgressReporter — sends incremental Discord updates during long ACP tool runs.
 *
 * Posts a single message after FIRST_UPDATE_MS of tool execution, then edits
 * it in-place every UPDATE_INTERVAL_MS. When the turn completes, edits to a
 * final summary or deletes the message.
 */

import { postMessage, editMessage } from "./discord-api.js";

const FIRST_UPDATE_MS = 12_000;
const UPDATE_INTERVAL_MS = 60_000;
const MIN_TOOLS_BEFORE_REPORT = 1;
const MAX_HISTORY = 5;
const MAX_TITLE_LEN = 60;

type CompletedTool = { title: string; kind: string };

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
  // Strip "Running: " prefix for shell commands.
  let t = title.replace(/^Running:\s*/i, "");
  // Strip absolute cwd prefixes.
  t = t.replace(/\/home\/[^/]+\/code\/[^/]+\/[^/]+\//g, "");
  // Collapse long curl commands to just the path.
  const curlMatch = /curl\s.*?(https?:\/\/[^\s]+)/.exec(t);
  if (curlMatch?.[1]) {
    try {
      const url = new URL(curlMatch[1]);
      t = `curl ${url.pathname.slice(0, 40)}`;
    } catch {
      // keep original
    }
  }
  if (t.length > MAX_TITLE_LEN) {
    t = t.slice(0, MAX_TITLE_LEN - 1) + "…";
  }
  return t;
}

/** Group consecutive edits to the same file. */
function groupHistory(history: CompletedTool[]): string[] {
  const lines: string[] = [];
  let i = 0;
  while (i < history.length) {
    const tool = history[i];
    if (!tool) {
      i++;
      continue;
    }
    // Count consecutive same-title entries.
    let count = 1;
    while (i + count < history.length && history[i + count]?.title === tool.title) {
      count++;
    }
    const emoji = kindEmoji(tool.kind);
    const title = formatTitle(tool.title);
    lines.push(count > 1 ? `  ✅ ${emoji} ${title} (×${count})` : `  ✅ ${emoji} ${title}`);
    i += count;
  }
  return lines;
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

export class ProgressReporter {
  private channelId: string | null = null;
  private messageId: string | null = null;
  private timer: NodeJS.Timeout | null = null;
  private firstTimer: NodeJS.Timeout | null = null;
  private started = false;
  private promptStartedAt = 0;
  private toolCount = 0;
  private currentTool: { title: string; kind: string } | null = null;
  private history: CompletedTool[] = [];
  private contextPct = 0;
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
    this.contextPct = contextPct;
    this.started = true;

    // First update after FIRST_UPDATE_MS, only if enough tools have fired.
    this.firstTimer = setTimeout(() => {
      this.firstTimer = null;
      if (!this.started || this.toolCount < MIN_TOOLS_BEFORE_REPORT) {
        // Not enough activity yet — check again at the next interval.
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

  onToolCall(title: string, kind: string, status: string): void {
    if (!this.started) {
      return;
    }
    if (status === "in_progress" || status === "pending") {
      // A new tool started — push the previous one to history.
      if (this.currentTool) {
        this.history.push(this.currentTool);
        if (this.history.length > MAX_HISTORY) {
          this.history.shift();
        }
      }
      this.currentTool = { title, kind };
      this.toolCount++;
    } else if (status === "execute" || status === "read" || status === "search") {
      // Descriptive update for the current tool — replace the bare name in place.
      if (this.currentTool) {
        this.currentTool.title = title;
        if (kind) {
          this.currentTool.kind = kind;
        }
      }
    } else if (status === "completed" || status === "failed") {
      if (this.currentTool) {
        this.history.push(this.currentTool);
        if (this.history.length > MAX_HISTORY) {
          this.history.shift();
        }
        this.currentTool = null;
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

    // Edit to final summary if we posted a progress message.
    const dt = elapsed(Date.now() - this.promptStartedAt);
    const summary = `✅ **Done** (${dt}, ${this.toolCount} tool${this.toolCount !== 1 ? "s" : ""})`;
    await editMessage(this.channelId, this.messageId, summary);
    this.messageId = null;
  }

  stop(): void {
    this.started = false;
    this.clearTimers();
    // Don't clean up messageId here — finish() handles the final edit.
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
      return;
    }
    const content = this.buildMessage();
    if (this.messageId) {
      await editMessage(this.channelId, this.messageId, content);
    } else {
      this.messageId = await postMessage(this.channelId, content);
      if (this.messageId) {
        this.log(`progress message posted: ${this.messageId}`);
      }
    }
  }

  private buildMessage(): string {
    const dt = elapsed(Date.now() - this.promptStartedAt);
    const lines: string[] = [];
    lines.push(
      `🔧 **Working...** (${dt}, ${this.toolCount} tool${this.toolCount !== 1 ? "s" : ""})`,
    );

    // Recent completed tools.
    const grouped = groupHistory(this.history);
    for (const line of grouped) {
      lines.push(line);
    }

    // Current active tool.
    if (this.currentTool) {
      const emoji = kindEmoji(this.currentTool.kind);
      lines.push(`  ⏳ ${emoji} ${formatTitle(this.currentTool.title)}`);
    }

    // Context usage.
    if (this.contextPct > 0) {
      lines.push(`  📊 ${this.contextPct.toFixed(1)}% context`);
    }

    return lines.join("\n");
  }
}
