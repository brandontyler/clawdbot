/**
 * KiroSession — wraps a single long-lived kiro ACP subprocess.
 *
 * One KiroSession per OpenClaw conversation.  The Kiro process maintains its
 * own conversation history internally, so we only ever send the *new* user
 * message(s) on each turn.
 *
 * Streaming works via a mutable callback that is set before each prompt() call
 * and cleared when the call resolves.  The ClientSideConnection's sessionUpdate
 * handler calls it on every agent_message_chunk event.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { Readable, Writable } from "node:stream";
import {
  ClientSideConnection,
  PROTOCOL_VERSION,
  ndJsonStream,
  type RequestPermissionRequest,
  type RequestPermissionResponse,
  type SessionNotification,
} from "@agentclientprotocol/sdk";

// ─── Kiro extension notifications ─────────────────────────────────────────────

type KiroMetadata = {
  sessionId: string;
  contextUsagePercentage: number;
};

// ─── Permission handling ──────────────────────────────────────────────────────

/** Auto-approve all permissions in proxy mode (no TTY available). */
function autoApprovePermission(params: RequestPermissionRequest): RequestPermissionResponse {
  const options = params.options ?? [];
  const allowOpt = options.find((o) => o.kind === "allow_once" || o.kind === "allow_always");
  if (allowOpt) {
    return { outcome: { outcome: "selected", optionId: allowOpt.optionId } };
  }
  return { outcome: { outcome: "cancelled" } };
}

// ─── KiroSession ──────────────────────────────────────────────────────────────

type ChunkCallback = (text: string) => void;

/** Prompt exceeded the proxy-side timeout (should be under the gateway timeout). */
export class PromptTimeoutError extends Error {
  constructor(timeoutMs: number) {
    super(`kiro-cli prompt timed out after ${Math.round(timeoutMs / 1000)}s`);
    this.name = "PromptTimeoutError";
  }
}

/**
 * Default prompt *idle* timeout in ms.  The timer resets on every ACP
 * notification (tool_call, agent_message_chunk, metadata).  Only fires
 * when kiro-cli goes completely silent — meaning it's truly hung, not
 * just running a long build/compile.
 */
const DEFAULT_PROMPT_TIMEOUT_MS = 300_000; // 5 minutes of silence

export type KiroSessionOptions = {
  kiroBin: string;
  kiroArgs: string[];
  cwd: string;
  verbose: boolean;
  /** Per-prompt timeout in ms.  Default: 540 000 (9 min). */
  promptTimeoutMs?: number;
};

export type KiroSessionEvents = {
  onContextUsage?: (pct: number) => void;
  onActivity?: () => void;
};

export class KiroSession {
  private readonly log: (msg: string) => void;
  private readonly proc: ChildProcess;
  private readonly client: ClientSideConnection;
  private readonly events: KiroSessionEvents;
  private readonly promptTimeoutMs: number;

  /** Set during an active prompt() call; null otherwise. */
  private chunkCallback: ChunkCallback | null = null;

  acpSessionId = "";
  lastTouchedAt = Date.now();
  sentMessageCount = 0;
  consecutiveErrors = 0;
  lastContextPct = 0;

  private constructor(
    proc: ChildProcess,
    client: ClientSideConnection,
    log: (msg: string) => void,
    events: KiroSessionEvents,
    promptTimeoutMs: number,
  ) {
    this.proc = proc;
    this.client = client;
    this.log = log;
    this.events = events;
    this.promptTimeoutMs = promptTimeoutMs;
  }

  /** Spawn kiro, perform ACP handshake, and return a ready-to-use session. */
  static async create(
    opts: KiroSessionOptions,
    events: KiroSessionEvents = {},
  ): Promise<KiroSession> {
    const log = opts.verbose
      ? (msg: string) => process.stderr.write(`[kiro-session] ${msg}\n`)
      : () => {};

    // Spawn `kiro acp [extra-args]`
    const args = ["acp", ...opts.kiroArgs];
    log(`spawning: ${opts.kiroBin} ${args.join(" ")}`);

    const proc = spawn(opts.kiroBin, args, {
      stdio: ["pipe", "pipe", "inherit"],
      cwd: opts.cwd,
    });

    if (!proc.stdin || !proc.stdout) {
      throw new Error("[kiro-proxy] Failed to open stdio pipes to kiro process");
    }

    proc.on("error", (err) => {
      log(`process error: ${err.message}`);
    });

    const input = Writable.toWeb(proc.stdin);
    const output = Readable.toWeb(proc.stdout) as unknown as ReadableStream<Uint8Array>;
    const stream = ndJsonStream(input, output);

    // We need a reference to `session` inside the callback, but `session` is
    // created below.  Use a holder so the closure captures it lazily.
    const holder: { session: KiroSession | null } = { session: null };

    const client = new ClientSideConnection(
      () => ({
        sessionUpdate: async (notification: SessionNotification) => {
          holder.session?.handleSessionUpdate(notification);
        },
        requestPermission: async (params: RequestPermissionRequest) => {
          log(`permission requested: ${params.toolCall?.title ?? "unknown"}`);
          return autoApprovePermission(params);
        },
        extNotification: async (method: string, params: Record<string, unknown>) => {
          holder.session?.handleExtNotification(method, params);
        },
      }),
      stream,
    );

    const session = new KiroSession(
      proc,
      client,
      log,
      events,
      opts.promptTimeoutMs ?? DEFAULT_PROMPT_TIMEOUT_MS,
    );
    holder.session = session;

    // ACP handshake
    log("initializing ACP");
    await client.initialize({
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true,
      },
      clientInfo: { name: "openclaw-kiro-proxy", version: "1.0.0" },
    });

    log("creating ACP session");
    const acpSession = await client.newSession({
      cwd: opts.cwd,
      mcpServers: [],
    });
    session.acpSessionId = acpSession.sessionId;
    log(`session ready: ${acpSession.sessionId}`);

    return session;
  }

  /**
   * Timestamp of the last ACP notification received during the current
   * prompt.  Reset by handleSessionUpdate / handleExtNotification via
   * bumpPromptActivity().  The idle-timeout check compares against this.
   */
  private lastPromptActivityAt = 0;

  /** Called internally whenever ACP sends any notification during a prompt. */
  bumpPromptActivity(): void {
    this.lastPromptActivityAt = Date.now();
  }

  /** Send a text prompt and stream chunks to the provided callback. */
  async prompt(text: string, onChunk: ChunkCallback): Promise<string> {
    this.lastTouchedAt = Date.now();
    this.lastPromptActivityAt = Date.now();
    this.chunkCallback = onChunk;

    // Keep-alive: bump lastTouchedAt periodically while the prompt is in-flight
    // so the GC doesn't kill sessions with long-running tools (e.g. sleep + tmux).
    const keepAlive = setInterval(() => {
      this.lastTouchedAt = Date.now();
      this.events.onActivity?.();
    }, 60_000);

    try {
      const promptPromise = this.client.prompt({
        sessionId: this.acpSessionId,
        prompt: [{ type: "text", text }],
      });

      // Race against process death so we don't hang forever if kiro-cli crashes.
      const deathPromise = new Promise<never>((_, reject) => {
        const onExit = (code: number | null, signal: string | null) => {
          reject(new Error(`kiro-cli exited unexpectedly (code=${code}, signal=${signal})`));
        };
        this.proc.once("exit", onExit);
        promptPromise.finally(() => this.proc.removeListener("exit", onExit)).catch(() => {});
      });

      // Activity-aware idle timeout: instead of a fixed wall-clock timer,
      // poll every 30s and only fire if there has been NO ACP activity
      // (tool_call, chunk, metadata) for promptTimeoutMs.  This lets
      // long-running tool sessions (builds, compiles) run indefinitely
      // while still catching truly hung/dead sessions.
      const timeoutPromise = new Promise<never>((_, reject) => {
        const check = setInterval(() => {
          const idleMs = Date.now() - this.lastPromptActivityAt;
          if (idleMs >= this.promptTimeoutMs) {
            clearInterval(check);
            reject(new PromptTimeoutError(this.promptTimeoutMs));
          }
        }, 30_000);
        promptPromise.finally(() => clearInterval(check)).catch(() => {});
      });

      const response = await Promise.race([promptPromise, deathPromise, timeoutPromise]);
      return response.stopReason ?? "end_turn";
    } finally {
      clearInterval(keepAlive);
      this.chunkCallback = null;
    }
  }

  /** Called by the ACP stream for every notification from the kiro agent. */
  private handleSessionUpdate(notification: SessionNotification): void {
    const update = notification.update;
    if (!("sessionUpdate" in update)) {
      return;
    }

    // Any session update means the session is alive — bump idle timer.
    this.events.onActivity?.();
    this.bumpPromptActivity();

    switch (update.sessionUpdate) {
      case "agent_message_chunk": {
        if (update.content?.type === "text" && this.chunkCallback) {
          this.chunkCallback(update.content.text);
        }
        break;
      }
      case "tool_call": {
        this.log(`tool: ${update.title ?? "unknown"} (${update.status ?? ""})`);
        break;
      }
      default:
        break;
    }
  }

  /** Handle Kiro-specific extension notifications (e.g. _kiro.dev/*). */
  private handleExtNotification(method: string, params: Record<string, unknown>): void {
    if (method === "_kiro.dev/metadata") {
      const meta = params as KiroMetadata | undefined;
      if (meta?.contextUsagePercentage != null) {
        this.lastContextPct = meta.contextUsagePercentage;
        this.events.onContextUsage?.(meta.contextUsagePercentage);
        this.events.onActivity?.();
        this.bumpPromptActivity();
      }
      return;
    }
    // Silently ignore other _kiro.dev/* notifications (e.g. commands/available)
  }

  /** Kill the underlying kiro process. */
  kill(reason?: string): void {
    const rssKb = this.getRssKb();
    this.log(
      `killing process (pid ${this.proc.pid ?? "?"}) reason=${reason ?? "unknown"} exitCode=${this.proc.exitCode} signal=${this.proc.signalCode} rss=${rssKb != null ? `${Math.round(rssKb / 1024)}MB` : "?"}`,
    );
    this.proc.kill("SIGTERM");
    setTimeout(() => {
      if (!this.proc.killed) {
        this.proc.kill("SIGKILL");
      }
    }, 5_000);
  }

  get alive(): boolean {
    return !this.proc.killed && this.proc.exitCode === null;
  }

  get pid(): number | undefined {
    return this.proc.pid;
  }

  /** Read RSS in KB from /proc (Linux only). Returns undefined on failure. */
  getRssKb(): number | undefined {
    const pid = this.proc.pid;
    if (!pid) {
      return undefined;
    }
    try {
      const fs = require("node:fs") as typeof import("node:fs");
      const status = fs.readFileSync(`/proc/${pid}/status`, "utf8");
      const match = /VmRSS:\s+(\d+)\s+kB/.exec(status);
      return match ? Number(match[1]) : undefined;
    } catch {
      return undefined;
    }
  }
}
