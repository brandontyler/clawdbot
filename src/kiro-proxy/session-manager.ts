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
import type { OpenAIMessage, KiroSessionHandle, ChannelRoute, ImageInput } from "./types.js";

const DEFAULT_IDLE_SECS = 1800; // 30 minutes — short idle timeout prevents stale ACP pipes

const HIBERNATE_PATH =
  process.env.KIRO_PROXY_HIBERNATE_PATH ??
  `${process.env.HOME}/.openclaw/kiro-proxy-hibernated.json`;

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
  // Delegate to extractTextAndImages so the multimodal parsing logic lives
  // in exactly one place. Callers that only care about text just ignore the
  // images field; this is a hot path but the cost is negligible (no I/O).
  return extractTextAndImages(content).text;
}

/**
 * Maximum number of images per request, matching kiro-cli's documented limit
 * (https://kiro.dev/docs/cli/chat/images/). Beyond this, kiro-cli may reject
 * the whole prompt; truncating preserves the first N rather than losing all.
 */
const MAX_IMAGES_PER_REQUEST = 10;

/**
 * Per-image cap matching kiro-cli's documented limit (10 MB). We measure
 * decoded bytes (3/4 of base64 length) since that's what kiro-cli sees.
 */
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

/**
 * Pattern matching the `[media attached: ...]` hint lines emitted by the
 * gateway in `src/auto-reply/media-note.ts`. When pi-ai has already attached
 * the corresponding image bytes as `image_url` parts, these lines are pure
 * token bloat (~70-80 tokens per image attachment). Strip them so the model
 * only sees the actual image plus the user's text, mirroring the IDE's
 * drag/drop UX. Patterns:
 *   [media attached: <path>]
 *   [media attached: <path> (<mime>)]
 *   [media attached: <path> (<mime>) | <url>]
 *   [media attached N/M: <path>...]
 *   [media attached: N files]   (multi-file header)
 */
const MEDIA_ATTACHED_LINE_PATTERN = /^\s*\[media attached(?:\s+\d+\/\d+)?:\s+[^\]]*\]\s*$/;

function stripMediaAttachedLines(text: string): string {
  if (!text.includes("[media attached")) return text;
  const lines = text.split("\n");
  const kept = lines.filter((line) => !MEDIA_ATTACHED_LINE_PATTERN.test(line));
  if (kept.length === lines.length) return text;
  // Collapse runs of blank lines created by removal so the prompt isn't
  // peppered with empty paragraphs.
  return kept
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/**
 * Parse a single OpenAI multimodal `image_url` part into an ImageInput.
 * Returns null on malformed/unsupported URLs (logged by caller). Supports
 * data:<mime>;base64,<bytes> URLs only — http(s) URLs are rejected because
 * kiro-cli expects inline bytes, not links.
 */
function parseImageUrlPart(
  url: string,
  log?: (msg: string) => void,
): { data: string; mimeType: string } | null {
  if (!url.startsWith("data:")) {
    log?.(`image_url skipped: non-data URL (${url.slice(0, 32)}…) — kiro expects inline bytes`);
    return null;
  }
  // Format: data:<mime>;base64,<base64-data>
  // Be permissive with parameters (e.g. data:image/jpeg;name=foo;base64,…).
  const commaIdx = url.indexOf(",");
  if (commaIdx < 0) {
    log?.(`image_url skipped: malformed data URL (no comma)`);
    return null;
  }
  const header = url.slice(5, commaIdx); // strip "data:"
  const data = url.slice(commaIdx + 1);
  if (!header.toLowerCase().includes(";base64")) {
    log?.(`image_url skipped: data URL not base64-encoded`);
    return null;
  }
  const mimeType = header.split(";")[0]?.trim() || "image/jpeg";
  // Sanity-check decoded size (4 base64 chars = 3 bytes).
  const approxBytes = Math.floor((data.length * 3) / 4);
  if (approxBytes > MAX_IMAGE_BYTES) {
    log?.(
      `image_url skipped: ${Math.round(approxBytes / 1024 / 1024)}MB exceeds ${MAX_IMAGE_BYTES / 1024 / 1024}MB cap`,
    );
    return null;
  }
  return { data, mimeType };
}

/**
 * Extract both text and inline images from OpenAI content. Used by the
 * proxy to translate multimodal user messages into ACP prompt content
 * blocks. `text` collapses all text parts; `images` is in source order.
 *
 * NOTE: this is a pure projection — no `[media attached:]` stripping
 * happens here. The strip is applied later in `buildPromptFromMessages`
 * for the prompt we send to ACP, but kept out of this function so that
 * session-key fingerprinting (`resolveSessionKey` → `extractText`) stays
 * stable for the same conversation regardless of whether images were
 * attached.
 */
function extractTextAndImages(
  content: unknown,
  log?: (msg: string) => void,
): { text: string; images: Array<{ data: string; mimeType: string }> } {
  if (typeof content === "string") {
    return { text: content, images: [] };
  }
  if (!Array.isArray(content)) {
    return { text: JSON.stringify(content ?? ""), images: [] };
  }
  const textParts: string[] = [];
  const images: Array<{ data: string; mimeType: string }> = [];
  for (const part of content) {
    if (!part || typeof part !== "object") continue;
    const p = part as { type?: string; text?: string; image_url?: { url?: string } };
    if (p.type === "text" && typeof p.text === "string") {
      textParts.push(p.text);
    } else if (p.type === "image_url" && typeof p.image_url?.url === "string") {
      const img = parseImageUrlPart(p.image_url.url, log);
      if (img) {
        images.push(img);
      }
    }
  }
  return { text: textParts.join(" "), images };
}

/**
 * Native kiro-cli slash commands as advertised in `_kiro.dev/commands/available`
 * (kiro-cli v2.8.1). Commands the OpenClaw gateway intercepts upstream
 * (/new, /reset, /compact, /model, /think, /usage, /help, /mcp, /sessions,
 * /restart, /stop, /session, /status, /unfocus, /acp) never reach the proxy
 * and are intentionally absent from this list.
 */
const KIRO_NATIVE_SLASH_COMMANDS: ReadonlySet<string> = new Set([
  "/agent",
  "/chat",
  "/clear",
  "/code",
  "/context",
  "/effort",
  "/feedback",
  "/goal",
  "/guide",
  "/hooks",
  "/knowledge",
  "/paste",
  "/plan",
  "/prompts",
  "/quit",
  "/reply",
  "/rewind",
  "/stats",
  "/tools",
]);

/**
 * If the message body is a kiro-cli native slash command (after stripping
 * the gateway's metadata envelope), return the bare command (with optional
 * trailing args). Otherwise return null.
 *
 * The gateway wraps Discord messages in JSON metadata blocks and
 * `<<<EXTERNAL_UNTRUSTED_CONTENT>>>` fences before forwarding. kiro-cli's
 * command parser only fires when `/` is at position 0, so `/clear` buried
 * inside the envelope is silently treated as plain text.
 */
export function extractKiroSlashCommand(text: string): string | null {
  if (!text) {
    return null;
  }
  // Strip JSON code fences (```json ... ```)
  let stripped = text.replace(/```(?:json)?\s*[\s\S]*?```/g, " ");
  // Strip fence markers — keep inner content, fences are single-line tokens
  stripped = stripped.replace(/<<<EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>/g, "");
  stripped = stripped.replace(/<<<END_EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>/g, "");
  // Strip common envelope headers
  stripped = stripped.replace(
    /^(Conversation info \(untrusted metadata\):|Sender \(untrusted metadata\):|Reply target [^\n]*:|Untrusted context [^\n]*:|Source: External|UNTRUSTED Discord [^\n]*|---)\s*$/gm,
    "",
  );
  // Collapse whitespace and pull non-empty lines
  const lines = stripped
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  if (lines.length === 0) {
    return null;
  }
  // The user's actual message is typically the last non-empty line
  // (or appears multiple times — same content, so taking last is safe).
  const candidate = lines[lines.length - 1];
  const match = /^(\/[a-z][a-z0-9-]*)(?:\s+(.*))?$/i.exec(candidate);
  if (!match) {
    return null;
  }
  const cmd = match[1].toLowerCase();
  if (!KIRO_NATIVE_SLASH_COMMANDS.has(cmd)) {
    return null;
  }
  return match[2] ? `${cmd} ${match[2].trim()}` : cmd;
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
  ): Promise<{
    session: KiroSession;
    promptText: string;
    promptImages: ImageInput[];
    managed: ManagedSession;
    unlockPrompt?: () => void;
  }> {
    const existing = this.sessions.get(sessionKey);

    if (existing && existing.session.alive) {
      // Wait for any in-flight prompt to finish before sending the next one.
      // Timeout after 120s to prevent infinite hangs when kiro-cli is zombie.
      const PROMPT_LOCK_TIMEOUT_MS = 120_000;
      const lockResult = await Promise.race([
        existing.promptLock.then(() => "resolved" as const),
        new Promise<"timeout">((r) => setTimeout(() => r("timeout"), PROMPT_LOCK_TIMEOUT_MS)),
      ]);
      if (lockResult === "timeout") {
        this.log(
          `🔴 promptLock timeout (${PROMPT_LOCK_TIMEOUT_MS / 1000}s): session=${this.tag(sessionKey)} — killing zombie session`,
        );
        this.resetSession(sessionKey, "prompt-lock-timeout");
        // Fall through to create a fresh session below.
      } else {
        // Detect history compaction: if the gateway pruned old messages, the array
        // is now shorter than what we've already sent.  Send only the latest user
        // message instead of an empty slice.
        let newMessages: OpenAIMessage[] = [];
        if (messages.length < existing.handle.sentMessageCount) {
          this.log(
            `⚠️ session reset detected (msgs=${messages.length} < sent=${existing.handle.sentMessageCount}), sending /chat new then replacing`,
          );
          // Send /chat new to clear kiro-cli's internal context before killing.
          const killTimer = setTimeout(() => existing.session.kill("chat-new-timeout"), 5000);
          let chatNewOk = false;
          try {
            await existing.session.prompt("/chat new", () => {});
            clearTimeout(killTimer);
            chatNewOk = true;
          } catch (err) {
            clearTimeout(killTimer);
            this.log(`/chat new failed (process may be dead): ${String(err)}`);
          }
          if (chatNewOk) {
            // Re-hibernate: the ACP session now has clean context on disk.
            existing.session.lastContextPct = 0;
            this.hibernateSession(sessionKey, existing.session, "session-reset");
          } else {
            // /chat new failed - don't hibernate the bloated session. Reset it
            // so next request creates a completely fresh one (also clears the
            // stale hibernated entry that snapshotAll() may have written).
            this.resetSession(sessionKey, "session-reset-failed");
          }
          // Session was reset - remove from active sessions and fall through
          // to create a fresh one below.
          this.sessions.delete(sessionKey);
          this.cleanupSession(sessionKey);
        } else {
          newMessages = messages.slice(existing.handle.sentMessageCount);
        }

        // Guard: if the slice produced zero new messages but the request has user
        // messages, the gateway likely reset its session (/new) while the proxy
        // still holds the old sentMessageCount.  Kill the stale session and let
        // the caller fall through to create a fresh one.
        if (
          newMessages.length === 0 &&
          messages.length > 0 &&
          messages.some((m) => m.role === "user")
        ) {
          this.log(
            `⚠️ session desync: sentCount=${existing.handle.sentMessageCount} msgs=${messages.length} but newMsgs=0 — gateway likely reset. Killing stale session=${this.tag(sessionKey)}`,
          );
          this.resetSession(sessionKey, "desync-empty-slice");
          // Fall through to the "create fresh session" path below.
        } else {
          const { text: promptText, images: promptImages } =
            this.buildPromptFromMessages(newMessages);
          existing.handle.sentMessageCount = messages.length;
          existing.handle.lastTouchedAt = Date.now();
          existing.session.lastTouchedAt = Date.now();
          const rssKb = existing.session.getRssKb();
          this.log(
            `session reuse: session=${this.tag(sessionKey)} pid=${existing.session.pid} ctx=${existing.session.lastContextPct.toFixed(0)}% rss=${rssKb != null ? `${Math.round(rssKb / 1024)}MB` : "?"} newMsgs=${newMessages.length}${promptImages.length ? ` imgs=${promptImages.length}` : ""}`,
          );
          // Lock immediately so no concurrent request can slip through before
          // the caller sets the real promptLock in the streaming path.
          let unlockPrompt: () => void;
          existing.promptLock = new Promise((r) => {
            unlockPrompt = r;
          });
          return {
            session: existing.session,
            promptText,
            promptImages,
            managed: existing,
            unlockPrompt: unlockPrompt!,
          };
        }
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
    const { text: promptText, images: promptImages } = this.buildPromptFromMessages(promptMessages);

    const handle: KiroSessionHandle = {
      acpSessionId: session.acpSessionId,
      sentMessageCount: messages.length,
      lastTouchedAt: Date.now(),
    };
    let unlockNew: () => void;
    const managed: ManagedSession = {
      session,
      handle,
      promptLock: new Promise((r) => {
        unlockNew = r;
      }),
    };
    this.sessions.set(sessionKey, managed);

    return { session, promptText, promptImages, managed, unlockPrompt: unlockNew! };
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
    // Always clear the hibernated entry so the session starts fresh.
    if (this.hibernated.delete(sessionKey)) {
      saveHibernated(this.hibernated);
      this.log(`cleared hibernated entry: ${this.tag(sessionKey)} reason=${reason}`);
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

  /**
   * Snapshot a session: persist the ACP session ID to the hibernation file
   * without killing the process. If the process dies later (VM reboot, proxy
   * restart, laptop shutdown), the next message will restore from this snapshot.
   */
  snapshotSession(sessionKey: string, session: KiroSession): void {
    const channelId = detectChannelId(sessionKey);
    const route = channelId ? this.channelRoutes[channelId] : undefined;
    if (route?.noHibernate === true) {
      return;
    }
    this.hibernated.set(sessionKey, {
      acpSessionId: session.acpSessionId,
      cwd: route?.cwd ?? this.sessionOpts.cwd,
      contextPct: session.lastContextPct,
      hibernatedAt: Date.now(),
    });
    saveHibernated(this.hibernated);
    this.log(
      `session snapshot saved: session=${this.tag(sessionKey)} acp=${session.acpSessionId} ctx=${session.lastContextPct.toFixed(0)}%`,
    );
  }

  /** Snapshot all active sessions without killing them. */
  snapshotAll(): number {
    let count = 0;
    for (const [key, managed] of this.sessions) {
      this.snapshotSession(key, managed.session);
      count++;
    }
    return count;
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
   *
   * Special case: if the latest user message body (after stripping the
   * gateway's metadata envelope) is a kiro-cli native slash command,
   * forward ONLY the bare command so kiro-cli's command parser sees `/`
   * at position 0.  Otherwise the command is buried inside metadata and
   * gets treated as plain text by kiro-cli.
   */
  private buildPromptFromMessages(messages: OpenAIMessage[]): {
    text: string;
    images: ImageInput[];
  } {
    // Try the slash-command fast-path on the latest user message.
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m?.role === "user") {
        const bare = extractKiroSlashCommand(extractText(m.content));
        if (bare) {
          // Slash commands never carry image attachments — keep it lean.
          return { text: bare, images: [] };
        }
        break;
      }
    }
    const parts: string[] = [];
    const images: ImageInput[] = [];
    for (const msg of messages) {
      if (msg.role === "user") {
        const extracted = extractTextAndImages(msg.content, this.log);
        // Per-message scope: strip the redundant `[media attached: /path]`
        // hint lines only from messages that actually carried image bytes.
        // This keeps session-key fingerprinting stable (extractText stays a
        // pure projection) while still saving ~80 tokens per attached image
        // in the prompt we send to ACP.
        const text =
          extracted.images.length > 0 ? stripMediaAttachedLines(extracted.text) : extracted.text;
        if (text) {
          parts.push(text);
        }
        if (extracted.images.length > 0) {
          images.push(...extracted.images);
        }
      }
    }
    // Enforce kiro-cli's documented 10-image-per-request cap. Truncate (keep
    // the first N) rather than dropping the request — better UX than silent
    // total failure if the user attaches 11+ images at once.
    if (images.length > MAX_IMAGES_PER_REQUEST) {
      this.log(
        `⚠️ ${images.length} images exceeds kiro-cli's ${MAX_IMAGES_PER_REQUEST}-image limit — truncating to first ${MAX_IMAGES_PER_REQUEST}`,
      );
      images.length = MAX_IMAGES_PER_REQUEST;
    }
    return { text: parts.join("\n\n").trim(), images };
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
      onToolCall: (title, kind, status, isNew) => {
        const reporter = this.reporters.get(sessionKey);
        if (reporter) {
          reporter.onToolCall(title, kind, status, isNew);
        }
      },
      onPromptStart: () => {
        const channelId = detectChannelId(sessionKey);
        this.log(
          `progress-diag: onPromptStart sessionKey=${sessionKey.slice(0, 40)} channelId=${channelId ?? "NONE"}`,
        );
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
    // Also auto-snapshot all sessions so state survives ungraceful shutdowns.
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
      if (sessions.length > 0) {
        this.snapshotAll();
      }
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
