/**
 * HTTP server — OpenAI-compatible API backed by kiro CLI.
 *
 * Endpoints:
 *   POST /v1/chat/completions   — main inference endpoint (stream + blocking)
 *   GET  /v1/models             — returns the single "kiro-default" model
 *   GET  /health                — liveness probe
 *
 * Usage by pi-ai (OpenClaw's model layer):
 *   pi-ai treats this as a plain openai-completions provider.  It sends a
 *   standard POST with {model, messages, stream:true} and reads back an SSE
 *   stream.  We translate that into ACP prompt() calls against kiro.
 */

import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { SessionManager, isInvalidHistoryError } from "./session-manager.js";
import type {
  KiroProxyOptions,
  OpenAIChatRequest,
  OpenAIChunk,
  OpenAICompletion,
  OpenAIMessage,
} from "./types.js";

const KIRO_MODEL_ID = "kiro-default";

/** Auto-reset a session after this many consecutive prompt failures. */
const MAX_CONSECUTIVE_ERRORS = 3;

/** Delay (ms) between recovery attempt 1 and 2 to let resources settle. */
const RECOVERY_BACKOFF_MS = 5000;

/**
 * Prefixed to the user's message during auto-recovery so the fresh session
 * doesn't immediately repeat the heavy tool use that caused the corruption.
 */
const RECOVERY_PREAMBLE =
  "[System: This is an auto-recovered session. The previous attempt crashed " +
  "mid-tool-execution. Do NOT write large files in this response. Instead, " +
  "summarize what you were doing and ask the user to confirm before retrying " +
  "any file writes.]\n\n";

/**
 * Last-resort prompt when the first recovery also crashes.  Contains NO
 * user content — just a harmless greeting that cannot trigger heavy tool use.
 * This breaks the doom loop: the session comes up clean, and the *next*
 * user message proceeds normally.
 */
const FALLBACK_RECOVERY_PROMPT =
  "[System: The previous session crashed and recovery also failed. " +
  "Start fresh. Do NOT use any tools. Just greet the user and let them " +
  "know the session was reset — they should resend their request.]";

/** Format an error with full stack for diagnostic logging. */
function formatErrorVerbose(err: unknown, label: string): string {
  if (err instanceof Error) {
    const stack = err.stack ?? `${err.name}: ${err.message}`;
    return `${label}: ${stack}`;
  }
  return `${label}: ${JSON.stringify(err)}`;
}

/** Extract a short, user-facing summary from a kiro-cli stream error. */
function extractStreamErrorSummary(err: unknown): string {
  const raw =
    err instanceof Error ? err.message : typeof err === "string" ? err : JSON.stringify(err);
  if (/InternalServerError|Internal error/i.test(raw)) {
    return " (InternalServerError)";
  }
  if (/timeout/i.test(raw)) {
    return " (timeout)";
  }
  if (/rate.?limit|throttl/i.test(raw)) {
    return " (rate limited)";
  }
  if (/context.*(length|limit|overflow)/i.test(raw)) {
    return " (context overflow)";
  }
  return "";
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ─── Persistent corruption log ────────────────────────────────────────────────

const CORRUPTION_LOG_DIR = `${process.env.HOME}/code/personal/clawdbot/logs`;
const CORRUPTION_LOG_PATH = `${CORRUPTION_LOG_DIR}/corruption-events.jsonl`;

/** Kiro-cli emits this message inline in the response stream when its internal session corrupts. */
const KIRO_CLI_CORRUPTION_MARKER = "Session history became corrupted";

type CorruptionEvent = {
  sessionKey: string;
  phase: string;
  error: unknown;
  messageCount: number;
  incomingChars: number;
  latestUserMessage?: string;
  /** Full response text accumulated before corruption was detected. */
  responseText?: string;
  /** ACP session ID from kiro-cli. */
  acpSessionId?: string;
  /** kiro-cli process PID. */
  pid?: number;
  /** RSS in MB at time of corruption. */
  rssMb?: number;
  /** Context usage % reported by kiro-cli. */
  contextPct?: number;
  /** How many messages the proxy had sent to this ACP session. */
  sentMessageCount?: number;
  /** How many consecutive errors this session had before this event. */
  consecutiveErrors?: number;
  /** Wall-clock ms from prompt start to corruption detection. */
  elapsedMs?: number;
  /** The prompt text that was sent to kiro-cli. */
  promptText?: string;
  /** Per-role message counts from the incoming OpenAI payload. */
  roleCounts?: Record<string, number>;
};

/** Append a structured corruption event to a persistent log that survives proxy restarts. */
function logCorruptionEvent(event: CorruptionEvent): void {
  try {
    mkdirSync(CORRUPTION_LOG_DIR, { recursive: true });
    const entry = {
      ts: new Date().toISOString(),
      session: event.sessionKey.slice(0, 24),
      phase: event.phase,
      error:
        event.error instanceof Error
          ? { name: event.error.name, message: event.error.message, stack: event.error.stack }
          : typeof event.error === "object" && event.error !== null
            ? event.error
            : String(event.error),
      msgs: event.messageCount,
      chars: event.incomingChars,
      lastMsg: event.latestUserMessage?.slice(0, 500),
      responseText: event.responseText?.slice(-2000),
      acpSessionId: event.acpSessionId,
      pid: event.pid,
      rssMb: event.rssMb,
      contextPct: event.contextPct,
      sentMessageCount: event.sentMessageCount,
      consecutiveErrors: event.consecutiveErrors,
      elapsedMs: event.elapsedMs,
      promptText: event.promptText?.slice(0, 1000),
      roleCounts: event.roleCounts,
    };
    appendFileSync(CORRUPTION_LOG_PATH, JSON.stringify(entry) + "\n");
  } catch {
    // Best-effort — don't crash the proxy over logging.
  }
}

/** Build a full diagnostic snapshot for a corruption event. */
function buildCorruptionDiagnostics(
  session: import("./kiro-session.js").KiroSession,
  managed: { handle: { sentMessageCount: number } },
  opts: {
    sessionKey: string;
    phase: string;
    error: unknown;
    messages: OpenAIMessage[];
    incomingChars: number;
    promptText: string;
    responseText: string;
    elapsedMs: number;
  },
): CorruptionEvent {
  const rssKb = session.getRssKb();
  const roleCounts: Record<string, number> = {};
  for (const m of opts.messages) {
    roleCounts[m.role] = (roleCounts[m.role] ?? 0) + 1;
  }
  return {
    sessionKey: opts.sessionKey,
    phase: opts.phase,
    error: opts.error,
    messageCount: opts.messages.length,
    incomingChars: opts.incomingChars,
    latestUserMessage: (() => {
      const c = opts.messages.findLast((m) => m.role === "user")?.content;
      if (typeof c === "string") {
        return c.slice(0, 500);
      }
      if (Array.isArray(c)) {
        return JSON.stringify(c).slice(0, 500);
      }
      return c != null ? String(c) : undefined;
    })(),
    responseText: opts.responseText,
    acpSessionId: session.acpSessionId,
    pid: session.pid,
    rssMb: rssKb != null ? Math.round(rssKb / 1024) : undefined,
    contextPct: session.lastContextPct,
    sentMessageCount: managed.handle.sentMessageCount,
    consecutiveErrors: session.consecutiveErrors,
    elapsedMs: opts.elapsedMs,
    promptText: opts.promptText,
    roleCounts,
  };
}

// ─── SSE helpers ──────────────────────────────────────────────────────────────

function sseChunk(res: ServerResponse, data: object): void {
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

function sseDone(res: ServerResponse): void {
  res.write("data: [DONE]\n\n");
  res.end();
}

function buildChunk(completionId: string, content: string): OpenAIChunk {
  return {
    id: completionId,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: KIRO_MODEL_ID,
    choices: [{ index: 0, delta: { content }, finish_reason: null }],
  };
}

function buildFinalChunk(
  completionId: string,
  finishReason: "stop" | "length" = "stop",
): OpenAIChunk {
  return {
    id: completionId,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: KIRO_MODEL_ID,
    choices: [{ index: 0, delta: {}, finish_reason: finishReason }],
  };
}

// ─── Request parsing ──────────────────────────────────────────────────────────

async function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function parseJsonBody(raw: string): OpenAIChatRequest {
  const parsed = JSON.parse(raw) as OpenAIChatRequest;
  if (!Array.isArray(parsed.messages) || parsed.messages.length === 0) {
    throw new Error("messages must be a non-empty array");
  }
  return parsed;
}

// ─── Route handlers ───────────────────────────────────────────────────────────

function handleHealth(res: ServerResponse): void {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ status: "ok", service: "kiro-proxy" }));
}

function handleModels(res: ServerResponse): void {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(
    JSON.stringify({
      object: "list",
      data: [
        {
          id: KIRO_MODEL_ID,
          object: "model",
          created: 0,
          owned_by: "kiro",
        },
      ],
    }),
  );
}

async function handleCompletions(
  req: IncomingMessage,
  res: ServerResponse,
  manager: SessionManager,
  log: (msg: string) => void,
): Promise<void> {
  // Parse request body
  let body: OpenAIChatRequest;
  try {
    const raw = await readBody(req);
    body = parseJsonBody(raw);
  } catch (err) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: String(err), type: "invalid_request_error" } }));
    return;
  }

  const t0 = performance.now();
  const wantStream = body.stream !== false;
  const completionId = `kiro-${randomUUID()}`;

  // Resolve session key: prefer explicit headers/fields, then fingerprint.
  const openclawSessionKey = req.headers["x-openclaw-session-key"] as string | undefined;
  const explicitKey =
    (req.headers["x-kiro-session-id"] as string | undefined) ?? openclawSessionKey ?? body.user;
  const sessionKey = SessionManager.resolveSessionKey(body.messages, explicitKey);
  const sessionTag = sessionKey.slice(0, 8);

  log(`${wantStream ? "stream" : "sync"} session=${sessionTag}… msgs=${body.messages.length}`);

  // Pre-flight context size check: estimate the incoming payload size from
  // OpenClaw's message history.  If it's very large, the gateway may not have
  // compacted yet (or compaction failed).  Log a warning so we have visibility
  // — the kiro-proxy can't trigger OpenClaw compaction, but the diagnostic
  // helps explain slow turns or timeouts.
  const incomingChars = body.messages.reduce(
    (sum, m) =>
      sum + (typeof m.content === "string" ? m.content.length : JSON.stringify(m.content).length),
    0,
  );
  if (incomingChars > 500_000) {
    log(
      `pre-flight WARNING: incoming payload very large (${Math.round(incomingChars / 1000)}K chars, ${body.messages.length} msgs) session=${sessionTag}… — gateway may need compaction`,
    );
  } else if (incomingChars > 200_000) {
    log(
      `pre-flight: large payload (${Math.round(incomingChars / 1000)}K chars, ${body.messages.length} msgs) session=${sessionTag}…`,
    );
  }

  // Pre-flight role-balance check: if user messages outnumber assistant messages
  // by more than 2, the gateway history is poisoned (e.g. from prior empty
  // responses that got pruned).  Reset proactively instead of letting kiro-cli
  // reject the history later.
  const userCount = body.messages.filter((m) => m.role === "user").length;
  const assistantCount = body.messages.filter((m) => m.role === "assistant").length;
  if (userCount - assistantCount > 2 && body.messages.length > 10) {
    log(
      `🟠 pre-flight: role imbalance detected (user=${userCount} assistant=${assistantCount}) session=${sessionTag}… — history likely poisoned`,
    );
  }

  // Get or create Kiro ACP session
  let sessionResult: Awaited<ReturnType<SessionManager["getOrCreate"]>>;
  try {
    sessionResult = await manager.getOrCreate(sessionKey, body.messages, openclawSessionKey);
  } catch (err) {
    log(`session error: ${String(err)}`);
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: {
          message: `Failed to start kiro session: ${String(err)}`,
          type: "service_unavailable",
        },
      }),
    );
    return;
  }

  const { session, promptText, managed } = sessionResult;
  const tSession = performance.now();
  log(`timing: session=${sessionTag}… resolve=${Math.round(tSession - t0)}ms`);

  if (!promptText.trim()) {
    // Nothing new to send (e.g. only assistant messages in the delta)
    res.writeHead(200, { "Content-Type": "application/json" });
    const completion: OpenAICompletion = {
      id: completionId,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: KIRO_MODEL_ID,
      choices: [{ index: 0, message: { role: "assistant", content: "" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
    };
    res.end(JSON.stringify(completion));
    return;
  }

  if (wantStream) {
    // ── Streaming response ────────────────────────────────────────────────
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });

    // Send role header chunk first (matches OpenAI spec)
    sseChunk(res, {
      ...buildChunk(completionId, ""),
      choices: [{ index: 0, delta: { role: "assistant" }, finish_reason: null }],
    });

    // Cancel the ACP prompt if the HTTP client disconnects mid-stream.
    let clientDisconnected = false;
    const onClose = () => {
      clientDisconnected = true;
      log(`client disconnected mid-stream: session=${sessionTag}… — sending ACP cancel`);
      session.cancel().catch(() => {});
    };
    req.once("close", onClose);

    let resolvePromptLock: () => void;
    managed.promptLock = new Promise((r) => {
      resolvePromptLock = r;
    });

    let wasMaxTokens = false;
    let tFirstChunk = 0;
    const responseChunks: string[] = [];
    try {
      const stopReason = await session.prompt(promptText, (text) => {
        if (!tFirstChunk) {
          tFirstChunk = performance.now();
        }
        responseChunks.push(text);
        sseChunk(res, buildChunk(completionId, text));
      });
      session.consecutiveErrors = 0;

      // When the model hits its output token limit, append a visible notice
      // so the user knows the response was cut short and can ask to continue.
      wasMaxTokens = stopReason === "max_tokens";
      if (wasMaxTokens && responseChunks.length > 0) {
        const notice =
          '\n\n⚠️ *Response truncated — output token limit reached. Say "continue" to pick up where I left off.*';
        sseChunk(res, buildChunk(completionId, notice));
        log(`⚠️ max_tokens: session=${sessionTag}… responseLen=${responseChunks.join("").length}`);
      }

      // Detect kiro-cli inline corruption message in the completed response.
      const fullResponse = responseChunks.join("");
      if (fullResponse.includes(KIRO_CLI_CORRUPTION_MARKER)) {
        const elapsed = performance.now() - t0;
        log(
          `🔴 KIRO-CLI CORRUPTION DETECTED IN STREAM: session=${sessionTag}… elapsed=${Math.round(elapsed)}ms responseLen=${fullResponse.length} ctx=${session.lastContextPct.toFixed(1)}%`,
        );
        const diag = buildCorruptionDiagnostics(session, managed, {
          sessionKey,
          phase: "stream-inline-corruption",
          error: "kiro-cli emitted corruption marker in response stream",
          messages: body.messages,
          incomingChars,
          promptText,
          responseText: fullResponse,
          elapsedMs: Math.round(elapsed),
        });
        logCorruptionEvent(diag);
        log(`🔴 CORRUPTION DIAG: ${JSON.stringify(diag, null, 2)}`);
      }

      // Detect silent empty response — ACP returned 0 tokens without throwing.
      // Retry once on the same session before counting it as a failure.
      if (!fullResponse.trim() && promptText.trim()) {
        const elapsed = performance.now() - t0;
        log(
          `🟡 EMPTY ACP RESPONSE — retrying once: session=${sessionTag}… elapsed=${Math.round(elapsed)}ms promptLen=${promptText.length} ctx=${session.lastContextPct.toFixed(1)}% streak=${session.consecutiveEmptyResponses}`,
        );
        logCorruptionEvent(
          buildCorruptionDiagnostics(session, managed, {
            sessionKey,
            phase: "silent-empty-response-pre-retry",
            error: "ACP returned 0 tokens without error — will retry",
            messages: body.messages,
            incomingChars,
            promptText,
            responseText: "",
            elapsedMs: Math.round(elapsed),
          }),
        );

        // Single retry on the same session — cheap (<100ms if still wedged).
        let retrySucceeded = false;
        try {
          const retryChunks: string[] = [];
          await session.prompt(promptText, (text) => {
            if (!tFirstChunk) {
              tFirstChunk = performance.now();
            }
            retryChunks.push(text);
            sseChunk(res, buildChunk(completionId, text));
          });
          const retryResponse = retryChunks.join("");
          if (retryResponse.trim()) {
            retrySucceeded = true;
            session.consecutiveEmptyResponses = 0;
            session.consecutiveErrors = 0;
            log(
              `🟢 EMPTY RETRY SUCCEEDED: session=${sessionTag}… retryLen=${retryResponse.length} totalElapsed=${Math.round(performance.now() - t0)}ms`,
            );
          }
        } catch (retryErr) {
          log(formatErrorVerbose(retryErr, "empty retry threw"));
        }

        if (!retrySucceeded) {
          // Retry also empty or failed — session is brain-dead, reset immediately.
          session.consecutiveEmptyResponses++;
          const totalElapsed = performance.now() - t0;
          log(
            `🔴 EMPTY RETRY ALSO FAILED — resetting: session=${sessionTag}… totalElapsed=${Math.round(totalElapsed)}ms streak=${session.consecutiveEmptyResponses}`,
          );
          logCorruptionEvent(
            buildCorruptionDiagnostics(session, managed, {
              sessionKey,
              phase: "silent-empty-response-retry-failed",
              error: "ACP returned 0 tokens on both initial and retry — session brain-dead",
              messages: body.messages,
              incomingChars,
              promptText,
              responseText: "",
              elapsedMs: Math.round(totalElapsed),
            }),
          );
          manager.resetSession(
            sessionKey,
            `empty-retry-failed-streak-${session.consecutiveEmptyResponses}`,
          );
          sseChunk(
            res,
            buildChunk(
              completionId,
              "⚠️ Session stopped responding and has been reset. Please resend your message.",
            ),
          );
        }
      } else if (fullResponse.trim()) {
        session.consecutiveEmptyResponses = 0;
      }

      // Surface context usage warning so the user sees it in Discord.
      if (session.lastContextPct >= 90) {
        sseChunk(
          res,
          buildChunk(
            completionId,
            `\n\n🚨 Context window at ${Math.round(session.lastContextPct)}% — approaching auto-reset threshold (95%). Send \`/new\` now to avoid losing your session mid-task.`,
          ),
        );
      } else if (session.lastContextPct >= 80) {
        sseChunk(
          res,
          buildChunk(
            completionId,
            `\n\n⚠️ Context window at ${Math.round(session.lastContextPct)}%. Send \`/new\` soon to reset before it fills up.`,
          ),
        );
      }

      // Append context usage footer to every response.
      if (session.lastContextPct > 0 && fullResponse.trim()) {
        const pct = Math.round(session.lastContextPct);
        sseChunk(res, buildChunk(completionId, `\n\n-# 📊 ${pct}% context used`));
      }
    } catch (err) {
      log(formatErrorVerbose(err, "prompt error (stream)"));
      session.consecutiveErrors++;

      // Too many consecutive errors: the session is likely broken beyond repair.
      if (session.consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
        log(
          `consecutive error threshold reached (${session.consecutiveErrors}) — auto-resetting session`,
        );
        manager.resetSession(sessionKey, `consecutive-errors-${session.consecutiveErrors}`);
        sseChunk(
          res,
          buildChunk(
            completionId,
            "⚠️ Multiple consecutive errors detected. The session has been reset — please resend your message.",
          ),
        );
        sseChunk(res, buildFinalChunk(completionId));
        sseDone(res);
        return;
      }

      // Surface the error visibly so the user knows the response was cut short
      // (partial content may already have been streamed to Discord).
      if (!isInvalidHistoryError(err)) {
        const hadPartial = responseChunks.length > 0;
        const detail = extractStreamErrorSummary(err);
        sseChunk(
          res,
          buildChunk(
            completionId,
            hadPartial
              ? `\n\n⚠️ Response interrupted — the model hit an internal error mid-stream.${detail} Please try again.`
              : `⚠️ The model returned an error before generating a response.${detail} Please try again.`,
          ),
        );
      }

      if (isInvalidHistoryError(err)) {
        log(formatErrorVerbose(err, "invalid history detected"));
        const recoveryText = manager.getLatestUserMessage(body.messages);
        const elapsed = performance.now() - t0;
        const diag = buildCorruptionDiagnostics(session, managed, {
          sessionKey,
          phase: "initial",
          error: err,
          messages: body.messages,
          incomingChars,
          promptText,
          responseText: responseChunks.join(""),
          elapsedMs: Math.round(elapsed),
        });
        logCorruptionEvent(diag);
        log(`🔴 CORRUPTION DIAG (ACP error): ${JSON.stringify(diag, null, 2)}`);
        manager.resetSession(sessionKey, "invalid-conversation-history");

        // Brief delay to let the killed kiro-cli process fully exit before respawning.
        await sleep(1000);

        // Attempt 1: replay user message with safety preamble
        if (recoveryText) {
          const safeRecoveryText = RECOVERY_PREAMBLE + recoveryText;
          log(`recovery attempt 1: preamble + user message (${recoveryText.length} chars)`);
          try {
            const cleanMessages = [{ role: "user" as const, content: safeRecoveryText }];
            const recovery = await manager.getOrCreate(
              sessionKey,
              cleanMessages,
              openclawSessionKey,
            );
            recovery.managed.handle.sentMessageCount = body.messages.length;

            let recoveryResolve: () => void;
            recovery.managed.promptLock = new Promise((r) => {
              recoveryResolve = r;
            });

            await recovery.session.prompt(safeRecoveryText, (text) => {
              if (!tFirstChunk) {
                tFirstChunk = performance.now();
              }
              sseChunk(res, buildChunk(completionId, text));
            });
            recovery.session.consecutiveErrors = 0;
            recoveryResolve!();

            sseChunk(res, buildFinalChunk(completionId));
            sseDone(res);
            return;
          } catch (retryErr) {
            log(formatErrorVerbose(retryErr, "recovery attempt 1 failed"));
            logCorruptionEvent(
              buildCorruptionDiagnostics(session, managed, {
                sessionKey,
                phase: "recovery-1",
                error: retryErr,
                messages: body.messages,
                incomingChars,
                promptText,
                responseText: responseChunks.join(""),
                elapsedMs: Math.round(performance.now() - t0),
              }),
            );
            manager.resetSession(sessionKey, "recovery-attempt-1-failed");
          }
        }

        // Backoff before attempt 2 to let resources settle
        log(`recovery backoff: waiting ${RECOVERY_BACKOFF_MS}ms before attempt 2`);
        await sleep(RECOVERY_BACKOFF_MS);

        // Attempt 2: minimal no-tool prompt to break the doom loop
        log("recovery attempt 2: fallback no-tool prompt");
        try {
          const fallbackMessages = [{ role: "user" as const, content: FALLBACK_RECOVERY_PROMPT }];
          const fallback = await manager.getOrCreate(
            sessionKey,
            fallbackMessages,
            openclawSessionKey,
          );
          fallback.managed.handle.sentMessageCount = body.messages.length;

          let fallbackResolve: () => void;
          fallback.managed.promptLock = new Promise((r) => {
            fallbackResolve = r;
          });

          await fallback.session.prompt(FALLBACK_RECOVERY_PROMPT, (text) => {
            if (!tFirstChunk) {
              tFirstChunk = performance.now();
            }
            sseChunk(res, buildChunk(completionId, text));
          });
          fallback.session.consecutiveErrors = 0;
          fallbackResolve!();

          sseChunk(res, buildFinalChunk(completionId));
          sseDone(res);
          return;
        } catch (fallbackErr) {
          log(formatErrorVerbose(fallbackErr, "recovery attempt 2 failed"));
          logCorruptionEvent(
            buildCorruptionDiagnostics(session, managed, {
              sessionKey,
              phase: "recovery-2",
              error: fallbackErr,
              messages: body.messages,
              incomingChars,
              promptText,
              responseText: responseChunks.join(""),
              elapsedMs: Math.round(performance.now() - t0),
            }),
          );
          manager.resetSession(sessionKey, "recovery-attempt-2-failed");
        }

        // Both recovery attempts failed — return a synthetic response and
        // leave the session cleared so the NEXT message starts fresh.
        // This avoids the doom loop: no third session spawn, just a clean
        // message telling the user what happened.
        log("recovery exhausted — returning synthetic reset notice");
        sseChunk(
          res,
          buildChunk(
            completionId,
            "⚠️ The session crashed and both auto-recovery attempts failed. " +
              "The session has been reset — your next message will start a fresh session. " +
              "If this keeps happening, try breaking your request into smaller pieces " +
              "(e.g., one diagram at a time).",
          ),
        );
      }

      sseChunk(res, buildFinalChunk(completionId));
      sseDone(res);
      return;
    } finally {
      req.removeListener("close", onClose);
      const tDone = performance.now();
      log(
        `timing: session=${sessionTag}… ttfc=${tFirstChunk ? Math.round(tFirstChunk - tSession) : "none"}ms total=${Math.round(tDone - t0)}ms`,
      );
      log(
        `done: session=${sessionTag}… ctx=${session.lastContextPct.toFixed(0)}% errors=${session.consecutiveErrors} msgs=${body.messages.length}${clientDisconnected ? " (client disconnected)" : ""}`,
      );
      resolvePromptLock!();
    }

    sseChunk(res, buildFinalChunk(completionId, wasMaxTokens ? "length" : "stop"));
    sseDone(res);
  } else {
    // ── Blocking (non-streaming) response ─────────────────────────────────
    const parts: string[] = [];
    let resolveBlockLock: () => void;
    managed.promptLock = new Promise((r) => {
      resolveBlockLock = r;
    });

    try {
      await session.prompt(promptText, (text) => parts.push(text));
      session.consecutiveErrors = 0;

      // Detect kiro-cli inline corruption in blocking response.
      const blockingResponse = parts.join("");
      if (blockingResponse.includes(KIRO_CLI_CORRUPTION_MARKER)) {
        const elapsed = performance.now() - t0;
        log(
          `🔴 KIRO-CLI CORRUPTION DETECTED (blocking): session=${sessionTag}… elapsed=${Math.round(elapsed)}ms responseLen=${blockingResponse.length}`,
        );
        const diag = buildCorruptionDiagnostics(session, managed, {
          sessionKey,
          phase: "blocking-inline-corruption",
          error: "kiro-cli emitted corruption marker in response",
          messages: body.messages,
          incomingChars,
          promptText,
          responseText: blockingResponse,
          elapsedMs: Math.round(elapsed),
        });
        logCorruptionEvent(diag);
        log(`🔴 CORRUPTION DIAG: ${JSON.stringify(diag, null, 2)}`);
      }

      // Detect silent empty response in blocking path — retry once before giving up.
      if (!blockingResponse.trim() && promptText.trim()) {
        const elapsed = performance.now() - t0;
        log(
          `🟡 EMPTY ACP RESPONSE (blocking) — retrying once: session=${sessionTag}… elapsed=${Math.round(elapsed)}ms promptLen=${promptText.length} ctx=${session.lastContextPct.toFixed(1)}%`,
        );
        logCorruptionEvent(
          buildCorruptionDiagnostics(session, managed, {
            sessionKey,
            phase: "silent-empty-response-blocking-pre-retry",
            error: "ACP returned 0 tokens without error (blocking) — will retry",
            messages: body.messages,
            incomingChars,
            promptText,
            responseText: "",
            elapsedMs: Math.round(elapsed),
          }),
        );

        // Single retry on the same session.
        let retryText = "";
        try {
          const retryParts: string[] = [];
          await session.prompt(promptText, (text) => retryParts.push(text));
          retryText = retryParts.join("");
        } catch (retryErr) {
          log(formatErrorVerbose(retryErr, "empty retry threw (blocking)"));
        }

        if (retryText.trim()) {
          session.consecutiveEmptyResponses = 0;
          session.consecutiveErrors = 0;
          log(
            `🟢 EMPTY RETRY SUCCEEDED (blocking): session=${sessionTag}… retryLen=${retryText.length} totalElapsed=${Math.round(performance.now() - t0)}ms`,
          );
          // Return the retry response instead of falling through to the empty one.
          const completion: OpenAICompletion = {
            id: completionId,
            object: "chat.completion",
            created: Math.floor(Date.now() / 1000),
            model: KIRO_MODEL_ID,
            choices: [
              {
                index: 0,
                message: { role: "assistant", content: retryText },
                finish_reason: "stop",
              },
            ],
            usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
          };
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify(completion));
          return;
        }

        // Retry also empty — session is brain-dead, reset immediately.
        session.consecutiveEmptyResponses++;
        const totalElapsed = performance.now() - t0;
        log(
          `🔴 EMPTY RETRY ALSO FAILED (blocking) — resetting: session=${sessionTag}… totalElapsed=${Math.round(totalElapsed)}ms streak=${session.consecutiveEmptyResponses}`,
        );
        logCorruptionEvent(
          buildCorruptionDiagnostics(session, managed, {
            sessionKey,
            phase: "silent-empty-response-blocking-retry-failed",
            error:
              "ACP returned 0 tokens on both initial and retry (blocking) — session brain-dead",
            messages: body.messages,
            incomingChars,
            promptText,
            responseText: "",
            elapsedMs: Math.round(totalElapsed),
          }),
        );
        manager.resetSession(
          sessionKey,
          `empty-retry-failed-blocking-streak-${session.consecutiveEmptyResponses}`,
        );
        // Return a reset notice so the caller knows the session was cleared.
        const completion: OpenAICompletion = {
          id: completionId,
          object: "chat.completion",
          created: Math.floor(Date.now() / 1000),
          model: KIRO_MODEL_ID,
          choices: [
            {
              index: 0,
              message: {
                role: "assistant",
                content:
                  "⚠️ Session stopped responding and has been reset. Please resend your message.",
              },
              finish_reason: "stop",
            },
          ],
          usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
        };
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(completion));
        return;
      }
    } catch (err) {
      log(formatErrorVerbose(err, "prompt error (blocking)"));
      session.consecutiveErrors++;

      // Too many consecutive errors: the session is likely broken beyond repair.
      if (session.consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
        log(
          `consecutive error threshold reached (${session.consecutiveErrors}) — auto-resetting session`,
        );
        manager.resetSession(sessionKey, `consecutive-errors-${session.consecutiveErrors}`);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            error: {
              message:
                "Multiple consecutive errors detected. The session has been reset — please resend your message.",
              type: "server_error",
            },
          }),
        );
        return;
      }

      if (isInvalidHistoryError(err)) {
        log(formatErrorVerbose(err, "invalid history detected (blocking)"));
        const recoveryText = manager.getLatestUserMessage(body.messages);
        const elapsed = performance.now() - t0;
        const diag = buildCorruptionDiagnostics(session, managed, {
          sessionKey,
          phase: "initial-blocking",
          error: err,
          messages: body.messages,
          incomingChars,
          promptText,
          responseText: parts.join(""),
          elapsedMs: Math.round(elapsed),
        });
        logCorruptionEvent(diag);
        log(`🔴 CORRUPTION DIAG (ACP error, blocking): ${JSON.stringify(diag, null, 2)}`);
        manager.resetSession(sessionKey, "invalid-conversation-history");

        // Brief delay to let the killed kiro-cli process fully exit before respawning.
        await sleep(1000);

        // Attempt 1: replay user message with safety preamble
        if (recoveryText) {
          const safeRecoveryText = RECOVERY_PREAMBLE + recoveryText;
          log(`recovery attempt 1: preamble + user message (${recoveryText.length} chars)`);
          try {
            const cleanMessages = [{ role: "user" as const, content: safeRecoveryText }];
            const recovery = await manager.getOrCreate(
              sessionKey,
              cleanMessages,
              openclawSessionKey,
            );
            recovery.managed.handle.sentMessageCount = body.messages.length;
            const retryParts: string[] = [];
            await recovery.session.prompt(safeRecoveryText, (text) => retryParts.push(text));
            recovery.session.consecutiveErrors = 0;

            const fullText = retryParts.join("");
            const completion: OpenAICompletion = {
              id: completionId,
              object: "chat.completion",
              created: Math.floor(Date.now() / 1000),
              model: KIRO_MODEL_ID,
              choices: [
                {
                  index: 0,
                  message: { role: "assistant", content: fullText },
                  finish_reason: "stop",
                },
              ],
              usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
            };
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify(completion));
            return;
          } catch (retryErr) {
            log(formatErrorVerbose(retryErr, "recovery attempt 1 failed (blocking)"));
            logCorruptionEvent(
              buildCorruptionDiagnostics(session, managed, {
                sessionKey,
                phase: "recovery-1-blocking",
                error: retryErr,
                messages: body.messages,
                incomingChars,
                promptText,
                responseText: parts.join(""),
                elapsedMs: Math.round(performance.now() - t0),
              }),
            );
            manager.resetSession(sessionKey, "recovery-attempt-1-failed");
          }
        }

        // Backoff before attempt 2
        log(`recovery backoff: waiting ${RECOVERY_BACKOFF_MS}ms before attempt 2`);
        await sleep(RECOVERY_BACKOFF_MS);

        // Attempt 2: minimal no-tool prompt to break the doom loop
        log("recovery attempt 2: fallback no-tool prompt (blocking)");
        try {
          const fallbackMessages = [{ role: "user" as const, content: FALLBACK_RECOVERY_PROMPT }];
          const fallback = await manager.getOrCreate(
            sessionKey,
            fallbackMessages,
            openclawSessionKey,
          );
          fallback.managed.handle.sentMessageCount = body.messages.length;
          const fallbackParts: string[] = [];
          await fallback.session.prompt(FALLBACK_RECOVERY_PROMPT, (text) =>
            fallbackParts.push(text),
          );
          fallback.session.consecutiveErrors = 0;

          const fullText = fallbackParts.join("");
          const completion: OpenAICompletion = {
            id: completionId,
            object: "chat.completion",
            created: Math.floor(Date.now() / 1000),
            model: KIRO_MODEL_ID,
            choices: [
              {
                index: 0,
                message: { role: "assistant", content: fullText },
                finish_reason: "stop",
              },
            ],
            usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
          };
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify(completion));
          return;
        } catch (fallbackErr) {
          log(formatErrorVerbose(fallbackErr, "recovery attempt 2 failed (blocking)"));
          logCorruptionEvent(
            buildCorruptionDiagnostics(session, managed, {
              sessionKey,
              phase: "recovery-2-blocking",
              error: fallbackErr,
              messages: body.messages,
              incomingChars,
              promptText,
              responseText: parts.join(""),
              elapsedMs: Math.round(performance.now() - t0),
            }),
          );
          manager.resetSession(sessionKey, "recovery-attempt-2-failed");
        }
      }

      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          error: {
            message: isInvalidHistoryError(err)
              ? "Session history corrupted. Please send /new to reset."
              : String(err),
            type: "server_error",
          },
        }),
      );
      return;
    } finally {
      const tDone = performance.now();
      log(`timing: session=${sessionTag}… total=${Math.round(tDone - t0)}ms`);
      resolveBlockLock!();
    }

    const fullText = parts.join("");
    const completion: OpenAICompletion = {
      id: completionId,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: KIRO_MODEL_ID,
      choices: [
        { index: 0, message: { role: "assistant", content: fullText }, finish_reason: "stop" },
      ],
      usage: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
      },
    };
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(completion));
  }
}

// ─── Main server factory ──────────────────────────────────────────────────────

export function createKiroProxyServer(
  manager: SessionManager,
  opts: KiroProxyOptions = {},
): ReturnType<typeof createServer> {
  const log = opts.verbose
    ? (msg: string) => process.stderr.write(`[kiro-proxy] ${msg}\n`)
    : () => {};

  const server = createServer((req, res) => {
    const url = req.url ?? "/";
    const method = req.method?.toUpperCase() ?? "GET";

    // CORS pre-flight
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Kiro-Session-Id");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    if (method === "GET" && (url === "/health" || url === "/")) {
      handleHealth(res);
      return;
    }

    if (method === "GET" && url === "/v1/models") {
      handleModels(res);
      return;
    }

    if (method === "GET" && url === "/sessions") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          sessions: manager.getSessionsInfo(),
          hibernated: manager.getHibernatedInfo(),
        }),
      );
      return;
    }

    // Cancel a specific session or all sessions.
    // POST /cancel — cancel all active prompts
    // POST /cancel/<sessionKey> — cancel a specific session
    if (method === "POST" && url.startsWith("/cancel")) {
      const targetKey =
        url === "/cancel" ? undefined : decodeURIComponent(url.slice("/cancel/".length));
      void (async () => {
        try {
          if (targetKey) {
            const cancelled = await manager.cancelSession(targetKey);
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ cancelled, sessionKey: targetKey }));
          } else {
            const count = await manager.cancelAll();
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ cancelled: count }));
          }
        } catch (err) {
          log(`cancel error: ${String(err)}`);
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: { message: String(err) } }));
        }
      })();
      return;
    }

    // POST /hibernate/<sessionKey> — hibernate a specific session for testing.
    if (method === "POST" && url.startsWith("/hibernate/")) {
      const targetKey = decodeURIComponent(url.slice("/hibernate/".length));
      const entry = manager.getSessionEntry(targetKey);
      if (!entry) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "session not found" }));
      } else if (entry.session.isPrompting) {
        res.writeHead(409, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "session is prompting" }));
      } else {
        manager.hibernateSession(targetKey, entry.session, "manual-test");
        log(`manual hibernate: ${targetKey}`);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ hibernated: true, sessionKey: targetKey }));
      }
      return;
    }

    if (method === "POST" && url === "/v1/chat/completions") {
      handleCompletions(req, res, manager, log).catch((err) => {
        log(`unhandled error: ${String(err)}`);
        if (!res.headersSent) {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: { message: "Internal server error" } }));
        }
      });
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: "Not found" } }));
  });

  return server;
}
