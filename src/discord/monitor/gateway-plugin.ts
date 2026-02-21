import { GatewayIntents, GatewayPlugin } from "@buape/carbon/gateway";
import type { APIGatewayBotInfo } from "discord-api-types/v10";
import { HttpsProxyAgent } from "https-proxy-agent";
import { ProxyAgent, fetch as undiciFetch } from "undici";
import WebSocket from "ws";
import type { DiscordAccountConfig } from "../../config/types.js";
import { danger } from "../../globals.js";
import type { RuntimeEnv } from "../../runtime.js";

export function resolveDiscordGatewayIntents(
  intentsConfig?: import("../../config/types.discord.js").DiscordIntentsConfig,
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
//    crashes the process. We override setupWebSocket to catch that throw and
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

    // The parent's "open" handler already ran via super.setupWebSocket() and
    // will reset reconnectAttempts=0 when the socket opens. We undo that by
    // prepending our own "open" listener that runs AFTER the parent's (since
    // the parent attached its listener first in setupWebSocket, and we append
    // ours after). Actually — we need to run AFTER the parent's open handler.
    // Use a regular listener (not prepend) so it fires after the parent's.
    ws.on("open", () => {
      // Parent just set reconnectAttempts = 0. Restore the saved value.
      // It will be properly reset to 0 only when READY/RESUMED arrives.
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

  /**
   * Override connect to catch the zombie heartbeat throw from @buape/carbon.
   */
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
    return new ResilientGatewayPlugin(options);
  }

  try {
    const wsAgent = new HttpsProxyAgent<string>(proxy);
    const fetchAgent = new ProxyAgent(proxy);

    params.runtime.log?.("discord: gateway proxy enabled");

    class ProxyResilientGatewayPlugin extends ResilientGatewayPlugin {
      constructor() {
        super(options);
      }

      override async registerClient(client: Parameters<GatewayPlugin["registerClient"]>[0]) {
        if (!this.gatewayInfo) {
          try {
            const response = await undiciFetch("https://discord.com/api/v10/gateway/bot", {
              headers: {
                Authorization: `Bot ${client.options.token}`,
              },
              dispatcher: fetchAgent,
            } as Record<string, unknown>);
            this.gatewayInfo = (await response.json()) as APIGatewayBotInfo;
          } catch (error) {
            throw new Error(
              `Failed to get gateway information from Discord: ${error instanceof Error ? error.message : String(error)}`,
              { cause: error },
            );
          }
        }
        return super.registerClient(client);
      }

      override createWebSocket(url: string) {
        return new WebSocket(url, { agent: wsAgent });
      }
    }

    return new ProxyResilientGatewayPlugin();
  } catch (err) {
    params.runtime.error?.(danger(`discord: invalid gateway proxy: ${String(err)}`));
    return new ResilientGatewayPlugin(options);
  }
}
