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
  /** Present in current kiro-cli; optional only for backward compatibility. */
  sessionId?: string;
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
  /**
   * Fires on compaction lifecycle events. Sourced from BOTH the modern
   * `session_info_update` (`_meta.kiro.kind` = summarization_*) notifications
   * (kiro-cli 2.8.1) AND the wrapper-compatible `_kiro.dev/compaction/status`
   * ext-notification. Events are de-duplicated in KiroSession before this
   * fires, so a subscriber sees each logical transition at most once per turn.
   *
   * `status`:
   *   - "started"   → compaction/summarization began (banner → "🧹 Compacting…")
   *   - "completed" → finished; `summary` is the transcript-replacement summary
   *   - "failed"    → compaction errored; in-progress state must be cleared so
   *                   the "Compacting" banner does not get stuck forever
   */
  onCompactionStatus?: (status: "started" | "completed" | "failed", summary?: string) => void;
};

export class KiroSession {
  private readonly log: (msg: string) => void;
  private readonly proc: ChildProcess;
  private readonly client: ClientSideConnection;
  private readonly events: KiroSessionEvents;

  /** Set during an active prompt() call; null otherwise. */
  private chunkCallback: ChunkCallback | null = null;

  /**
   * Set to true the moment the child process exits, regardless of who killed
   * it.  We can't rely on `proc.killed` alone because Node only flips that flag
   * when WE call `proc.kill()`; an external `kill <pid>` leaves it false until
   * `exitCode` is populated, which races with the next incoming request.  This
   * flag is the authoritative liveness check (see `get alive`).
   */
  private dead = false;

  acpSessionId = "";
  lastTouchedAt = Date.now();
  sentMessageCount = 0;
  consecutiveErrors = 0;
  consecutiveEmptyResponses = 0;
  lastContextPct = 0;
  /**
   * Compaction lifecycle de-duplication state.
   *
   * Kiro defines modern `session_info_update` (`_meta.kiro.kind`) events while
   * the CLI ACP wrapper also emits `_kiro.dev/compaction/status` compatibility
   * notifications. During a session LOAD, kiro-cli may also REPLAY historical
   * notifications from the persisted transcript. We must:
   *   1. fire each logical transition (started / completed / failed) at most once
   *      per live compaction, regardless of which event family delivered it;
   *   2. IGNORE a replayed `completed`/`failed` that has no matching live
   *      `started` in this session (otherwise a load would spuriously post a
   *      stale "Compacted" banner for a compaction that finished long ago).
   */
  private compactionInProgress = false;
  /** True once we have seen a live "started" this session (gates completed/failed). */
  private sawCompactionStarted = false;
  /** True while a prompt() call is in-flight (GC must never kill). */
  isPrompting = false;
  /** Epoch ms when the current prompt started (null when idle). */
  promptStartedAt: number | null = null;
  /** True if this session was restored via loadSession (not freshly created). */
  wasLoaded = false;
  /**
   * True once this session has successfully streamed at least one first-token
   * back to the gateway.  Used to apply a more generous timeout to the very
   * first turn after a fresh ACP spawn (cold-start: workspace scan + skill
   * discovery + memory load + steering files all happen before the model can
   * reason).  Once flipped to true, the warm-session timeout floor applies.
   */
  hasStreamedFirstToken = false;

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

    // Mark the session dead the instant the OS reports the child gone.
    // Without this, `alive` lies after an external kill (proc.killed stays
    // false) and the next incoming request tries to prompt a corpse, surfacing
    // as "ACP connection closed" → "consecutive errors" → auto-reset.
    this.proc.once("exit", (code, signal) => {
      this.dead = true;
      this.log(`process exited: code=${code} signal=${signal}`);
    });
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

    // ACP handshake (load path).
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

    // Set the expected ID BEFORE loadSession: kiro-cli replays session metadata
    // during the load call, and foreign subagent updates must not be mistaken
    // for this parent session's context usage.
    session.acpSessionId = acpSessionId;
    log(`loading ACP session: ${acpSessionId}`);
    try {
      await client.loadSession({
        sessionId: acpSessionId,
        cwd: opts.cwd,
        mcpServers: [],
      });
      session.wasLoaded = true;
      log(`session loaded: ${acpSessionId}`);
    } catch (err) {
      log(`loadSession failed (${String(err)}), falling back to newSession`);
      // The replacement session ID is unknown until newSession returns. Clear
      // the failed load ID so its initial notifications are not filtered out.
      session.acpSessionId = "";
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
  async prompt(
    text: string,
    onChunk: ChunkCallback,
    images?: ReadonlyArray<{ data: string; mimeType: string }>,
  ): Promise<string> {
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
      // Build ACP prompt content blocks. Images first so the model has the
      // visual context before the textual instruction (matches IDE drag/drop).
      // kiro-cli advertises promptCapabilities.image:true; this is the
      // path that actually feeds vision into the model context (the read-tool
      // Image mode is broken for ACP — see kirodotdev/Kiro#6937).
      const promptContent: Array<
        { type: "text"; text: string } | { type: "image"; data: string; mimeType: string }
      > = [];
      if (images && images.length > 0) {
        for (const img of images) {
          promptContent.push({ type: "image", data: img.data, mimeType: img.mimeType });
        }
      }
      promptContent.push({ type: "text", text });

      const promptPromise = this.client.prompt({
        sessionId: this.acpSessionId,
        prompt: promptContent,
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
    if (this.isForeignSessionId(Reflect.get(notification as object, "sessionId"))) {
      return;
    }
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
        // Signal liveness to clear first-token timeout — tool_call means
        // kiro-cli is alive and working, even if no text has been emitted yet.
        if (this.chunkCallback) {
          this.chunkCallback("");
        }
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
      case "session_info_update": {
        // kiro-cli 2.8.1 delivers context-usage + compaction lifecycle through
        // this update carrying a namespaced `_meta.kiro` payload. The `_meta`
        // may ride on the update object OR on the enclosing notification, so
        // check both (notification takes precedence when both are present).
        const meta = this.extractKiroMeta(
          Reflect.get(notification as object, "_meta"),
          Reflect.get(update as object, "_meta"),
        );
        if (meta) {
          this.handleKiroSessionMeta(meta);
        }
        break;
      }
      default:
        break;
    }
  }

  /** Ignore updates for child/subagent sessions sharing this ACP connection. */
  private isForeignSessionId(sessionId: unknown): boolean {
    return (
      typeof sessionId === "string" &&
      this.acpSessionId.length > 0 &&
      sessionId !== this.acpSessionId
    );
  }

  /**
   * Pull the `kiro` namespace out of one or more ACP `_meta` bags. The modern
   * event may carry it on the notification or on the update object; we prefer
   * the notification-level bag but fall back to the update-level one.
   */
  private extractKiroMeta(...bags: unknown[]): Record<string, unknown> | null {
    for (const bag of bags) {
      if (bag && typeof bag === "object") {
        const kiro = (bag as { kiro?: unknown }).kiro;
        if (kiro && typeof kiro === "object") {
          return kiro as Record<string, unknown>;
        }
      }
    }
    return null;
  }

  /**
   * Handle a modern `_meta.kiro` payload from a `session_info_update`.
   *
   * Discriminates on `_meta.kiro.kind`:
   *   - "context_usage"          → update lastContextPct + notify listeners
   *   - "summarization_started"  → compaction began
   *   - "summarization_completed"→ compaction finished (with replacement summary)
   *   - "summarization_failed"   → compaction errored (must clear in-progress)
   *
   * Context percentage is read from any of the fields kiro-cli has used across
   * versions (`percentage`, `contextUsagePercentage`, `usagePercentage`) so we
   * stay resilient to minor key drift.
   */
  private handleKiroSessionMeta(kiro: Record<string, unknown>): void {
    const kind = typeof kiro.kind === "string" ? kiro.kind : undefined;
    if (!kind) {
      return;
    }
    this.log(`session_info_update: kiro.kind=${kind}`);
    switch (kind) {
      case "context_usage": {
        const pct = this.readPct(kiro);
        if (pct != null) {
          this.lastContextPct = pct;
          this.events.onContextUsage?.(pct);
          this.events.onActivity?.();
        }
        return;
      }
      case "summarization_started": {
        this.emitCompactionStatus("started");
        return;
      }
      case "summarization_completed": {
        // 2.8.1 uses conversationSummary; retain summary as compatibility for
        // older preview builds that used the shorter field name.
        const summary =
          typeof kiro.conversationSummary === "string"
            ? kiro.conversationSummary
            : typeof kiro.summary === "string"
              ? kiro.summary
              : undefined;
        this.emitCompactionStatus("completed", summary);
        return;
      }
      case "summarization_failed": {
        this.emitCompactionStatus("failed");
        return;
      }
      default:
        return;
    }
  }

  /** Extract a context-usage percentage from a kiro meta bag, if present. */
  private readPct(kiro: Record<string, unknown>): number | null {
    for (const key of ["percentage", "contextUsagePercentage", "usagePercentage"]) {
      const v = kiro[key];
      if (typeof v === "number" && Number.isFinite(v)) {
        return v;
      }
    }
    return null;
  }

  /**
   * De-duplicated compaction-lifecycle emitter. Both the modern
   * `session_info_update` path and the legacy `_kiro.dev/compaction/status`
   * path funnel through here so a subscriber sees each transition once.
   *
   * Rules:
   *   - "started": ignore if one is already in progress; else mark in-progress
   *     and remember we saw a LIVE start this session.
   *   - "completed"/"failed": ignore replays that were never preceded by a live
   *     "started" (guards against kiro-cli replaying old transcript events on
   *     session load). On a real terminal event, clear in-progress state so the
   *     "Compacting" banner can never get stuck.
   */
  private emitCompactionStatus(status: "started" | "completed" | "failed", summary?: string): void {
    if (status === "started") {
      if (this.compactionInProgress) {
        this.log("compaction started ignored (already in progress)");
        return;
      }
      this.compactionInProgress = true;
      this.sawCompactionStarted = true;
      this.events.onCompactionStatus?.("started");
      return;
    }
    // completed | failed
    if (!this.compactionInProgress && !this.sawCompactionStarted) {
      this.log(`compaction ${status} ignored (no live start seen — likely replayed)`);
      return;
    }
    if (!this.compactionInProgress) {
      // We saw a start earlier this session but already handled its terminal
      // event; a duplicate completed/failed for the same run is a no-op.
      this.log(`compaction ${status} ignored (already finalized)`);
      return;
    }
    this.compactionInProgress = false;
    this.sawCompactionStarted = false;
    this.events.onCompactionStatus?.(status, summary);
  }

  /**
   * Resolve a lifecycle whose terminal event never arrived. The manager calls
   * this only after observing a real context drop or a bounded timeout, so the
   * session cannot remain permanently marked as compacting.
   */
  settleCompactionTracking(status: "completed" | "failed"): void {
    if (!this.compactionInProgress) {
      return;
    }
    this.log(`compaction tracking settled by proxy: ${status}`);
    this.compactionInProgress = false;
    this.sawCompactionStarted = false;
    this.events.onCompactionStatus?.(status);
  }

  /** Handle Kiro-specific extension notifications (e.g. _kiro.dev/*). */
  private handleExtNotification(method: string, params: Record<string, unknown>): void {
    // kiro-cli multiplexes parent and subagent extension notifications over the
    // same ACP connection. Without this guard, a child at 6% can overwrite a
    // 70% parent context reading and make compaction appear to happen early.
    if (this.isForeignSessionId(params.sessionId)) {
      return;
    }
    if (method === "_kiro.dev/metadata") {
      const meta = params as KiroMetadata | undefined;
      if (meta?.contextUsagePercentage != null) {
        this.lastContextPct = meta.contextUsagePercentage;
        this.events.onContextUsage?.(meta.contextUsagePercentage);
        this.events.onActivity?.();
      }
      return;
    }
    if (method === "_kiro.dev/compaction/status") {
      // Compatibility path: the installed kiro-cli 2.8.1 ACP wrapper still
      // emits this alongside the modern KAS `session_info_update` contract.
      // Both are kept and de-duplicated via emitCompactionStatus() for wrapper
      // version compatibility and session-load replays.
      //
      // Shape (verified 2026-07-01, kiro-cli 2.6.0):
      //   { sessionId: "…", status: { type: "started" | "completed" }, summary: string | null }
      // ACP `session/prompt` for `/compact` returns almost immediately with
      // stopReason:"end_turn", but kiro-cli keeps working in the background
      // and only emits `completed` (with the transcript-replacement summary)
      // when compaction actually finishes — often 60+ seconds later. Without
      // this hook the Discord progress banner freezes at the pre-compaction
      // "🔧 Working... N% ctx" state because ProgressReporter never sees a
      // tool_call event to update on and finish() ran too early.
      const p = params as { status?: { type?: string }; summary?: unknown };
      const type = p.status?.type;
      const summary = typeof p.summary === "string" ? p.summary : undefined;
      // Funnel the legacy event through the SAME de-dup gate as the modern
      // `session_info_update` path so a build that somehow emits both families
      // (or replays the legacy one on load) fires each transition just once.
      if (type === "started" || type === "completed" || type === "failed") {
        this.emitCompactionStatus(type, summary);
      }
      this.log(
        `ext-notification: ${method} type=${type ?? "?"} summaryLen=${summary?.length ?? 0}`,
      );
      return;
    }
    // Log other _kiro.dev/* notifications for discovery
    if (method === "_kiro.dev/commands/available") {
      this.log(`ext-notification: ${method} ${JSON.stringify(params)}`);
    } else {
      this.log(`ext-notification: ${method} ${JSON.stringify(params).slice(0, 300)}`);
    }
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
    return !this.dead && !this.proc.killed && this.proc.exitCode === null;
  }

  /** True while kiro-cli is actively compacting this conversation. */
  get isCompacting(): boolean {
    return this.compactionInProgress;
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
