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
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { PromptTimeoutError } from "./kiro-session.js";
import { SessionManager, isInvalidHistoryError } from "./session-manager.js";
import type {
  KiroProxyOptions,
  OpenAIChatRequest,
  OpenAIChunk,
  OpenAICompletion,
} from "./types.js";

const KIRO_MODEL_ID = "kiro-default";

/** Auto-reset a session after this many consecutive prompt failures. */
const MAX_CONSECUTIVE_ERRORS = 3;

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

function buildFinalChunk(completionId: string): OpenAIChunk {
  return {
    id: completionId,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: KIRO_MODEL_ID,
    choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
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

    let resolvePromptLock: () => void;
    managed.promptLock = new Promise((r) => {
      resolvePromptLock = r;
    });

    let tFirstChunk = 0;
    try {
      await session.prompt(promptText, (text) => {
        if (!tFirstChunk) {
          tFirstChunk = performance.now();
        }
        sseChunk(res, buildChunk(completionId, text));
      });
      session.consecutiveErrors = 0;

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
    } catch (err) {
      log(`prompt error: ${err instanceof Error ? err.message : JSON.stringify(err)}`);
      session.consecutiveErrors++;

      // Timeout: kill the hung session so the next message spawns a fresh one.
      if (err instanceof PromptTimeoutError) {
        log(`prompt idle timeout — killing session (consecutive=${session.consecutiveErrors})`);
        manager.resetSession(sessionKey, "prompt-idle-timeout");
        sseChunk(
          res,
          buildChunk(
            completionId,
            "⚠️ The session went silent for too long (no tool activity). It has been reset — please resend your message.",
          ),
        );
        sseChunk(res, buildFinalChunk(completionId));
        sseDone(res);
        return;
      }

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

      if (isInvalidHistoryError(err)) {
        // Auto-recovery: kill corrupted session, spawn fresh one, retry with just the latest message.
        log(`invalid history detected — auto-resetting session and retrying`);
        manager.resetSession(sessionKey, "invalid-conversation-history");

        const recoveryText = manager.getLatestUserMessage(body.messages);
        if (recoveryText) {
          try {
            const recovery = await manager.getOrCreate(
              sessionKey,
              body.messages,
              openclawSessionKey,
            );
            // Override sentMessageCount so future turns don't resend old messages
            recovery.managed.handle.sentMessageCount = body.messages.length;

            let recoveryResolve: () => void;
            recovery.managed.promptLock = new Promise((r) => {
              recoveryResolve = r;
            });

            await recovery.session.prompt(recoveryText, (text) => {
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
            log(
              `recovery retry also failed: ${retryErr instanceof Error ? retryErr.message : String(retryErr)}`,
            );
          }
        }

        // Recovery failed — tell the user clearly
        sseChunk(
          res,
          buildChunk(
            completionId,
            "⚠️ Session history became corrupted and auto-recovery failed. Please send `/new` to reset this conversation.",
          ),
        );
      }

      sseChunk(res, buildFinalChunk(completionId));
      sseDone(res);
      return;
    } finally {
      const tDone = performance.now();
      log(
        `timing: session=${sessionTag}… ttfc=${tFirstChunk ? Math.round(tFirstChunk - tSession) : "none"}ms total=${Math.round(tDone - t0)}ms`,
      );
      log(
        `done: session=${sessionTag}… ctx=${session.lastContextPct.toFixed(0)}% errors=${session.consecutiveErrors} msgs=${body.messages.length}`,
      );
      resolvePromptLock!();
    }

    sseChunk(res, buildFinalChunk(completionId));
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
    } catch (err) {
      log(`prompt error: ${err instanceof Error ? err.message : JSON.stringify(err)}`);
      session.consecutiveErrors++;

      // Timeout: kill the hung session so the next message spawns a fresh one.
      if (err instanceof PromptTimeoutError) {
        log(`prompt idle timeout — killing session (consecutive=${session.consecutiveErrors})`);
        manager.resetSession(sessionKey, "prompt-idle-timeout");
        res.writeHead(504, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            error: {
              message:
                "The session went silent for too long (no tool activity). It has been reset — please resend your message.",
              type: "timeout",
            },
          }),
        );
        return;
      }

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
        log(`invalid history detected — auto-resetting session and retrying`);
        manager.resetSession(sessionKey, "invalid-conversation-history");

        const recoveryText = manager.getLatestUserMessage(body.messages);
        if (recoveryText) {
          try {
            const recovery = await manager.getOrCreate(
              sessionKey,
              body.messages,
              openclawSessionKey,
            );
            recovery.managed.handle.sentMessageCount = body.messages.length;
            const retryParts: string[] = [];
            await recovery.session.prompt(recoveryText, (text) => retryParts.push(text));
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
            log(
              `recovery retry also failed: ${retryErr instanceof Error ? retryErr.message : String(retryErr)}`,
            );
          }
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
      res.end(JSON.stringify({ sessions: manager.getSessionsInfo() }));
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
