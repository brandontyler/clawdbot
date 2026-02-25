/**
 * SessionManager — owns the pool of live KiroSessions.
 *
 * Session identity:
 *   pi-ai sends the FULL conversation in every request (standard OpenAI
 *   format).  We identify a conversation by hashing its "anchor" — the
 *   first user message (or the system message + first user message pair).
 *   All subsequent turns from the same conversation share the same anchor
 *   and are therefore routed to the same kiro process.
 *
 *   Callers may also pass an explicit session key via OpenAI's `user` field
 *   (the proxy checks that first) or via the `X-Kiro-Session-Id` header.
 *
 * Session memory:
 *   The kiro process maintains its own conversation history.  We track
 *   `sentMessageCount` so we know how many OpenAI messages have already
 *   been forwarded.  On each turn we send only the NEW user message(s).
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { checkContextAlert, clearContextAlerts } from "./alerts.js";
import { KiroSession, type KiroSessionOptions, type KiroSessionEvents } from "./kiro-session.js";
import { ProgressReporter } from "./progress.js";
import type { OpenAIMessage, KiroSessionHandle, ChannelRoute } from "./types.js";

const DEFAULT_IDLE_SECS = 14400; // 4 hours — idle sessions hibernate (not killed), so context is preserved

const HIBERNATE_PATH = `${process.env.HOME}/.openclaw/kiro-proxy-hibernated.json`;

const CONTEXT_WARN_PCT = 80;
const CONTEXT_CRITICAL_PCT = 90;
const CONTEXT_RESET_PCT = 95;

/** Check if an error is the "invalid conversation history" crash. */
export function isInvalidHistoryError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : JSON.stringify(err);
  return (
    msg.includes("invalid conversation history") ||
    msg.includes("conversation history is invalid") ||
    msg.includes("session state") ||
    msg.includes("corrupt")
  );
}

/** Extract text from OpenAI content (string or array of content parts). */
function extractText(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .filter((p: { type: string; text?: string }) => p.type === "text" && p.text)
      .map((p: { text: string }) => p.text)
      .join(" ");
  }
  return JSON.stringify(content ?? "");
}

/**
 * Extract a Discord channel ID from an OpenClaw session key.
 * Session keys look like: agent:main:discord:channel:1475216992956059698
 */
const SESSION_KEY_CHANNEL_RE = /discord:channel:(\d+)/;

export function detectChannelId(sessionKey: string | undefined): string | undefined {
  if (!sessionKey) {
    return undefined;
  }
  const match = SESSION_KEY_CHANNEL_RE.exec(sessionKey);
  return match ? match[1] : undefined;
}

/**
 * Build a short human-readable tag for a session key.
 * If the key contains a channel ID that maps to a known route, return the
 * project directory basename (e.g. "clawdbot"); otherwise fall back to the
 * first 16 chars of the key.
 */
export function resolveSessionTag(
  sessionKey: string,
  channelRoutes: Record<string, ChannelRoute>,
): string {
  const channelId = detectChannelId(sessionKey);
  if (channelId) {
    const route = channelRoutes[channelId];
    if (route) {
      const name = route.cwd.split("/").pop() ?? route.cwd;
      return `${name}(${channelId.slice(-4)})`;
    }
    return `ch:${channelId.slice(-6)}`;
  }
  return `${sessionKey.slice(0, 16)}…`;
}

type HibernatedSession = {
  acpSessionId: string;
  cwd: string;
  contextPct: number;
  hibernatedAt: number;
};

type ManagedSession = {
  session: KiroSession;
  handle: KiroSessionHandle;
  promptLock: Promise<void>;
};

/** Load hibernated sessions from disk. */
function loadHibernated(): Map<string, HibernatedSession> {
  try {
    const data = JSON.parse(readFileSync(HIBERNATE_PATH, "utf8")) as Record<
      string,
      HibernatedSession
    >;
    return new Map(Object.entries(data));
  } catch {
    return new Map();
  }
}

/** Persist hibernated sessions to disk. */
function saveHibernated(map: Map<string, HibernatedSession>): void {
  try {
    mkdirSync(`${process.env.HOME}/.openclaw`, { recursive: true });
    writeFileSync(HIBERNATE_PATH, JSON.stringify(Object.fromEntries(map), null, 2) + "\n");
  } catch {
    // Best-effort.
  }
}

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();
  private readonly hibernated: Map<string, HibernatedSession>;
  private readonly reporters = new Map<string, ProgressReporter>();
  private readonly sessionOpts: KiroSessionOptions;
  private readonly channelRoutes: Record<string, ChannelRoute>;
  private readonly idleMs: number;
  private readonly log: (msg: string) => void;
  private gcTimer: NodeJS.Timeout | null = null;
  private heartbeatTimer: NodeJS.Timeout | null = null;

  /** Short human-readable label for a session key (e.g. "clawdbot(7014)"). */
  private tag(key: string): string {
    return resolveSessionTag(key, this.channelRoutes);
  }

  /** Clean up all per-session state (alerts, progress reporter). */
  private cleanupSession(sessionKey: string): void {
    clearContextAlerts(sessionKey);
    const reporter = this.reporters.get(sessionKey);
    if (reporter) {
      reporter.stop();
      this.reporters.delete(sessionKey);
    }
  }

  constructor(
    sessionOpts: KiroSessionOptions,
    opts: {
      channelRoutes?: Record<string, ChannelRoute>;
      idleSecs?: number;
      log?: (msg: string) => void;
    } = {},
  ) {
    this.sessionOpts = sessionOpts;
    this.channelRoutes = opts.channelRoutes ?? {};
    this.idleMs = (opts.idleSecs ?? DEFAULT_IDLE_SECS) * 1000;
    this.log = opts.log ?? (() => {});
    this.hibernated = loadHibernated();
    if (this.hibernated.size > 0) {
      this.log(`loaded ${this.hibernated.size} hibernated session(s) from disk`);
    }
    this.scheduleGc();
    this.scheduleHeartbeat();
  }

  /**
   * Return the session key for a given conversation.
   * Explicit key (from `user` field or header) takes precedence.
   */
  static resolveSessionKey(messages: OpenAIMessage[], explicitKey?: string): string {
    if (explicitKey?.trim()) {
      return explicitKey.trim();
    }
    const anchor = messages
      .filter((m) => m.role === "system" || m.role === "user")
      .slice(0, 2)
      .map((m) => {
        let text = extractText(m.content).slice(0, 512);
        text = text.replace(/"message_id"\s*:\s*"[^"]*",?\s*/g, "");
        // Strip envelope timestamps: both bare [Thu 2026-02-20 19:30 CST]
        // and prefixed [Discord 123 Thu 2026-02-20 19:30 CST]
        text = text.replace(/\[[^\]]*[A-Z][a-z]{2} \d{4}-\d{2}-\d{2} \d{2}:\d{2} [A-Z]+\]\s*/g, "");
        return `${m.role}:${text.trim()}`;
      })
      .join("|");
    return createHash("sha256").update(anchor).digest("hex").slice(0, 32);
  }

  /**
   * Get or create a KiroSession for the given key.
   * Returns the session + the text to send in this turn.
   */
  async getOrCreate(
    sessionKey: string,
    messages: OpenAIMessage[],
    openclawSessionKey?: string,
  ): Promise<{ session: KiroSession; promptText: string; managed: ManagedSession }> {
    const existing = this.sessions.get(sessionKey);

    if (existing && existing.session.alive) {
      // Session was reset upstream — message count dropped below what we've sent.
      if (messages.length < existing.handle.sentMessageCount) {
        this.log(
          `session reset detected (msgs=${messages.length} < sent=${existing.handle.sentMessageCount}), replacing`,
        );
        existing.session.kill("session-reset");
        this.sessions.delete(sessionKey);
        this.cleanupSession(sessionKey);
      } else {
        // Wait for any in-flight prompt to finish before sending the next one.
        await existing.promptLock;
        const newMessages = messages.slice(existing.handle.sentMessageCount);
        const promptText = this.buildPromptFromMessages(newMessages);
        existing.handle.sentMessageCount = messages.length;
        existing.handle.lastTouchedAt = Date.now();
        existing.session.lastTouchedAt = Date.now();
        const rssKb = existing.session.getRssKb();
        this.log(
          `session reuse: session=${this.tag(sessionKey)} pid=${existing.session.pid} ctx=${existing.session.lastContextPct.toFixed(0)}% rss=${rssKb != null ? `${Math.round(rssKb / 1024)}MB` : "?"} newMsgs=${newMessages.length}`,
        );
        return { session: existing.session, promptText, managed: existing };
      }
    }

    // Dead or non-existent session — create a fresh one.
    if (existing) {
      existing.session.kill("replaced-dead-session");
      this.sessions.delete(sessionKey);
      this.cleanupSession(sessionKey);
    }

    // Resolve per-channel cwd/args overrides.
    const channelId = detectChannelId(openclawSessionKey);
    const route = channelId ? this.channelRoutes[channelId] : undefined;
    const sessionOpts: KiroSessionOptions = route
      ? {
          ...this.sessionOpts,
          cwd: route.cwd,
          kiroArgs: route.kiroArgs ?? this.sessionOpts.kiroArgs,
        }
      : this.sessionOpts;

    if (route) {
      this.log(`channel route: channel=${channelId} cwd=${route.cwd}`);
    }

    const session = await this.createOrLoadSession(sessionKey, sessionOpts);

    this.log(
      `session ready: session=${this.tag(sessionKey)} pid=${session.pid} cwd=${sessionOpts.cwd} pool=${this.sessions.size + 1}`,
    );

    // For noHibernate routes the ACP session is always fresh — only send the
    // latest user message so the model doesn't hallucinate prior context from
    // the gateway's replayed history.
    const freshOnly = route?.noHibernate === true && !session.wasLoaded;
    const promptMessages = freshOnly ? messages.slice(-1) : messages;
    if (freshOnly && messages.length > 1) {
      this.log(
        `noHibernate fresh session — sending only latest message (dropped ${messages.length - 1} replayed)`,
      );
    }
    const promptText = this.buildPromptFromMessages(promptMessages);

    const handle: KiroSessionHandle = {
      acpSessionId: session.acpSessionId,
      sentMessageCount: messages.length,
      lastTouchedAt: Date.now(),
    };
    const managed: ManagedSession = { session, handle, promptLock: Promise.resolve() };
    this.sessions.set(sessionKey, managed);

    return { session, promptText, managed };
  }

  /** Kill all sessions cleanly. */
  shutdown(): void {
    if (this.gcTimer) {
      clearInterval(this.gcTimer);
      this.gcTimer = null;
    }
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    for (const [key, { session }] of this.sessions) {
      if (session.alive && session.acpSessionId) {
        this.hibernateSession(key, session, "shutdown");
      } else {
        session.kill("shutdown");
      }
    }
    this.sessions.clear();
  }

  /**
   * Reset a session after an unrecoverable error (e.g. invalid history).
   * Kills the ACP process and removes it from the pool so the next
   * getOrCreate() spawns a fresh one.
   */
  resetSession(sessionKey: string, reason: string): void {
    const existing = this.sessions.get(sessionKey);
    if (existing) {
      this.log(`session auto-reset: reason=${reason} (session=${this.tag(sessionKey)})`);
      existing.session.kill(`auto-reset: ${reason}`);
      this.sessions.delete(sessionKey);
      this.cleanupSession(sessionKey);
    }
  }

  /**
   * Send ACP session/cancel to interrupt an in-flight prompt.
   * Returns true if a cancel was sent, false if no active prompt was found.
   */
  async cancelSession(sessionKey: string): Promise<boolean> {
    const managed = this.sessions.get(sessionKey);
    if (!managed?.session.isPrompting) {
      return false;
    }
    this.log(`cancel requested: session=${this.tag(sessionKey)}`);
    await managed.session.cancel();
    return true;
  }

  /**
   * Cancel all sessions that are currently prompting.
   * Returns the number of sessions cancelled.
   */
  async cancelAll(): Promise<number> {
    let count = 0;
    for (const [key, { session }] of this.sessions) {
      if (session.isPrompting) {
        this.log(`cancel-all: session=${this.tag(key)}`);
        await session.cancel();
        count++;
      }
    }
    return count;
  }

  /**
   * Get the latest user message text from an OpenAI message array.
   * Used for recovery: send only the last message to a fresh session.
   */
  getLatestUserMessage(messages: OpenAIMessage[]): string {
    for (let i = messages.length - 1; i >= 0; i--) {
      const msg = messages[i];
      if (msg.role === "user") {
        return extractText(msg.content);
      }
    }
    return "";
  }

  // ─── Private ──────────────────────────────────────────────────────────────

  /**
   * Try to load a hibernated session; fall back to creating a fresh one.
   * Removes the hibernation entry regardless of outcome.
   */
  private async createOrLoadSession(
    sessionKey: string,
    sessionOpts: KiroSessionOptions,
  ): Promise<KiroSession> {
    const channelId = detectChannelId(sessionKey);
    const route = channelId ? this.channelRoutes[channelId] : undefined;
    const hibernated = this.hibernated.get(sessionKey);
    if (hibernated) {
      this.hibernated.delete(sessionKey);
      saveHibernated(this.hibernated);
      if (route?.noHibernate) {
        this.log(`discarding hibernated session (noHibernate): acp=${hibernated.acpSessionId}`);
      } else {
        this.log(
          `resuming hibernated session: acp=${hibernated.acpSessionId} ctx=${hibernated.contextPct.toFixed(0)}% age=${Math.round((Date.now() - hibernated.hibernatedAt) / 60_000)}min`,
        );
        const session = await KiroSession.load(
          hibernated.acpSessionId,
          sessionOpts,
          this.buildSessionEvents(sessionKey),
        );
        return session;
      }
    }
    return KiroSession.create(sessionOpts, this.buildSessionEvents(sessionKey));
  }

  /**
   * Hibernate a session: kill the process but save the ACP session ID
   * so it can be restored via loadSession later.
   */
  hibernateSession(sessionKey: string, session: KiroSession, reason: string): void {
    const channelId = detectChannelId(sessionKey);
    const route = channelId ? this.channelRoutes[channelId] : undefined;
    const skip = route?.noHibernate === true;
    if (!skip) {
      this.hibernated.set(sessionKey, {
        acpSessionId: session.acpSessionId,
        cwd: route?.cwd ?? this.sessionOpts.cwd,
        contextPct: session.lastContextPct,
        hibernatedAt: Date.now(),
      });
      saveHibernated(this.hibernated);
    }
    session.kill(`${skip ? "kill" : "hibernate"}: ${reason}`);
    this.sessions.delete(sessionKey);
    this.cleanupSession(sessionKey);
    this.log(
      `session ${skip ? "killed (noHibernate)" : "hibernated"}: session=${this.tag(sessionKey)} acp=${session.acpSessionId} ctx=${session.lastContextPct.toFixed(0)}% reason=${reason}`,
    );
  }

  /** Look up a live session by key (for manual hibernate endpoint). */
  getSessionEntry(sessionKey: string): { session: KiroSession } | undefined {
    const managed = this.sessions.get(sessionKey);
    if (!managed) {
      return undefined;
    }
    return { session: managed.session };
  }

  /** Return diagnostic info for all active sessions. */
  getSessionsInfo(): Array<{
    key: string;
    alive: boolean;
    pid: number | undefined;
    rssMb: number | undefined;
    contextPct: number;
    idleSecs: number;
    consecutiveErrors: number;
    sentMessages: number;
    isPrompting: boolean;
    promptingSecs: number | null;
  }> {
    const now = Date.now();
    const result: Array<{
      key: string;
      alive: boolean;
      pid: number | undefined;
      rssMb: number | undefined;
      contextPct: number;
      idleSecs: number;
      consecutiveErrors: number;
      sentMessages: number;
      isPrompting: boolean;
      promptingSecs: number | null;
    }> = [];
    for (const [key, { session, handle }] of this.sessions) {
      const rssKb = session.getRssKb();
      result.push({
        key,
        alive: session.alive,
        pid: session.pid,
        rssMb: rssKb != null ? Math.round(rssKb / 1024) : undefined,
        contextPct: session.lastContextPct,
        idleSecs: Math.round((now - handle.lastTouchedAt) / 1000),
        consecutiveErrors: session.consecutiveErrors,
        sentMessages: handle.sentMessageCount,
        isPrompting: session.isPrompting,
        promptingSecs:
          session.promptStartedAt != null
            ? Math.round((now - session.promptStartedAt) / 1000)
            : null,
      });
    }
    return result;
  }

  /** Return info about hibernated sessions for the /sessions endpoint. */
  getHibernatedInfo(): Array<{
    key: string;
    acpSessionId: string;
    contextPct: number;
    hibernatedAt: number;
    ageSecs: number;
  }> {
    const now = Date.now();
    return [...this.hibernated.entries()].map(([key, h]) => ({
      key,
      acpSessionId: h.acpSessionId,
      contextPct: h.contextPct,
      hibernatedAt: h.hibernatedAt,
      ageSecs: Math.round((now - h.hibernatedAt) / 1000),
    }));
  }

  /**
   * Convert an array of OpenAI messages into a single text block to send
   * to Kiro.  Only user messages are forwarded — system messages from the
   * gateway are dropped because kiro-cli builds its own context from the
   * project's `.kiro/` config.  Forwarding them would inject the shared
   * workspace memory/persona into every channel (cross-contamination).
   */
  private buildPromptFromMessages(messages: OpenAIMessage[]): string {
    const parts: string[] = [];
    for (const msg of messages) {
      if (msg.role === "user") {
        parts.push(extractText(msg.content));
      }
    }
    return parts.join("\n\n").trim();
  }

  private buildSessionEvents(sessionKey: string): KiroSessionEvents {
    return {
      onContextUsage: (pct) => {
        this.log(`context: ${pct.toFixed(1)}% (session=${this.tag(sessionKey)})`);
        checkContextAlert(sessionKey, pct, this.log);
        const reporter = this.reporters.get(sessionKey);
        if (reporter) {
          reporter.updateContext(pct);
        }
        if (pct >= CONTEXT_RESET_PCT) {
          this.log(
            `context critical (${pct.toFixed(1)}% >= ${CONTEXT_RESET_PCT}%) — auto-resetting session=${this.tag(sessionKey)}`,
          );
          this.resetSession(sessionKey, `context-critical-${Math.round(pct)}pct`);
        } else if (pct >= CONTEXT_CRITICAL_PCT) {
          this.log(
            `context CRITICAL: ${pct.toFixed(1)}% (session=${this.tag(sessionKey)}) — will auto-reset at ${CONTEXT_RESET_PCT}%, send /new soon`,
          );
        } else if (pct >= CONTEXT_WARN_PCT) {
          this.log(
            `context warning: ${pct.toFixed(1)}% (session=${this.tag(sessionKey)}) — approaching limit`,
          );
        }
      },
      onActivity: () => {
        const managed = this.sessions.get(sessionKey);
        if (managed) {
          managed.handle.lastTouchedAt = Date.now();
          managed.session.lastTouchedAt = Date.now();
        }
      },
      onToolCall: (title, kind, status) => {
        const reporter = this.reporters.get(sessionKey);
        if (reporter) {
          reporter.onToolCall(title, kind, status);
        }
      },
      onPromptStart: () => {
        const channelId = detectChannelId(sessionKey);
        if (!channelId) {
          return;
        }
        let reporter = this.reporters.get(sessionKey);
        if (!reporter) {
          reporter = new ProgressReporter(this.log);
          this.reporters.set(sessionKey, reporter);
        }
        const session = this.sessions.get(sessionKey)?.session;
        reporter.start(channelId, session?.lastContextPct ?? 0);
      },
      onPromptEnd: () => {
        const reporter = this.reporters.get(sessionKey);
        if (reporter) {
          void reporter.finish();
        }
      },
    };
  }

  private scheduleGc(): void {
    if (this.gcTimer) {
      return;
    }
    const interval = Math.max(60_000, this.idleMs / 6);
    this.gcTimer = setInterval(() => this.gc(), interval);
    this.gcTimer.unref();
  }

  private scheduleHeartbeat(): void {
    if (this.heartbeatTimer) {
      return;
    }
    // Log pool health every 5 minutes for passive diagnostics.
    this.heartbeatTimer = setInterval(() => {
      const sessions = this.getSessionsInfo();
      const totalRss = sessions.reduce((sum, s) => sum + (s.rssMb ?? 0), 0);
      const summary = sessions
        .map(
          (s) =>
            `${this.tag(s.key)}(ctx=${Math.round(s.contextPct)}%,idle=${s.idleSecs}s,rss=${s.rssMb ?? "?"}MB,errs=${s.consecutiveErrors}${s.isPrompting ? `,PROMPTING=${s.promptingSecs}s` : ""})`,
        )
        .join(" ");
      this.log(
        `heartbeat: sessions=${sessions.length} totalRss=${totalRss}MB${summary ? ` [${summary}]` : ""}`,
      );
    }, 300_000);
    this.heartbeatTimer.unref();
  }

  private gc(): void {
    const now = Date.now();
    const before = this.sessions.size;
    let reaped = 0;
    for (const [key, { session, handle }] of this.sessions) {
      const idleFor = now - handle.lastTouchedAt;
      const rssKb = session.getRssKb();
      const rssMb = rssKb != null ? Math.round(rssKb / 1024) : "?";
      const keyTag = `session=${this.tag(key)}`;
      if (!session.alive) {
        session.kill(
          `gc-already-dead (${keyTag}, idle=${Math.round(idleFor / 1000)}s, rss=${rssMb}MB)`,
        );
        this.sessions.delete(key);
        this.cleanupSession(key);
        reaped++;
      } else if (session.isPrompting) {
        // Never kill a session with an active prompt — the agent is working.
        continue;
      } else if (idleFor > this.idleMs) {
        this.hibernateSession(
          key,
          session,
          `gc-idle-timeout (idle=${Math.round(idleFor / 1000)}s)`,
        );
        reaped++;
      }
    }
    // Log GC summary so we have visibility even when nothing is reaped.
    if (before > 0 || reaped > 0) {
      const survivors = this.getSessionsInfo();
      const summary = survivors
        .map(
          (s) =>
            `${this.tag(s.key)}(ctx=${Math.round(s.contextPct)}%,idle=${s.idleSecs}s,rss=${s.rssMb ?? "?"}MB${s.isPrompting ? `,PROMPTING=${s.promptingSecs}s` : ""})`,
        )
        .join(" ");
      this.log(
        `gc: checked=${before} reaped=${reaped} alive=${this.sessions.size}${summary ? ` [${summary}]` : ""}`,
      );
    }
    // GC timer stays alive even when empty — avoids edge case where
    // orphaned sessions survive because the timer was cleared and never
    // restarted (the timer is unref'd so it won't prevent exit).
  }
}
