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
import { KiroSession, type KiroSessionOptions, type KiroSessionEvents } from "./kiro-session.js";
import type { OpenAIMessage, KiroSessionHandle, ChannelRoute } from "./types.js";

const DEFAULT_IDLE_SECS = 1800; // 30 minutes

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

type ManagedSession = {
  session: KiroSession;
  handle: KiroSessionHandle;
  promptLock: Promise<void>;
};

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();
  private readonly sessionOpts: KiroSessionOptions;
  private readonly channelRoutes: Record<string, ChannelRoute>;
  private readonly idleMs: number;
  private readonly log: (msg: string) => void;
  private gcTimer: NodeJS.Timeout | null = null;

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
    this.scheduleGc();
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
      } else {
        // Wait for any in-flight prompt to finish before sending the next one.
        await existing.promptLock;
        const newMessages = messages.slice(existing.handle.sentMessageCount);
        const promptText = this.buildPromptFromMessages(newMessages);
        existing.handle.sentMessageCount = messages.length;
        existing.handle.lastTouchedAt = Date.now();
        existing.session.lastTouchedAt = Date.now();
        return { session: existing.session, promptText, managed: existing };
      }
    }

    // Dead or non-existent session — create a fresh one.
    if (existing) {
      existing.session.kill("replaced-dead-session");
      this.sessions.delete(sessionKey);
    }

    // Resolve per-channel cwd/args overrides.
    const channelId = detectChannelId(openclawSessionKey);
    this.log(
      `detectChannelId: channelId=${channelId ?? "none"} routeKeys=[${Object.keys(this.channelRoutes).join(",")}]`,
    );
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

    const session = await KiroSession.create(sessionOpts, this.buildSessionEvents(sessionKey));

    // For the very first turn, send system prompt (if any) prepended to the
    // first user message so Kiro can establish context.
    const promptText = this.buildPromptFromMessages(messages);

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
    for (const { session } of this.sessions.values()) {
      session.kill("shutdown");
    }
    this.sessions.clear();
  }

  // ─── Private ──────────────────────────────────────────────────────────────

  /**
   * Convert an array of OpenAI messages into a single text block to send
   * to Kiro.  System messages are prefixed with "System: "; user messages
   * with "User: "; assistant echoes are skipped (Kiro has them already).
   */
  private buildPromptFromMessages(messages: OpenAIMessage[]): string {
    const parts: string[] = [];
    for (const msg of messages) {
      const text = extractText(msg.content);
      if (msg.role === "system") {
        parts.push(`[System context]\n${text}`);
      } else if (msg.role === "user") {
        parts.push(text);
      }
    }
    return parts.join("\n\n").trim();
  }

  private buildSessionEvents(sessionKey: string): KiroSessionEvents {
    return {
      onContextUsage: (pct) => {
        this.log(`context: ${pct.toFixed(1)}% (session=${sessionKey.slice(0, 8)}…)`);
      },
      onActivity: () => {
        const managed = this.sessions.get(sessionKey);
        if (managed) {
          managed.handle.lastTouchedAt = Date.now();
          managed.session.lastTouchedAt = Date.now();
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

  private gc(): void {
    const now = Date.now();
    for (const [key, { session, handle }] of this.sessions) {
      const idleFor = now - handle.lastTouchedAt;
      if (!session.alive) {
        session.kill(`gc-already-dead (idle=${Math.round(idleFor / 1000)}s)`);
        this.sessions.delete(key);
      } else if (idleFor > this.idleMs) {
        session.kill(
          `gc-idle-timeout (idle=${Math.round(idleFor / 1000)}s, limit=${Math.round(this.idleMs / 1000)}s)`,
        );
        this.sessions.delete(key);
      }
    }
    // GC timer stays alive even when empty — avoids edge case where
    // orphaned sessions survive because the timer was cleared and never
    // restarted (the timer is unref'd so it won't prevent exit).
  }
}
