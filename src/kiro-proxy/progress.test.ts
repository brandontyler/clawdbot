/**
 * ProgressReporter.finish() honest-card gate.
 *
 * Regression guard for the "Done (30s, 0 tools)" bug: when an agent run
 * produces no assistant text (first-token timeout, empty ACP response, killed
 * stale session), the proxy must NOT finalize the progress card as "✅ Done" —
 * that reads as a successful reply when nothing reached the user. It must show
 * an honest "⚠️ No reply" instead.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Capture what the reporter posts/edits to Discord without hitting the network.
const editedContent: string[] = [];
vi.mock("./discord-api.js", () => ({
  postMessage: vi.fn().mockResolvedValue("msg-1"),
  editMessage: vi
    .fn()
    .mockImplementation((_channelId: string, _messageId: string, content: string) => {
      editedContent.push(content);
      return Promise.resolve();
    }),
}));

import { ProgressReporter } from "./progress.js";

/** Start a reporter and wait for its initial postMessage to resolve a messageId. */
async function startReporter(): Promise<ProgressReporter> {
  const reporter = new ProgressReporter(() => {});
  reporter.start("channel-123", 0);
  // start() fires sendOrEdit() (which calls postMessage) without awaiting it;
  // flush the microtask queue so messageId is set before finish().
  await Promise.resolve();
  await Promise.resolve();
  return reporter;
}

/** The last content the reporter wrote to Discord (the finalized card). */
function finalCard(): string {
  return editedContent[editedContent.length - 1] ?? "";
}

beforeEach(() => {
  editedContent.length = 0;
});

afterEach(() => {
  vi.clearAllMocks();
});

describe("ProgressReporter.finish honest-card gate", () => {
  it("renders ✅ Done when the model produced text", async () => {
    const reporter = await startReporter();
    reporter.onToolCall("Read file", "read", "completed", true);

    await reporter.finish(true);

    expect(finalCard()).toContain("✅ **Done**");
    expect(finalCard()).not.toContain("No reply");
  });

  it("renders ⚠️ No reply (not Done) on a timeout with zero tools", async () => {
    // The exact "Done (30s, 0 tools)" scenario: first-token timeout, no text,
    // no tools. This must never read as a successful reply.
    const reporter = await startReporter();

    await reporter.finish(false);

    const card = finalCard();
    expect(card).toContain("⚠️ **No reply**");
    expect(card).toContain("timed out");
    expect(card).not.toContain("✅ **Done**");
  });

  it("renders ⚠️ No reply when tools ran but no answer was produced", async () => {
    const reporter = await startReporter();
    reporter.onToolCall("br list", "execute", "completed", true);
    reporter.onToolCall("Read SKILL.md", "read", "completed", true);

    await reporter.finish(false);

    const card = finalCard();
    expect(card).toContain("⚠️ **No reply**");
    expect(card).toContain("ran tools but returned no answer");
    expect(card).not.toContain("✅ **Done**");
  });

  it("is a no-op when finish runs without an active prompt", async () => {
    const reporter = new ProgressReporter(() => {});
    // Never started — finish() must not post or throw.
    await reporter.finish(false);
    expect(editedContent).toHaveLength(0);
  });
});
