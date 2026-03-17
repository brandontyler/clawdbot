import { GatewayIntents, GatewayPlugin } from "@buape/carbon/gateway";
import type { APIGatewayBotInfo } from "discord-api-types/v10";
import { HttpsProxyAgent } from "https-proxy-agent";
import type { DiscordAccountConfig } from "openclaw/plugin-sdk/config-runtime";
import { danger } from "openclaw/plugin-sdk/runtime-env";
import type { RuntimeEnv } from "openclaw/plugin-sdk/runtime-env";
import { ProxyAgent, fetch as undiciFetch } from "undici";
import WebSocket from "ws";

const DISCORD_GATEWAY_BOT_URL = "https://discord.com/api/v10/gateway/bot";
const DEFAULT_DISCORD_GATEWAY_URL = "wss://gateway.discord.gg/";

type DiscordGatewayMetadataResponse = Pick<Response, "ok" | "status" | "text">;
type DiscordGatewayFetchInit = Record<string, unknown> & {
  headers?: Record<string, string>;
};
type DiscordGatewayFetch = (
  input: string,
  init?: DiscordGatewayFetchInit,
) => Promise<DiscordGatewayMetadataResponse>;

export function resolveDiscordGatewayIntents(
  intentsConfig?: import("openclaw/plugin-sdk/config-runtime").DiscordIntentsConfig,
): number {
  let intents =
    GatewayIntents.Guilds |
    GatewayIntents.GuildMessages |
    GatewayIntents.MessageContent |
    GatewayIntents.DirectMessages |
    GatewayIntents.GuildMessageReactions |
    GatewayIntents.DirectMessageReactions |
    GatewayIntents.GuildVoiceStates;
  if (intentsConfig?.presence) {
    intents |= GatewayIntents.GuildPresences;
  }
  if (intentsConfig?.guildMembers) {
    intents |= GatewayIntents.GuildMembers;
  }
  return intents;
}

function summarizeGatewayResponseBody(body: string): string {
  const normalized = body.trim().replace(/\s+/g, " ");
  if (!normalized) {
    return "<empty>";
  }
  return normalized.slice(0, 240);
}

function isTransientDiscordGatewayResponse(status: number, body: string): boolean {
  if (status >= 500) {
    return true;
  }
  const normalized = body.toLowerCase();
  return (
    normalized.includes("upstream connect error") ||
    normalized.includes("disconnect/reset before headers") ||
    normalized.includes("reset reason:")
  );
}

function createGatewayMetadataError(params: {
  detail: string;
  transient: boolean;
  cause?: unknown;
}): Error {
  if (params.transient) {
    return new Error("Failed to get gateway information from Discord: fetch failed", {
      cause: params.cause ?? new Error(params.detail),
    });
  }
  return new Error(`Failed to get gateway information from Discord: ${params.detail}`, {
    cause: params.cause,
  });
}

export async function fetchDiscordGatewayInfo(params: {
  token: string;
  fetchImpl: DiscordGatewayFetch;
  fetchInit?: DiscordGatewayFetchInit;
}): Promise<APIGatewayBotInfo> {
  let response: DiscordGatewayMetadataResponse;
  try {
    response = await params.fetchImpl(DISCORD_GATEWAY_BOT_URL, {
      ...params.fetchInit,
      headers: {
        ...params.fetchInit?.headers,
        Authorization: `Bot ${params.token}`,
      },
    });
  } catch (error) {
    throw createGatewayMetadataError({
      detail: error instanceof Error ? error.message : String(error),
      transient: true,
      cause: error,
    });
  }

  let body: string;
  try {
    body = await response.text();
  } catch (error) {
    throw createGatewayMetadataError({
      detail: error instanceof Error ? error.message : String(error),
      transient: true,
      cause: error,
    });
  }
  const summary = summarizeGatewayResponseBody(body);
  const transient = isTransientDiscordGatewayResponse(response.status, body);

  if (!response.ok) {
    throw createGatewayMetadataError({
      detail: `Discord API /gateway/bot failed (${response.status}): ${summary}`,
      transient,
    });
  }

  try {
    const parsed = JSON.parse(body) as Partial<APIGatewayBotInfo>;
    return {
      ...parsed,
      url:
        typeof parsed.url === "string" && parsed.url.trim()
          ? parsed.url
          : DEFAULT_DISCORD_GATEWAY_URL,
    } as APIGatewayBotInfo;
  } catch (error) {
    throw createGatewayMetadataError({
      detail: `Discord API /gateway/bot returned invalid JSON: ${summary}`,
      transient,
      cause: error,
    });
  }
}

// ─── Resilient GatewayPlugin ──────────────────────────────────────────────────
//
// Fixes two @buape/carbon bugs:
//
// 1. reconnectAttempts resets on every WS "open" event, even if the connection
//    immediately closes again. This defeats exponential backoff on flapping
//    connections. We defer the reset until a READY or RESUMED dispatch.
//
// 2. The heartbeat timer can fire after disconnect(), throwing
//    "Attempted to reconnect zombie connection" as an uncaught exception that
//    crashes the process. We override connect to catch that throw and
//    route it through handleZombieConnection() instead.

export class ResilientGatewayPlugin extends GatewayPlugin {
  protected get _reconnectAttempts(): number {
    return (this as unknown as { reconnectAttempts: number }).reconnectAttempts;
  }
  protected set _reconnectAttempts(v: number) {
    (this as unknown as { reconnectAttempts: number }).reconnectAttempts = v;
  }

  override setupWebSocket(): void {
    if (!(this as unknown as { ws: WebSocket | null }).ws) {
      return;
    }
    const ws = (this as unknown as { ws: WebSocket }).ws;

    // Save reconnect count before parent's "open" handler resets it to 0.
    const savedAttempts = this._reconnectAttempts;

    super.setupWebSocket();

    // Restore saved count — parent's "open" handler already reset it to 0.
    // It will be properly reset to 0 only when READY/RESUMED arrives.
    ws.on("open", () => {
      this._reconnectAttempts = savedAttempts;
    });

    // Reset reconnect counter only on successful READY/RESUMED.
    ws.on("message", (data: WebSocket.Data) => {
      try {
        const raw =
          typeof data === "string" ? data : Buffer.isBuffer(data) ? data.toString("utf8") : "";
        const parsed = JSON.parse(raw);
        if (parsed?.op === 0 && (parsed?.t === "READY" || parsed?.t === "RESUMED")) {
          this._reconnectAttempts = 0;
        }
      } catch {
        // Ignore — parent handles validation.
      }
    });
  }

  override connect(resume?: boolean): void {
    try {
      super.connect(resume);
    } catch (err) {
      if (String(err).includes("zombie connection")) {
        this.emitter.emit("debug", `caught zombie connection error, reconnecting`);
        (this as unknown as { handleZombieConnection: () => void }).handleZombieConnection();
        return;
      }
      throw err;
    }
  }
}

function createGatewayPlugin(params: {
  options: {
    reconnect: { maxAttempts: number };
    intents: number;
    autoInteractions: boolean;
  };
  fetchImpl: DiscordGatewayFetch;
  fetchInit?: DiscordGatewayFetchInit;
  wsAgent?: HttpsProxyAgent<string>;
}): GatewayPlugin {
  class SafeResilientGatewayPlugin extends ResilientGatewayPlugin {
    constructor() {
      super(params.options);
    }

    override async registerClient(client: Parameters<GatewayPlugin["registerClient"]>[0]) {
      if (!this.gatewayInfo) {
        this.gatewayInfo = await fetchDiscordGatewayInfo({
          token: client.options.token,
          fetchImpl: params.fetchImpl,
          fetchInit: params.fetchInit,
        });
      }
      return super.registerClient(client);
    }

    override createWebSocket(url: string) {
      if (!params.wsAgent) {
        return super.createWebSocket(url);
      }
      return new WebSocket(url, { agent: params.wsAgent });
    }
  }

  return new SafeResilientGatewayPlugin();
}

export function createDiscordGatewayPlugin(params: {
  discordConfig: DiscordAccountConfig;
  runtime: RuntimeEnv;
}): GatewayPlugin {
  const intents = resolveDiscordGatewayIntents(params.discordConfig?.intents);
  const proxy = params.discordConfig?.proxy?.trim();
  const options = {
    reconnect: { maxAttempts: 50 },
    intents,
    autoInteractions: true,
  };

  if (!proxy) {
    return createGatewayPlugin({
      options,
      fetchImpl: (input, init) => fetch(input, init as RequestInit),
    });
  }

  try {
    const wsAgent = new HttpsProxyAgent<string>(proxy);
    const fetchAgent = new ProxyAgent(proxy);

    params.runtime.log?.("discord: gateway proxy enabled");

    return createGatewayPlugin({
      options,
      fetchImpl: (input, init) => undiciFetch(input, init),
      fetchInit: { dispatcher: fetchAgent },
      wsAgent,
    });
  } catch (err) {
    params.runtime.error?.(danger(`discord: invalid gateway proxy: ${String(err)}`));
    return createGatewayPlugin({
      options,
      fetchImpl: (input, init) => fetch(input, init as RequestInit),
    });
  }
}
