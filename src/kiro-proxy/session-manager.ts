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
import { KiroSession, type KiroSessionOptions } from "./kiro-session.js";
import type { OpenAIMessage, KiroSessionHandle } from "./types.js";

const DEFAULT_IDLE_SECS = 1800; // 30 minutes

type ManagedSession = {
  session: KiroSession;
  handle: KiroSessionHandle;
};

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();
  private readonly sessionOpts: KiroSessionOptions;
  private readonly idleMs: number;
  private gcTimer: NodeJS.Timeout | null = null;

  constructor(
    sessionOpts: KiroSessionOptions,
    opts: { idleSecs?: number } = {},
  ) {
    this.sessionOpts = sessionOpts;
    this.idleMs = (opts.idleSecs ?? DEFAULT_IDLE_SECS) * 1000;
  }

  /**
   * Return the session key for a given conversation.
   * Explicit key (from `user` field or header) takes precedence.
   */
  static resolveSessionKey(messages: OpenAIMessage[], explicitKey?: string): string {
    if (explicitKey?.trim()) {
      return explicitKey.trim();
    }
    // Anchor: first system message (if any) + first user message content.
    const anchor = messages
      .filter((m) => m.role === "system" || m.role === "user")
      .slice(0, 2)
      .map((m) => `${m.role}:${m.content.slice(0, 512)}`)
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
  ): Promise<{ session: KiroSession; promptText: string }> {
    const existing = this.sessions.get(sessionKey);

    if (existing && existing.session.alive) {
      // Route only the NEW messages since the last turn.
      const newMessages = messages.slice(existing.handle.sentMessageCount);
      const promptText = this.buildPromptFromMessages(newMessages);
      existing.handle.sentMessageCount = messages.length;
      existing.handle.lastTouchedAt = Date.now();
      existing.session.lastTouchedAt = Date.now();
      return { session: existing.session, promptText };
    }

    // Dead or non-existent session — create a fresh one.
    if (existing) {
      existing.session.kill();
      this.sessions.delete(sessionKey);
    }

    const session = await KiroSession.create(this.sessionOpts);

    // For the very first turn, send system prompt (if any) prepended to the
    // first user message so Kiro can establish context.
    const promptText = this.buildPromptFromMessages(messages);

    const handle: KiroSessionHandle = {
      acpSessionId: session.acpSessionId,
      sentMessageCount: messages.length,
      lastTouchedAt: Date.now(),
    };
    this.sessions.set(sessionKey, { session, handle });
    this.scheduleGc();

    return { session, promptText };
  }

  /** Kill all sessions cleanly. */
  shutdown(): void {
    if (this.gcTimer) {
      clearInterval(this.gcTimer);
      this.gcTimer = null;
    }
    for (const { session } of this.sessions.values()) {
      session.kill();
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
      if (msg.role === "system") {
        parts.push(`[System context]\n${msg.content}`);
      } else if (msg.role === "user") {
        parts.push(msg.content);
      }
      // Skip assistant messages — Kiro already knows what it said.
    }
    return parts.join("\n\n").trim();
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
      if (!session.alive || now - handle.lastTouchedAt > this.idleMs) {
        session.kill();
        this.sessions.delete(key);
      }
    }
    if (this.sessions.size === 0 && this.gcTimer) {
      clearInterval(this.gcTimer);
      this.gcTimer = null;
    }
  }
}
