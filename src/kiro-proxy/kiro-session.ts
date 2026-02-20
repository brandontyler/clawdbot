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

export type KiroSessionOptions = {
  kiroBin: string;
  kiroArgs: string[];
  cwd: string;
  verbose: boolean;
};

export class KiroSession {
  private readonly log: (msg: string) => void;
  private readonly proc: ChildProcess;
  private readonly client: ClientSideConnection;

  /** Set during an active prompt() call; null otherwise. */
  private chunkCallback: ChunkCallback | null = null;

  acpSessionId = "";
  lastTouchedAt = Date.now();
  sentMessageCount = 0;

  private constructor(
    proc: ChildProcess,
    client: ClientSideConnection,
    log: (msg: string) => void,
  ) {
    this.proc = proc;
    this.client = client;
    this.log = log;
  }

  /** Spawn kiro, perform ACP handshake, and return a ready-to-use session. */
  static async create(opts: KiroSessionOptions): Promise<KiroSession> {
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
      }),
      stream,
    );

    const session = new KiroSession(proc, client, log);
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

  /** Send a text prompt and stream chunks to the provided callback. */
  async prompt(text: string, onChunk: ChunkCallback): Promise<string> {
    this.lastTouchedAt = Date.now();
    this.chunkCallback = onChunk;

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

      const response = await Promise.race([promptPromise, deathPromise]);
      return response.stopReason ?? "end_turn";
    } finally {
      this.chunkCallback = null;
    }
  }

  /** Called by the ACP stream for every notification from the kiro agent. */
  private handleSessionUpdate(notification: SessionNotification): void {
    const update = notification.update;
    if (!("sessionUpdate" in update)) {
      return;
    }

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

  /** Kill the underlying kiro process. */
  kill(): void {
    this.log(`killing process (pid ${this.proc.pid ?? "?"})`);
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
}
