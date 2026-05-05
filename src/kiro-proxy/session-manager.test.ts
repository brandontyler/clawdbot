import { describe, expect, it } from "vitest";
import { SessionManager } from "./session-manager.js";
import type { OpenAIMessage } from "./types.js";

// ─── resolveSessionKey ────────────────────────────────────────────────────────

describe("SessionManager.resolveSessionKey", () => {
  const msgs: OpenAIMessage[] = [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user", content: "Hello world" },
    { role: "assistant", content: "Hi there!" },
    { role: "user", content: "Second turn" },
  ];

  it("returns explicit key when provided (non-empty string)", () => {
    const key = SessionManager.resolveSessionKey(msgs, "my-session-id");
    expect(key).toBe("my-session-id");
  });

  it("ignores blank explicit keys and falls back to fingerprint", () => {
    const keyBlank = SessionManager.resolveSessionKey(msgs, "   ");
    const keyUndefined = SessionManager.resolveSessionKey(msgs, undefined);
    expect(keyBlank).toBe(keyUndefined);
    expect(keyBlank).not.toBe("   ");
  });

  it("produces a stable 32-character hex string", () => {
    const key = SessionManager.resolveSessionKey(msgs);
    expect(key).toMatch(/^[0-9a-f]{32}$/);
  });

  it("produces the same key for identical first messages (session stability)", () => {
    const turn1: OpenAIMessage[] = [
      { role: "system", content: "You are a helpful assistant." },
      { role: "user", content: "Hello world" },
    ];
    const turn2: OpenAIMessage[] = [
      { role: "system", content: "You are a helpful assistant." },
      { role: "user", content: "Hello world" },
      { role: "assistant", content: "Hi there!" },
      { role: "user", content: "Second turn" },
    ];
    expect(SessionManager.resolveSessionKey(turn1)).toBe(SessionManager.resolveSessionKey(turn2));
  });

  it("produces different keys for different first user messages", () => {
    const a: OpenAIMessage[] = [{ role: "user", content: "Question A" }];
    const b: OpenAIMessage[] = [{ role: "user", content: "Question B" }];
    expect(SessionManager.resolveSessionKey(a)).not.toBe(SessionManager.resolveSessionKey(b));
  });

  it("considers the system message part of the fingerprint", () => {
    const withSystem: OpenAIMessage[] = [
      { role: "system", content: "Be concise." },
      { role: "user", content: "Same question" },
    ];
    const withoutSystem: OpenAIMessage[] = [{ role: "user", content: "Same question" }];
    expect(SessionManager.resolveSessionKey(withSystem)).not.toBe(
      SessionManager.resolveSessionKey(withoutSystem),
    );
  });

  it("handles a single user message (no system prompt)", () => {
    const key = SessionManager.resolveSessionKey([{ role: "user", content: "Hello" }]);
    expect(key).toMatch(/^[0-9a-f]{32}$/);
  });

  it("handles assistant-only messages (no user or system)", () => {
    // Edge case: no system/user messages → empty anchor → deterministic hash
    const key = SessionManager.resolveSessionKey([
      { role: "assistant", content: "I said something" },
    ]);
    expect(key).toMatch(/^[0-9a-f]{32}$/);
  });

  it("truncates very long first user content to 512 chars for fingerprint", () => {
    const longContent = "x".repeat(2000);
    const truncatedContent = "x".repeat(512);

    const long: OpenAIMessage[] = [{ role: "user", content: longContent }];
    const truncated: OpenAIMessage[] = [{ role: "user", content: truncatedContent }];

    // Both should produce the same fingerprint (content is sliced to 512)
    expect(SessionManager.resolveSessionKey(long)).toBe(
      SessionManager.resolveSessionKey(truncated),
    );
  });
});

// ─── resolveSessionTag ────────────────────────────────────────────────────────

import { resolveSessionTag, detectChannelId } from "./session-manager.js";

describe("detectChannelId", () => {
  it("extracts channel ID from an OpenClaw session key", () => {
    expect(detectChannelId("agent:main:discord:channel:1475216992956059698")).toBe(
      "1475216992956059698",
    );
  });

  it("returns undefined for non-Discord keys", () => {
    expect(detectChannelId("agent:main:telegram:chat:12345")).toBeUndefined();
  });

  it("returns undefined for undefined input", () => {
    expect(detectChannelId(undefined)).toBeUndefined();
  });
});

describe("resolveSessionTag", () => {
  it("returns project name for known channel routes", () => {
    const routes = { "123456": { cwd: "/home/user/code/myproject" } };
    const tag = resolveSessionTag("agent:main:discord:channel:123456", routes);
    expect(tag).toBe("myproject(3456)");
  });

  it("returns short channel ID for unknown routes", () => {
    const tag = resolveSessionTag("agent:main:discord:channel:999888777", {});
    expect(tag).toBe("ch:888777");
  });

  it("returns truncated key for non-channel session keys", () => {
    const tag = resolveSessionTag("abcdef1234567890abcdef", {});
    expect(tag).toBe("abcdef1234567890…");
  });
});
