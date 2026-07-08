import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

function createGatewayInfoBody(overrides?: { url?: string; shards?: number }): string {
  return JSON.stringify({
    url: overrides?.url ?? "wss://gateway.discord.gg",
    shards: overrides?.shards ?? 1,
    session_start_limit: {
      total: 1000,
      remaining: 999,
      reset_after: 120_000,
      max_concurrency: 1,
    },
  });
}

const { GatewayIntents, GatewayPlugin, baseRegisterClientSpy, globalFetchMock } = vi.hoisted(() => {
  const baseRegisterClientSpy = vi.fn();
  const globalFetchMock = vi.fn();

  const GatewayIntents = {
    Guilds: 1 << 0,
    GuildMessages: 1 << 1,
    MessageContent: 1 << 2,
    DirectMessages: 1 << 3,
    GuildMessageReactions: 1 << 4,
    DirectMessageReactions: 1 << 5,
    GuildPresences: 1 << 6,
    GuildMembers: 1 << 7,
    GuildVoiceStates: 1 << 8,
  } as const;

  // Minimal base matching ../internal/gateway.js GatewayPlugin surface the fork
  // patches. setupWebSocket is monkey-patched in the constructor, so it must exist.
  class GatewayPlugin {
    options: unknown;
    gatewayInfo: unknown;
    emitter = { emit: vi.fn(), on: vi.fn() };
    ws: unknown = null;
    reconnectAttempts = 0;
    sequence: number | null = null;
    state = { sessionId: null, resumeGatewayUrl: null, sequence: null };
    constructor(options?: unknown) {
      this.options = options;
    }
    setupWebSocket(_resume?: boolean): void {}
    async registerClient(client: unknown) {
      baseRegisterClientSpy(client);
    }
    connect(_resume = false): void {}
    disconnect(): void {}
  }

  return { GatewayIntents, GatewayPlugin, baseRegisterClientSpy, globalFetchMock };
});

vi.mock("../internal/gateway.js", () => ({
  GatewayIntents,
  GatewayPlugin,
}));

// ws default export is invoked when setupWebSocket runs; keep it inert.
vi.mock("ws", () => ({
  default: class MockWebSocket {
    on() {}
  },
}));

vi.mock("openclaw/plugin-sdk/runtime-env", () => ({
  danger: (value: string) => value,
}));

vi.mock("openclaw/plugin-sdk/ssrf-runtime", () => ({
  fetchWithSsrFGuard: vi.fn(async (params: { url: string; init?: RequestInit }) => {
    const source = (await globalFetchMock(params.url, params.init)) as Response;
    const body = await source.text();
    return {
      response: new Response(body, {
        status: source.status,
        statusText: source.statusText,
        headers: source.headers,
      }),
      release: vi.fn(),
    };
  }),
}));

vi.mock("openclaw/plugin-sdk/proxy-capture", () => ({
  captureHttpExchange: vi.fn(),
  captureWsEvent: vi.fn(),
}));

describe("createKiroGatewayPlugin", () => {
  let createKiroGatewayPlugin: typeof import("./gateway-plugin-kiro.js").createKiroGatewayPlugin;

  beforeAll(async () => {
    ({ createKiroGatewayPlugin } = await import("./gateway-plugin-kiro.js"));
  });

  function createRuntime() {
    return { log: vi.fn(), error: vi.fn(), exit: vi.fn() };
  }

  function registerClient(plugin: unknown, token = "token-123") {
    return (
      plugin as {
        registerClient: (client: { options: { token: string } }) => Promise<void>;
      }
    ).registerClient({ options: { token } });
  }

  function gatewayUrl(plugin: unknown): string | undefined {
    return (plugin as { gatewayInfo?: { url?: string } }).gatewayInfo?.url;
  }

  beforeEach(() => {
    vi.unstubAllEnvs();
    vi.stubGlobal("fetch", globalFetchMock);
    baseRegisterClientSpy.mockReset();
    globalFetchMock.mockReset();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.useRealTimers();
  });

  it("fetches and uses real gateway metadata on the happy path", async () => {
    const plugin = createKiroGatewayPlugin({ discordConfig: {}, runtime: createRuntime() });
    globalFetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      text: async () => createGatewayInfoBody(),
    } as Response);

    await registerClient(plugin);

    expect(globalFetchMock).toHaveBeenCalledWith(
      "https://discord.com/api/v10/gateway/bot",
      expect.objectContaining({ headers: { Authorization: "Bot token-123" } }),
    );
    expect(baseRegisterClientSpy).toHaveBeenCalledTimes(1);
    expect(gatewayUrl(plugin)).toBe("wss://gateway.discord.gg");
  });

  it("falls back to the default gateway url on a transient metadata failure", async () => {
    const runtime = createRuntime();
    const plugin = createKiroGatewayPlugin({ discordConfig: {}, runtime });
    globalFetchMock.mockResolvedValue({
      ok: false,
      status: 503,
      text: async () =>
        "upstream connect error or disconnect/reset before headers. reset reason: overflow",
    } as Response);

    await registerClient(plugin);

    // Registration still proceeds against the fallback url — the gateway connects.
    expect(baseRegisterClientSpy).toHaveBeenCalledTimes(1);
    expect(gatewayUrl(plugin)).toBe("wss://gateway.discord.gg/");
    expect(runtime.log).toHaveBeenCalledWith(
      expect.stringContaining("discord: gateway metadata lookup failed transiently"),
    );
  });

  it("does not crash the process when a fire-and-forget registration hits a transient DNS error", async () => {
    // Reproduces the machine-wake crash: client.ts calls `void plugin.registerClient(...)`,
    // so a rejection here would surface as an unhandledRejection and exit the gateway.
    const runtime = createRuntime();
    const plugin = createKiroGatewayPlugin({ discordConfig: {}, runtime });
    globalFetchMock.mockRejectedValue(
      Object.assign(new Error("getaddrinfo ENOTFOUND discord.com"), { code: "ENOTFOUND" }),
    );

    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    try {
      void registerClient(plugin);
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));

      expect(unhandled).toHaveLength(0);
      expect(gatewayUrl(plugin)).toBe("wss://gateway.discord.gg/");
      expect(baseRegisterClientSpy).toHaveBeenCalledTimes(1);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  it("re-fetches real metadata on the next register after a fallback", async () => {
    const plugin = createKiroGatewayPlugin({ discordConfig: {}, runtime: createRuntime() });
    globalFetchMock
      .mockResolvedValueOnce({
        ok: false,
        status: 503,
        text: async () => "upstream connect error",
      } as Response)
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        text: async () =>
          createGatewayInfoBody({ url: "wss://gateway.discord.gg/?v=10", shards: 8 }),
      } as Response);

    await registerClient(plugin);
    await registerClient(plugin);

    expect(globalFetchMock).toHaveBeenCalledTimes(2);
    expect(baseRegisterClientSpy).toHaveBeenCalledTimes(2);
    expect(gatewayUrl(plugin)).toBe("wss://gateway.discord.gg/?v=10");
  });

  it("does not re-fetch metadata once a real lookup succeeds", async () => {
    const plugin = createKiroGatewayPlugin({ discordConfig: {}, runtime: createRuntime() });
    globalFetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      text: async () => createGatewayInfoBody(),
    } as Response);

    await registerClient(plugin);
    await registerClient(plugin);

    expect(globalFetchMock).toHaveBeenCalledTimes(1);
    expect(baseRegisterClientSpy).toHaveBeenCalledTimes(2);
  });

  it("falls back to the default gateway url when the metadata lookup times out", async () => {
    vi.useFakeTimers();
    const runtime = createRuntime();
    const plugin = createKiroGatewayPlugin({
      discordConfig: { gatewayInfoTimeoutMs: 5_000 },
      runtime,
    });
    globalFetchMock.mockImplementation(() => new Promise(() => {}));

    const registration = registerClient(plugin);
    await vi.advanceTimersByTimeAsync(4_999);
    expect(baseRegisterClientSpy).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await registration;

    expect(gatewayUrl(plugin)).toBe("wss://gateway.discord.gg/");
    expect(baseRegisterClientSpy).toHaveBeenCalledTimes(1);
  });
});
