/**
 * HTTP server tests for the kiro-proxy.
 *
 * Tests the OpenAI-compatible endpoint behaviour without spawning a real
 * kiro-cli process — the SessionManager is replaced with a lightweight stub.
 */

import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { KiroSession } from "./kiro-session.js";
import { createKiroProxyServer } from "./server.js";
import type { SessionManager } from "./session-manager.js";

// ─── Stubs ────────────────────────────────────────────────────────────────────

function makeSession(reply: string, alive = true): KiroSession {
  return {
    acpSessionId: "test-acp-session",
    lastTouchedAt: Date.now(),
    sentMessageCount: 0,
    alive,
    async prompt(_text: string, onChunk: (t: string) => void): Promise<string> {
      onChunk(reply);
      return "end_turn";
    },
    kill: vi.fn(),
  } as unknown as KiroSession;
}

function makeManager(
  reply: string,
  opts: { alive?: boolean; throwOnGetOrCreate?: boolean } = {},
): SessionManager {
  const session = makeSession(reply, opts.alive ?? true);
  return {
    getOrCreate: opts.throwOnGetOrCreate
      ? vi.fn().mockRejectedValue(new Error("kiro startup failure"))
      : vi.fn().mockResolvedValue({ session, promptText: "latest user message" }),
    shutdown: vi.fn(),
    resolveSessionKey: vi.fn().mockReturnValue("test-session-key"),
  } as unknown as SessionManager;
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

type FetchOpts = {
  method?: string;
  body?: unknown;
  headers?: Record<string, string>;
};

async function testFetch(
  baseUrl: string,
  path: string,
  opts: FetchOpts = {},
): Promise<{ status: number; body: unknown; headers: Record<string, string> }> {
  const { method = "GET", body, headers = {} } = opts;
  const init: RequestInit = { method, headers: { ...headers } };
  if (body !== undefined) {
    (init.headers as Record<string, string>)["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const res = await fetch(`${baseUrl}${path}`, init);
  const text = await res.text();
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  const respHeaders: Record<string, string> = {};
  res.headers.forEach((v, k) => {
    respHeaders[k] = v;
  });
  return { status: res.status, body: parsed, headers: respHeaders };
}

// ─── Test lifecycle ───────────────────────────────────────────────────────────

let baseUrl = "";
let currentServer: ReturnType<typeof createServer> | null = null;

function startServer(manager: SessionManager): Promise<string> {
  return new Promise((resolve, reject) => {
    const srv = createKiroProxyServer(manager, { verbose: false });
    currentServer = srv;
    srv.listen(0, "127.0.0.1", () => {
      const port = (srv.address() as AddressInfo).port;
      resolve(`http://127.0.0.1:${port}`);
    });
    srv.once("error", reject);
  });
}

afterEach(() => {
  if (currentServer) {
    currentServer.close();
    currentServer = null;
  }
  baseUrl = "";
});

// ─── Health / Models ──────────────────────────────────────────────────────────

describe("GET /health", () => {
  beforeEach(async () => {
    baseUrl = await startServer(makeManager("ok"));
  });

  it("returns 200 with status ok", async () => {
    const { status, body } = await testFetch(baseUrl, "/health");
    expect(status).toBe(200);
    expect(body).toMatchObject({ status: "ok", service: "kiro-proxy" });
  });

  it("root path also returns 200", async () => {
    const { status } = await testFetch(baseUrl, "/");
    expect(status).toBe(200);
  });
});

describe("GET /v1/models", () => {
  beforeEach(async () => {
    baseUrl = await startServer(makeManager("ok"));
  });

  it("returns the kiro-default model", async () => {
    const { status, body } = await testFetch(baseUrl, "/v1/models");
    expect(status).toBe(200);
    const b = body as { data: Array<{ id: string }> };
    expect(b.data).toHaveLength(1);
    expect(b.data[0]?.id).toBe("kiro-default");
  });
});

describe("404 for unknown routes", () => {
  beforeEach(async () => {
    baseUrl = await startServer(makeManager("ok"));
  });

  it("returns 404", async () => {
    const { status } = await testFetch(baseUrl, "/v1/unknown");
    expect(status).toBe(404);
  });
});

// ─── POST /v1/chat/completions — blocking ─────────────────────────────────────

describe("POST /v1/chat/completions (stream: false)", () => {
  beforeEach(async () => {
    baseUrl = await startServer(makeManager("Hello from Kiro!"));
  });

  it("returns a chat completion object with the agent reply", async () => {
    const { status, body } = await testFetch(baseUrl, "/v1/chat/completions", {
      method: "POST",
      body: {
        model: "kiro-default",
        stream: false,
        messages: [{ role: "user", content: "Hi" }],
      },
    });
    expect(status).toBe(200);
    const b = body as { object: string; choices: Array<{ message: { content: string } }> };
    expect(b.object).toBe("chat.completion");
    expect(b.choices[0]?.message.content).toBe("Hello from Kiro!");
  });

  it("returns 400 for malformed JSON", async () => {
    const res = await fetch(`${baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not-json{{{",
    });
    expect(res.status).toBe(400);
  });

  it("returns 400 when messages array is missing", async () => {
    const { status } = await testFetch(baseUrl, "/v1/chat/completions", {
      method: "POST",
      body: { model: "kiro-default", stream: false },
    });
    expect(status).toBe(400);
  });

  it("returns 400 when messages is an empty array", async () => {
    const { status } = await testFetch(baseUrl, "/v1/chat/completions", {
      method: "POST",
      body: { model: "kiro-default", stream: false, messages: [] },
    });
    expect(status).toBe(400);
  });

  it("returns 503 when kiro session fails to start", async () => {
    const failManager = makeManager("", { throwOnGetOrCreate: true });
    const extraServer = createKiroProxyServer(failManager, { verbose: false });
    const failUrl = await new Promise<string>((resolve, reject) => {
      extraServer.listen(0, "127.0.0.1", () => {
        const port = (extraServer.address() as AddressInfo).port;
        resolve(`http://127.0.0.1:${port}`);
      });
      extraServer.once("error", reject);
    });
    try {
      const res = await fetch(`${failUrl}/v1/chat/completions`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: "kiro-default",
          stream: false,
          messages: [{ role: "user", content: "Hi" }],
        }),
      });
      expect(res.status).toBe(503);
    } finally {
      await new Promise<void>((r) => extraServer.close(() => r()));
    }
  });
});

// ─── POST /v1/chat/completions — streaming ────────────────────────────────────

describe("POST /v1/chat/completions (stream: true)", () => {
  beforeEach(async () => {
    baseUrl = await startServer(makeManager("streamed chunk"));
  });

  it("returns text/event-stream content type", async () => {
    const res = await fetch(`${baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "kiro-default",
        stream: true,
        messages: [{ role: "user", content: "Hi" }],
      }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/event-stream");
    await res.body?.cancel();
  });

  it("SSE stream contains the agent text chunk and [DONE]", async () => {
    const res = await fetch(`${baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "kiro-default",
        stream: true,
        messages: [{ role: "user", content: "Hi" }],
      }),
    });
    const text = await res.text();
    // Should contain the streamed chunk
    expect(text).toContain("streamed chunk");
    // Should end with [DONE]
    expect(text).toContain("data: [DONE]");
  });

  it("default (no stream field) behaves as streaming", async () => {
    const res = await fetch(`${baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "kiro-default",
        messages: [{ role: "user", content: "Hi" }],
      }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/event-stream");
    await res.body?.cancel();
  });
});

// ─── CORS ─────────────────────────────────────────────────────────────────────

describe("CORS", () => {
  beforeEach(async () => {
    baseUrl = await startServer(makeManager("ok"));
  });

  it("responds to OPTIONS pre-flight with 204", async () => {
    const res = await fetch(`${baseUrl}/v1/chat/completions`, { method: "OPTIONS" });
    expect(res.status).toBe(204);
  });

  it("includes Access-Control-Allow-Origin on all responses", async () => {
    const { headers } = await testFetch(baseUrl, "/health");
    expect(headers["access-control-allow-origin"]).toBe("*");
  });
});
