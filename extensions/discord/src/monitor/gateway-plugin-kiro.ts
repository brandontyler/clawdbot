// ─── Kiro-specific gateway hardening ──────────────────────────────────────────
//
// Extends upstream's ResilientGatewayPlugin with:
// - Flap detection: force fresh IDENTIFY after repeated rapid disconnects
// - Exponential backoff with jitter on reconnect attempts
// - "Resumed successfully" debug logging
//
// Gateway metadata uses the same timeout + transient-fallback path as upstream's
// OpenClawGatewayPlugin (fetchDiscordGatewayInfoWithTimeout + resolveGatewayInfoWithFallback),
// and registerClient swallows the fire-and-forget rejection so a transient
// lookup failure (e.g. ENOTFOUND on machine wake) cannot crash the gateway.
//
// Kept in a separate file so upstream gateway-plugin.ts can be synced cleanly.

import type { APIGatewayBotInfo } from "discord-api-types/v10";
import { HttpsProxyAgent } from "https-proxy-agent";
import type { DiscordAccountConfig } from "openclaw/plugin-sdk/config-types";
import { danger } from "openclaw/plugin-sdk/runtime-env";
import type { RuntimeEnv } from "openclaw/plugin-sdk/runtime-env";
import { ProxyAgent, fetch as undiciFetch } from "undici";
import WebSocket from "ws";
import * as discordGateway from "../internal/gateway.js";
import {
  fetchDiscordGatewayInfoWithTimeout,
  resolveDiscordGatewayInfoTimeoutMs,
  resolveGatewayInfoWithFallback,
} from "./gateway-metadata.js";
import { ResilientGatewayPlugin, resolveDiscordGatewayIntents } from "./gateway-plugin.js";

/** A resume that lasts less than this is considered a "flap". */
const STABLE_CONNECTION_MS = 60_000;
/** After this many consecutive flaps, force a fresh IDENTIFY. */
const MAX_RAPID_RESUMES = 8;

type KiroGatewayPluginParams = {
  runtime?: RuntimeEnv;
  /** Configured gateway-info timeout (ms); resolved against env + default. */
  gatewayInfoTimeoutMs?: number;
};

class KiroGatewayPlugin extends ResilientGatewayPlugin {
  protected readonly runtime: RuntimeEnv | undefined;
  protected readonly gatewayInfoTimeoutMs: number;
  private gatewayInfoUsedFallback = false;
  private _lastResumedAt = 0;
  private _rapidResumeCount = 0;
  private _backoffTimer: ReturnType<typeof setTimeout> | undefined;

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

  constructor(
    options: ConstructorParameters<typeof discordGateway.GatewayPlugin>[0],
    params?: KiroGatewayPluginParams,
  ) {
    super(options);
    this.runtime = params?.runtime;
    this.gatewayInfoTimeoutMs = resolveDiscordGatewayInfoTimeoutMs({
      configuredTimeoutMs: params?.gatewayInfoTimeoutMs,
      env: process.env,
    });

    // Patch setupWebSocket to add flap detection logging.
    const origSetup = (
      this as unknown as { setupWebSocket: (r?: boolean) => void }
    ).setupWebSocket.bind(this);
    (this as unknown as { setupWebSocket: (r?: boolean) => void }).setupWebSocket = (
      resume?: boolean,
    ) => {
      origSetup(resume);
      const ws = (this as unknown as { ws: WebSocket | null }).ws;
      if (!ws) {
        return;
      }
      ws.on("message", (data: WebSocket.Data) => {
        try {
          const raw =
            typeof data === "string" ? data : Buffer.isBuffer(data) ? data.toString("utf8") : "";
          const parsed = JSON.parse(raw);
          if (parsed?.op === 0 && (parsed?.t === "READY" || parsed?.t === "RESUMED")) {
            this._lastResumedAt = Date.now();
            this.emitter.emit("debug", `Resumed successfully (${parsed.t})`);
          }
        } catch {
          // Ignore — parent handles validation.
        }
      });
    };
  }

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

    // Exponential backoff with jitter when attempts pile up.
    const attempts = this._reconnectAttempts;
    if (attempts > 3) {
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
        super.connect(resume);
      }, delay);
      return;
    }

    super.connect(resume);
  }

  override disconnect(): void {
    if (this._backoffTimer) {
      clearTimeout(this._backoffTimer);
      this._backoffTimer = undefined;
    }
    super.disconnect();
  }

  /**
   * Overridable metadata fetch. The proxy variant swaps in an undici fetch with
   * a dispatcher; the default uses the global fetch. Both go through the shared
   * timeout wrapper so a hung lookup cannot stall registration.
   */
  protected fetchGatewayInfo(token: string): Promise<APIGatewayBotInfo> {
    return fetchDiscordGatewayInfoWithTimeout({
      token,
      fetchImpl: (input, init) => fetch(input, init as RequestInit),
      timeoutMs: this.gatewayInfoTimeoutMs,
    });
  }

  override registerClient(client: unknown) {
    const registration = this.registerClientInternal(client);
    // client.ts registers plugins fire-and-forget (`void plugin.registerClient`).
    // Mark the promise handled so a transient/fatal metadata failure becomes a
    // logged fallback or rejected registration — never an unhandled rejection
    // that crashes the gateway process (e.g. ENOTFOUND on machine wake).
    registration.catch(() => {});
    return registration;
  }

  private async registerClientInternal(client: unknown) {
    // Re-fetch when the last attempt fell back to the default url, so a healthy
    // network on a later reconnect upgrades us off the fallback gateway.
    if (!this.gatewayInfo || this.gatewayInfoUsedFallback) {
      const token = (client as { options: { token: string } }).options.token;
      const resolved = await this.fetchGatewayInfo(token)
        .then((info) => ({ info, usedFallback: false }))
        .catch((error) => resolveGatewayInfoWithFallback({ runtime: this.runtime, error }));
      this.gatewayInfo = resolved.info;
      this.gatewayInfoUsedFallback = resolved.usedFallback;
    }
    return super.registerClient(client as never);
  }
}

export function createKiroGatewayPlugin(params: {
  discordConfig: DiscordAccountConfig;
  runtime: RuntimeEnv;
}): discordGateway.GatewayPlugin {
  const intents = resolveDiscordGatewayIntents(
    params.discordConfig?.intents as Parameters<typeof resolveDiscordGatewayIntents>[0],
  );
  const proxy = params.discordConfig?.proxy?.trim();
  const options = {
    reconnect: { maxAttempts: 50 },
    intents,
    autoInteractions: true,
  };
  const pluginParams: KiroGatewayPluginParams = {
    runtime: params.runtime,
    gatewayInfoTimeoutMs: params.discordConfig?.gatewayInfoTimeoutMs,
  };

  if (!proxy) {
    return new KiroGatewayPlugin(options, pluginParams) as unknown as discordGateway.GatewayPlugin;
  }

  try {
    const wsAgent = new HttpsProxyAgent(proxy);
    const fetchAgent = new ProxyAgent(proxy);
    params.runtime.log?.("discord: gateway proxy enabled");

    class ProxyKiroGatewayPlugin extends KiroGatewayPlugin {
      protected override fetchGatewayInfo(token: string): Promise<APIGatewayBotInfo> {
        return fetchDiscordGatewayInfoWithTimeout({
          token,
          fetchImpl: (input, init) => undiciFetch(input, init),
          fetchInit: { dispatcher: fetchAgent },
          timeoutMs: this.gatewayInfoTimeoutMs,
        });
      }

      override createWebSocket(url: string) {
        return new WebSocket(url, { agent: wsAgent });
      }
    }

    return new ProxyKiroGatewayPlugin(
      options,
      pluginParams,
    ) as unknown as discordGateway.GatewayPlugin;
  } catch (err) {
    params.runtime.error?.(danger(`discord: invalid gateway proxy: ${String(err)}`));
    return new KiroGatewayPlugin(options, pluginParams) as unknown as discordGateway.GatewayPlugin;
  }
}
