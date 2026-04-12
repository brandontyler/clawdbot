// ─── Kiro-specific gateway hardening ──────────────────────────────────────────
//
// Extends upstream's ResilientGatewayPlugin with:
// - Flap detection: force fresh IDENTIFY after repeated rapid disconnects
// - Exponential backoff with jitter on reconnect attempts
// - "Resumed successfully" debug logging
// - Safe gateway metadata fetch via fetchDiscordGatewayInfo (upstream improvement)
//
// Kept in a separate file so upstream gateway-plugin.ts can be synced cleanly.

import { GatewayPlugin } from "@buape/carbon/gateway";
import { HttpsProxyAgent } from "https-proxy-agent";
import type { DiscordAccountConfig } from "openclaw/plugin-sdk/config-runtime";
import { danger } from "openclaw/plugin-sdk/runtime-env";
import type { RuntimeEnv } from "openclaw/plugin-sdk/runtime-env";
import { ProxyAgent, fetch as undiciFetch } from "undici";
import WebSocket from "ws";
import {
  ResilientGatewayPlugin,
  fetchDiscordGatewayInfo,
  resolveDiscordGatewayIntents,
} from "./gateway-plugin.js";

/** A resume that lasts less than this is considered a "flap". */
const STABLE_CONNECTION_MS = 60_000;
/** After this many consecutive flaps, force a fresh IDENTIFY. */
const MAX_RAPID_RESUMES = 8;

class KiroGatewayPlugin extends ResilientGatewayPlugin {
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

  override setupWebSocket(): void {
    super.setupWebSocket();

    const ws = (this as unknown as { ws: WebSocket | null }).ws;
    if (!ws) {
      return;
    }

    // Track successful READY/RESUMED for flap detection.
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
}

class SafeKiroGatewayPlugin extends KiroGatewayPlugin {
  override async registerClient(client: Parameters<GatewayPlugin["registerClient"]>[0]) {
    if (!this.gatewayInfo) {
      this.gatewayInfo = await fetchDiscordGatewayInfo({
        token: client.options.token,
        fetchImpl: (input, init) => fetch(input, init as RequestInit),
      });
    }
    return super.registerClient(client);
  }
}

export function createKiroGatewayPlugin(params: {
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
    return new SafeKiroGatewayPlugin(options);
  }

  try {
    const wsAgent = new HttpsProxyAgent(proxy);
    const fetchAgent = new ProxyAgent(proxy);
    params.runtime.log?.("discord: gateway proxy enabled");

    class ProxyKiroGatewayPlugin extends KiroGatewayPlugin {
      constructor() {
        super(options);
      }

      override async registerClient(client: Parameters<GatewayPlugin["registerClient"]>[0]) {
        if (!this.gatewayInfo) {
          this.gatewayInfo = await fetchDiscordGatewayInfo({
            token: client.options.token,
            fetchImpl: (input, init) => undiciFetch(input, init),
            fetchInit: { dispatcher: fetchAgent },
          });
        }
        return super.registerClient(client);
      }

      override createWebSocket(url: string) {
        return new WebSocket(url, { agent: wsAgent });
      }
    }

    return new ProxyKiroGatewayPlugin();
  } catch (err) {
    params.runtime.error?.(danger(`discord: invalid gateway proxy: ${String(err)}`));
    return new SafeKiroGatewayPlugin(options);
  }
}
