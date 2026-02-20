/**
 * Types for the Kiro proxy server.
 *
 * The proxy exposes an OpenAI-compatible HTTP API so that pi-ai (OpenClaw's
 * model-abstraction layer) can route all inference through Kiro CLI instead of
 * calling cloud providers directly.
 */

// ─── OpenAI wire format (subset we care about) ───────────────────────────────

export type OpenAIRole = "system" | "user" | "assistant";

export type OpenAIMessage = {
  role: OpenAIRole;
  content: string;
};

export type OpenAIChatRequest = {
  model: string;
  messages: OpenAIMessage[];
  stream?: boolean;
  /** Optional caller-supplied session key; checked before fingerprinting. */
  user?: string;
  temperature?: number;
  max_tokens?: number;
};

export type OpenAIChunk = {
  id: string;
  object: "chat.completion.chunk";
  created: number;
  model: string;
  choices: Array<{
    index: 0;
    delta: { role?: "assistant"; content?: string };
    finish_reason: string | null;
  }>;
};

export type OpenAICompletion = {
  id: string;
  object: "chat.completion";
  created: number;
  model: string;
  choices: Array<{
    index: 0;
    message: { role: "assistant"; content: string };
    finish_reason: "stop" | "cancelled" | "error";
  }>;
  usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
};

// ─── Kiro proxy internal ──────────────────────────────────────────────────────

export type KiroProxyOptions = {
  /** TCP port for the HTTP server. Default: 18790 */
  port?: number;
  /** Hostname to bind to. Default: 127.0.0.1 */
  host?: string;
  /**
   * Path to the kiro executable. Default: "kiro-cli"
   * Kiro CLI is typically installed at ~/.local/bin/kiro-cli on Linux/macOS.
   * Use the full path if `kiro-cli` is not on $PATH.
   */
  kiroBin?: string;
  /**
   * Additional args passed to kiro after the "acp" sub-command.
   * E.g. ["--workspace", "/my/project"]
   */
  kiroArgs?: string[];
  /** Working directory passed to every kiro process. Default: process.cwd() */
  cwd?: string;
  /**
   * Seconds of inactivity before an idle Kiro session is killed.
   * Default: 1800 (30 min)
   */
  sessionIdleSecs?: number;
  /** Emit debug logs to stderr. */
  verbose?: boolean;
};

export type KiroSessionHandle = {
  /** ACP session ID returned by kiro */
  acpSessionId: string;
  /** Number of OpenAI messages that have already been forwarded */
  sentMessageCount: number;
  /** Epoch ms of last prompt() call */
  lastTouchedAt: number;
};
