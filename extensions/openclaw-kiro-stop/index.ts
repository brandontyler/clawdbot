import { definePluginEntry, type OpenClawPluginApi } from "./api.js";

const DEFAULT_PROXY_URL = "http://localhost:18801";

type StopPluginConfig = {
  proxyUrl?: string;
};

function isStopPluginConfig(value: unknown): value is StopPluginConfig {
  return value !== null && typeof value === "object";
}

function normalizeUrl(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function resolveProxyUrl(pluginConfig: unknown): string {
  if (isStopPluginConfig(pluginConfig) && typeof pluginConfig.proxyUrl === "string") {
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

export default definePluginEntry({
  id: "stopkiro",
  name: "Kiro Stop",
  description: "Cancels the in-flight kiro-proxy ACP session for this channel.",
  register(api: OpenClawPluginApi) {
    api.registerCommand({
      name: "stopkiro",
      description: "Cancel the in-flight kiro-cli run for this channel.",
      acceptsArgs: false,
      handler: async (ctx) => {
        const sessionKey = resolveTargetSessionKey({
          sessionKey: ctx.sessionKey,
          channelId: ctx.channelId as string | number | undefined,
        });
        if (!sessionKey) {
          return {
            text: "⚠️ Could not resolve a session key for this surface — nothing to stop.",
          };
        }
        const proxyUrl = resolveProxyUrl(api.pluginConfig);
        const cancelUrl = `${proxyUrl}/cancel/${encodeURIComponent(sessionKey)}`;
        try {
          const res = await fetch(cancelUrl, { method: "POST" });
          if (!res.ok) {
            return {
              text: `⚠️ Stop failed: kiro-proxy responded HTTP ${res.status}.`,
            };
          }
          const body = (await res.json().catch(() => null)) as {
            cancelled?: boolean;
            sessionKey?: string;
          } | null;
          if (body?.cancelled) {
            return {
              text: "🛑 Stop sent. The agent will respawn on your next message.",
            };
          }
          return {
            text: "ℹ️ Nothing currently in-flight to cancel for this channel.",
          };
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          return { text: `⚠️ Stop failed: ${msg}` };
        }
      },
    });
  },
});
