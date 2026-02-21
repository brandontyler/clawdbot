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
// Fixes @buape/carbon gateway bugs and adds flap detection:
//
// 1. reconnectAttempts resets on every WS "open" event, even if the connection
//    immediately closes again. This defeats exponential backoff on flapping
//    connections. We defer the reset until a READY or RESUMED dispatch.
//
// 2. The heartbeat timer can fire after disconnect(), throwing
//    "Attempted to reconnect zombie connection" as an uncaught exception that
//    crashes the process. We override setupWebSocket to catch that throw and
//    route it through handleZombieConnection() instead.
//
// 3. Flap detection: if the connection drops repeatedly within a short window
//    after each successful RESUMED, the session is likely stale. After
//    MAX_RAPID_RESUMES consecutive rapid disconnects we clear session state
//    and force a fresh IDENTIFY instead of resuming forever.

/** A resume that lasts less than this is considered a "flap". */
const STABLE_CONNECTION_MS = 60_000;
/** After this many consecutive flaps, force a fresh IDENTIFY. */
const MAX_RAPID_RESUMES = 8;

class ResilientGatewayPlugin extends GatewayPlugin {
  private get _reconnectAttempts(): number {
    return (this as unknown as { reconnectAttempts: number }).reconnectAttempts;
  }
  private set _reconnectAttempts(v: number) {
    (this as unknown as { reconnectAttempts: number }).reconnectAttempts = v;
  }

  /** Timestamp of the last successful READY/RESUMED dispatch. */
  private _lastResumedAt = 0;
  /** How many consecutive resumes lasted less than STABLE_CONNECTION_MS. */
  private _rapidResumeCount = 0;

  private get _state() {
    return (
      this as unknown as {
        state: {
          sessionId: string | null;
          resumeGatewayUrl: string | null;
          sequence: number | null;
        };
      }
    ).state;
  }

  private set _sequence(v: number | null) {
    (this as unknown as { sequence: number | null }).sequence = v;
  }

  override setupWebSocket(): void {
    if (!(this as unknown as { ws: WebSocket | null }).ws) {
      return;
    }
    const ws = (this as unknown as { ws: WebSocket }).ws;

    // Save reconnect count before parent's "open" handler resets it to 0.
    const savedAttempts = this._reconnectAttempts;

    super.setupWebSocket();

    // Parent's "open" handler resets reconnectAttempts=0. Restore saved value;
    // it will be properly reset only when READY/RESUMED arrives.
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
          this._lastResumedAt = Date.now();
          this.emitter.emit("debug", `Resumed successfully (${parsed.t})`);
        }
      } catch {
        // Ignore — parent handles validation.
      }
    });
  }

  private _backoffTimer: ReturnType<typeof setTimeout> | undefined;

  /**
   * Override connect to:
   * - detect flapping (rapid disconnect after resume) and force fresh IDENTIFY
   * - add exponential backoff with jitter when attempts pile up
   * - catch the zombie heartbeat throw from @buape/carbon
   */
  override connect(resume?: boolean): void {
    // Flap detection: if the last resume was very short-lived, count it.
    if (this._lastResumedAt > 0) {
      const uptime = Date.now() - this._lastResumedAt;
      if (uptime < STABLE_CONNECTION_MS) {
        this._rapidResumeCount++;
      } else {
        this._rapidResumeCount = 0;
      }
    }

    // After too many rapid flaps, clear session and force fresh IDENTIFY.
    if (resume && this._rapidResumeCount >= MAX_RAPID_RESUMES) {
      this.emitter.emit(
        "debug",
        `${this._rapidResumeCount} rapid disconnects detected, forcing fresh IDENTIFY`,
      );
      this._state.sessionId = null;
      this._state.resumeGatewayUrl = null;
      this._state.sequence = null;
      this._sequence = null;
      this._rapidResumeCount = 0;
      resume = false;
    }

    const attempts = this._reconnectAttempts;
    if (attempts > 3) {
      // Exponential backoff: 4s, 8s, 16s … capped at 60s, plus up to 3s jitter
      const delay = Math.min(2000 * 2 ** (attempts - 3), 60_000) + Math.random() * 3000;
      this.emitter.emit(
        "debug",
        `backing off reconnect attempt ${attempts}: waiting ${Math.round(delay)}ms`,
      );
      if (this._backoffTimer) {
        clearTimeout(this._backoffTimer);
      }
      this._backoffTimer = setTimeout(() => {
        this._backoffTimer = undefined;
        this._connectInner(resume);
      }, delay);
      return;
    }
    this._connectInner(resume);
  }

  private _connectInner(resume?: boolean): void {
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

  override disconnect(): void {
    if (this._backoffTimer) {
      clearTimeout(this._backoffTimer);
      this._backoffTimer = undefined;
    }
    super.disconnect();
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
