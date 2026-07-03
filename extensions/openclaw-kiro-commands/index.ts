import { definePluginEntry, type OpenClawPluginApi } from "./api.js";

const DEFAULT_PROXY_URL = "http://localhost:18801";

type KiroCommandsPluginConfig = {
  proxyUrl?: string;
};

function isPluginConfig(value: unknown): value is KiroCommandsPluginConfig {
  return value !== null && typeof value === "object";
}

function normalizeUrl(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function resolveProxyUrl(pluginConfig: unknown): string {
  if (isPluginConfig(pluginConfig) && typeof pluginConfig.proxyUrl === "string") {
    const fromConfig = normalizeUrl(pluginConfig.proxyUrl);
    if (fromConfig) {
      return fromConfig;
    }
  }
  const fromEnv = process.env.OPENCLAW_KIRO_PROXY_URL ?? "";
  const trimmedEnv = normalizeUrl(fromEnv);
  if (trimmedEnv) {
    return trimmedEnv;
  }
  return DEFAULT_PROXY_URL;
}

function resolveTargetSessionKey(ctx: {
  sessionKey?: string;
  channelId?: string | number;
}): string | null {
  if (typeof ctx.sessionKey === "string" && ctx.sessionKey.trim()) {
    return ctx.sessionKey.trim();
  }
  if (ctx.channelId !== undefined && ctx.channelId !== null) {
    const channelId = String(ctx.channelId).trim();
    if (channelId) {
      return `agent:main:discord:channel:${channelId}`;
    }
  }
  return null;
}

/**
 * The /k command family: native Discord slash commands that forward kiro-cli
 * native commands to the channel's persistent ACP child via kiro-proxy.
 *
 * WHY: the OpenClaw gateway intercepts several kiro-native commands upstream
 * (/compact, /usage, /clear via /reset, ...) and runs them against its OWN
 * near-empty transcript — the real conversation context lives in the kiro-cli
 * ACP child that kiro-proxy supervises. The /k prefix routes around that:
 * each command below POSTs the underlying kiro command to the proxy's
 * /v1/chat/completions with the channel's session key, so kiro-cli executes
 * it against the right transcript. Unlike the plain-text aliases in
 * kiro-proxy's KIRO_COMMAND_ALIASES (e.g. typing "/kcompact" as a message),
 * these are REGISTERED commands — they show up in Discord's autocomplete.
 *
 * The text-alias path in session-manager.ts stays as a fallback; both routes
 * converge on the same kiro-cli native command.
 */
const KIRO_FORWARD_COMMANDS: ReadonlyArray<{
  name: string;
  kiroCommand: string;
  description: string;
  acceptsArgs: boolean;
}> = [
  {
    name: "kcompact",
    kiroCommand: "/compact",
    description: "Compact the kiro agent's conversation history (banner + summary follow).",
    acceptsArgs: true,
  },
  {
    name: "kclear",
    kiroCommand: "/clear",
    description: "Clear the kiro agent's conversation history (no summary — blunt reset).",
    acceptsArgs: false,
  },
  {
    name: "kusage",
    kiroCommand: "/usage",
    description: "Show kiro-cli plan usage / credit burn for this channel's agent.",
    acceptsArgs: false,
  },
  {
    name: "kcontext",
    kiroCommand: "/context",
    description: "Show the kiro agent's context breakdown (default: show).",
    acceptsArgs: true,
  },
  {
    name: "kstats",
    kiroCommand: "/stats",
    description: "Show kiro-cli request IDs and timings for debugging slow turns.",
    acceptsArgs: false,
  },
];

/** Discord message limit is 2000 — leave headroom for the header line. */
const MAX_REPLY_LEN = 1800;

async function forwardToKiro(params: {
  proxyUrl: string;
  sessionKey: string;
  command: string;
}): Promise<string> {
  const res = await fetch(`${params.proxyUrl}/v1/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-OpenClaw-Session-Key": params.sessionKey,
    },
    body: JSON.stringify({
      model: "kiro-default",
      stream: false,
      messages: [{ role: "user", content: params.command }],
    }),
  });
  if (!res.ok) {
    throw new Error(`kiro-proxy responded HTTP ${res.status}`);
  }
  const body = (await res.json().catch(() => null)) as {
    choices?: Array<{ message?: { content?: string } }>;
  } | null;
  const content = body?.choices?.[0]?.message?.content ?? "";
  return content.trim();
}

export default definePluginEntry({
  id: "kiro-commands",
  name: "Kiro Commands",
  description:
    "Native /k* slash commands that forward kiro-cli native commands to the channel's ACP child via kiro-proxy.",
  register(api: OpenClawPluginApi) {
    for (const spec of KIRO_FORWARD_COMMANDS) {
      api.registerCommand({
        name: spec.name,
        description: spec.description,
        acceptsArgs: spec.acceptsArgs,
        handler: async (ctx) => {
          const sessionKey = resolveTargetSessionKey({
            sessionKey: ctx.sessionKey,
            channelId: ctx.channelId as string | number | undefined,
          });
          if (!sessionKey) {
            return {
              text: "⚠️ Could not resolve a session key for this surface — nothing to forward.",
            };
          }
          const args = typeof ctx.args === "string" ? ctx.args.trim() : "";
          const command = args ? `${spec.kiroCommand} ${args}` : spec.kiroCommand;
          const proxyUrl = resolveProxyUrl(api.pluginConfig);
          try {
            const reply = await forwardToKiro({ proxyUrl, sessionKey, command });
            if (!reply) {
              // e.g. /compact returns end_turn immediately; the proxy's
              // progress banner + completion summary arrive asynchronously.
              return {
                text: `✅ Sent \`${command}\` to the kiro agent. Watch this channel for its output.`,
              };
            }
            const truncated =
              reply.length > MAX_REPLY_LEN
                ? `${reply.slice(0, MAX_REPLY_LEN)}\n\n_[truncated]_`
                : reply;
            return { text: truncated };
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return { text: `⚠️ \`${command}\` failed: ${msg}` };
          }
        },
      });
    }
  },
});
