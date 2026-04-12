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

// ─── Child process cleanup ────────────────────────────────────────────────────

import { readFileSync } from "node:fs";

const EXPECTED_CHILD_COMM = "kiro-cli-chat";

/** Read /proc/<pid>/comm and return the trimmed process name, or null. */
function readProcComm(pid: number): string | null {
  try {
    return readFileSync(`/proc/${pid}/comm`, "utf8").trim();
  } catch {
    return null;
  }
}

/**
 * Return child PIDs of `parentPid` that are verified `kiro-cli-chat` processes.
 * Reads from /proc — returns [] on non-Linux or if the parent already exited.
 */
function getVerifiedChildPids(parentPid: number, log: (msg: string) => void): number[] {
  let raw: string;
  try {
    raw = readFileSync(`/proc/${parentPid}/task/${parentPid}/children`, "utf8").trim();
  } catch {
    return [];
  }
  if (!raw) {
    return [];
  }

  const verified: number[] = [];
  for (const token of raw.split(/\s+/)) {
    const childPid = Number(token);
    if (!childPid) {
      continue;
    }
    const comm = readProcComm(childPid);
    if (comm === EXPECTED_CHILD_COMM) {
      verified.push(childPid);
    } else {
      log(`child pid ${childPid} comm="${comm}" — skipping (expected ${EXPECTED_CHILD_COMM})`);
    }
  }
  return verified;
}

/** Send SIGTERM to a child PID after re-verifying its identity, with SIGKILL fallback. */
function killVerifiedChild(childPid: number, log: (msg: string) => void): void {
  // Re-check identity right before signaling (guards against PID recycling).
  const comm = readProcComm(childPid);
  if (comm !== EXPECTED_CHILD_COMM) {
    log(`child pid ${childPid} identity changed to "${comm}" before kill — skipping`);
    return;
  }
  try {
    log(`killing child kiro-cli-chat (pid ${childPid})`);
    process.kill(childPid, "SIGTERM");
  } catch {
    return; // already dead
  }
  setTimeout(() => {
    // Final identity check before SIGKILL — PID could have been recycled during the 5s wait.
    const commNow = readProcComm(childPid);
    if (commNow !== EXPECTED_CHILD_COMM) {
      return;
    }
    try {
      process.kill(childPid, "SIGKILL");
    } catch {
      // already dead
    }
  }, 5_000);
}

export type KiroSessionOptions = {
  kiroBin: string;
  kiroArgs: string[];
  cwd: string;
  verbose: boolean;
};

export type KiroSessionEvents = {
  onContextUsage?: (pct: number) => void;
  onActivity?: () => void;
  onToolCall?: (title: string, kind: string, status: string, isNew: boolean) => void;
  onPromptStart?: () => void;
  onPromptEnd?: () => void;
};

export class KiroSession {
  private readonly log: (msg: string) => void;
  private readonly proc: ChildProcess;
  private readonly client: ClientSideConnection;
  private readonly events: KiroSessionEvents;

  /** Set during an active prompt() call; null otherwise. */
  private chunkCallback: ChunkCallback | null = null;

  acpSessionId = "";
  lastTouchedAt = Date.now();
  sentMessageCount = 0;
  consecutiveErrors = 0;
  consecutiveEmptyResponses = 0;
  lastContextPct = 0;
  /** True while a prompt() call is in-flight (GC must never kill). */
  isPrompting = false;
  /** Epoch ms when the current prompt started (null when idle). */
  promptStartedAt: number | null = null;
  /** True if this session was restored via loadSession (not freshly created). */
  wasLoaded = false;

  private constructor(
    proc: ChildProcess,
    client: ClientSideConnection,
    log: (msg: string) => void,
    events: KiroSessionEvents,
  ) {
    this.proc = proc;
    this.client = client;
    this.log = log;
    this.events = events;
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

    const session = new KiroSession(proc, client, log, events);
    holder.session = session;

    // ACP handshake
    log("initializing ACP");
    const initResult = await client.initialize({
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true,
      },
      clientInfo: { name: "openclaw-kiro-proxy", version: "1.0.0" },
    });
    log(
      `agent: ${initResult.agentInfo?.name ?? "unknown"} v${initResult.agentInfo?.version ?? "?"} capabilities=${JSON.stringify(initResult.agentCapabilities ?? {})}`,
    );

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
   * Spawn kiro, perform ACP handshake, and LOAD an existing session by ID.
   * Falls back to a fresh session if loadSession fails.
   */
  static async load(
    acpSessionId: string,
    opts: KiroSessionOptions,
    events: KiroSessionEvents = {},
  ): Promise<KiroSession> {
    const log = opts.verbose
      ? (msg: string) => process.stderr.write(`[kiro-session] ${msg}\n`)
      : () => {};

    const args = ["acp", ...opts.kiroArgs];
    log(`spawning (load): ${opts.kiroBin} ${args.join(" ")}`);

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

    const session = new KiroSession(proc, client, log, events);
    holder.session = session;

    log("initializing ACP");
    const initResult = await client.initialize({
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true,
      },
      clientInfo: { name: "openclaw-kiro-proxy", version: "1.0.0" },
    });
    log(
      `agent: ${initResult.agentInfo?.name ?? "unknown"} v${initResult.agentInfo?.version ?? "?"} capabilities=${JSON.stringify(initResult.agentCapabilities ?? {})}`,
    );

    log(`loading ACP session: ${acpSessionId}`);
    try {
      await client.loadSession({
        sessionId: acpSessionId,
        cwd: opts.cwd,
        mcpServers: [],
      });
      session.acpSessionId = acpSessionId;
      session.wasLoaded = true;
      log(`session loaded: ${acpSessionId}`);
    } catch (err) {
      log(`loadSession failed (${String(err)}), falling back to newSession`);
      const acpSession = await client.newSession({
        cwd: opts.cwd,
        mcpServers: [],
      });
      session.acpSessionId = acpSession.sessionId;
      log(`fallback session ready: ${acpSession.sessionId}`);
    }

    return session;
  }

  /** Send a text prompt and stream chunks to the provided callback. */
  async prompt(text: string, onChunk: ChunkCallback): Promise<string> {
    this.lastTouchedAt = Date.now();
    this.isPrompting = true;
    this.promptStartedAt = Date.now();
    this.chunkCallback = onChunk;
    this.events.onPromptStart?.();

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
      // This is the ONLY guard — no idle timeout.  kiro-cli sends zero ACP
      // notifications while a shell command is running, so any idle timer
      // would kill long-running tools (deploys, builds, compiles).  If the
      // process is truly hung, the operator can kill it manually; we never
      // kill a working session.
      const deathPromise = new Promise<never>((_, reject) => {
        const onExit = (code: number | null, signal: string | null) => {
          reject(new Error(`kiro-cli exited unexpectedly (code=${code}, signal=${signal})`));
        };
        this.proc.once("exit", onExit);
        promptPromise.finally(() => this.proc.removeListener("exit", onExit)).catch(() => {});
      });

      const response = await Promise.race([promptPromise, deathPromise]);
      return response.stopReason ?? "end_turn";
    } finally {
      clearInterval(keepAlive);
      this.isPrompting = false;
      this.promptStartedAt = null;
      this.chunkCallback = null;
      this.events.onPromptEnd?.();
    }
  }

  /** Called by the ACP stream for every notification from the kiro agent. */
  private handleSessionUpdate(notification: SessionNotification): void {
    const update = notification.update;
    if (!("sessionUpdate" in update)) {
      return;
    }

    // Any session update means the session is alive — bump GC timer.
    this.events.onActivity?.();

    switch (update.sessionUpdate) {
      case "agent_message_chunk": {
        if (update.content?.type === "text" && this.chunkCallback) {
          this.chunkCallback(update.content.text);
        }
        break;
      }
      case "tool_call": {
        const title = update.title ?? "unknown";
        const kind = update.kind ?? "";
        const status = update.status ?? "";
        this.log(`tool: ${title} (${status || kind})`);
        this.events.onToolCall?.(title, kind, status, true);
        break;
      }
      case "tool_call_update": {
        const title = update.title ?? "";
        const kind = update.kind ?? "";
        const status = update.status ?? "";
        if (title || status) {
          this.events.onToolCall?.(title, kind, status, false);
        }
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
      }
      return;
    }
    // Silently ignore other _kiro.dev/* notifications (e.g. commands/available)
  }

  /** Send ACP session/cancel to interrupt an in-flight prompt. */
  async cancel(): Promise<void> {
    if (!this.isPrompting || !this.acpSessionId) {
      return;
    }
    this.log(`cancelling session ${this.acpSessionId}`);
    try {
      await this.client.cancel({ sessionId: this.acpSessionId });
    } catch (err) {
      this.log(`cancel failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  /** Kill the underlying kiro process and any verified kiro-cli-chat children. */
  kill(reason?: string): void {
    const pid = this.proc.pid;
    const rssKb = this.getRssKb();
    this.log(
      `killing process (pid ${pid ?? "?"}) reason=${reason ?? "unknown"} exitCode=${this.proc.exitCode} signal=${this.proc.signalCode} rss=${rssKb != null ? `${Math.round(rssKb / 1024)}MB` : "?"}`,
    );

    // Snapshot verified child PIDs BEFORE killing the wrapper, because once
    // the wrapper dies the children get reparented to init and we lose the
    // parent→child link in /proc.
    const childPids = pid != null ? getVerifiedChildPids(pid, this.log) : [];
    this.proc.kill("SIGTERM");
    setTimeout(() => {
      if (!this.proc.killed) {
        this.proc.kill("SIGKILL");
      }
    }, 5_000);

    // Kill each verified child.  Re-check identity at signal time to guard
    // against PID recycling between the snapshot and the kill.
    for (const childPid of childPids) {
      killVerifiedChild(childPid, this.log);
    }
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
      const status = readFileSync(`/proc/${pid}/status`, "utf8");
      const match = /VmRSS:\s+(\d+)\s+kB/.exec(status);
      return match ? Number(match[1]) : undefined;
    } catch {
      return undefined;
    }
  }
}
