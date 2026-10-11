import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { KiroSession, KiroSessionEvents } from "./kiro-session.js";
import type { OpenAIMessage } from "./types.js";

const tempDirs: string[] = [];
const managers: Array<{ shutdown: () => void }> = [];
const originalHibernatePath = process.env.KIRO_PROXY_HIBERNATE_PATH;

afterEach(() => {
  for (const manager of managers.splice(0)) {
    manager.shutdown();
  }
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.resetModules();
  if (originalHibernatePath === undefined) {
    delete process.env.KIRO_PROXY_HIBERNATE_PATH;
  } else {
    process.env.KIRO_PROXY_HIBERNATE_PATH = originalHibernatePath;
  }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

type FakeSession = KiroSession & {
  alive: boolean;
  isCompacting: boolean;
  prompt: ReturnType<typeof vi.fn>;
  kill: ReturnType<typeof vi.fn>;
};

async function createHarness(
  autoCompaction = true,
  promptLockTimeoutMs?: number,
): Promise<{
  manager: InstanceType<(typeof import("./session-manager.js"))["SessionManager"]>;
  session: FakeSession;
  getEvents: () => KiroSessionEvents;
  promptOrder: string[];
}> {
  const tempDir = mkdtempSync(join(tmpdir(), "openclaw-kiro-compaction-"));
  tempDirs.push(tempDir);
  process.env.KIRO_PROXY_HIBERNATE_PATH = join(tempDir, "hibernated.json");
  vi.resetModules();

  const [{ SessionManager }, { KiroSession: KiroSessionClass }] = await Promise.all([
    import("./session-manager.js"),
    import("./kiro-session.js"),
  ]);

  let events: KiroSessionEvents = {};
  const promptOrder: string[] = [];
  const session = {
    acpSessionId: "same-acp-session",
    lastTouchedAt: Date.now(),
    sentMessageCount: 0,
    consecutiveErrors: 0,
    consecutiveEmptyResponses: 0,
    lastContextPct: 0,
    alive: true,
    isPrompting: false,
    isCompacting: false,
    wasLoaded: false,
    hasStreamedFirstToken: true,
    getRssKb: vi.fn(() => 1024),
    cancel: vi.fn(async () => {}),
    kill: vi.fn(),
    prompt: vi.fn(async (text: string) => {
      promptOrder.push(text);
      if (text === "/compact") {
        session.isCompacting = true;
        events.onCompactionStatus?.("started");
        await Promise.resolve();
        session.lastContextPct = 12;
        events.onContextUsage?.(12);
        session.isCompacting = false;
        events.onCompactionStatus?.("completed", "summary");
      }
      return "end_turn";
    }),
  } as unknown as FakeSession;

  vi.spyOn(KiroSessionClass, "create").mockImplementation(async (_opts, sessionEvents = {}) => {
    events = sessionEvents;
    return session;
  });

  const manager = new SessionManager(
    { kiroBin: "kiro-cli", kiroArgs: [], cwd: tempDir, verbose: false },
    { autoCompaction, idleSecs: 3600, promptLockTimeoutMs },
  );
  managers.push(manager);

  return { manager, session, getEvents: () => events, promptOrder };
}

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve: (value: T) => void = () => {};
  let reject: (error: unknown) => void = () => {};
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function createColdStartHarness(promptLockTimeoutMs = 1_000) {
  const tempDir = mkdtempSync(join(tmpdir(), "openclaw-kiro-cold-start-"));
  tempDirs.push(tempDir);
  process.env.KIRO_PROXY_HIBERNATE_PATH = join(tempDir, "hibernated.json");
  vi.resetModules();

  const [{ SessionManager }, { KiroSession: KiroSessionClass }] = await Promise.all([
    import("./session-manager.js"),
    import("./kiro-session.js"),
  ]);

  const promptOrder: string[] = [];
  const session = {
    acpSessionId: "cold-start-acp-session",
    lastTouchedAt: Date.now(),
    sentMessageCount: 0,
    consecutiveErrors: 0,
    consecutiveEmptyResponses: 0,
    lastContextPct: 0,
    alive: true,
    isPrompting: false,
    isCompacting: false,
    wasLoaded: false,
    hasStreamedFirstToken: true,
    getRssKb: vi.fn(() => 1024),
    cancel: vi.fn(async () => {}),
    kill: vi.fn(),
    prompt: vi.fn(async (text: string) => {
      promptOrder.push(text);
      return "end_turn";
    }),
  } as unknown as FakeSession;
  const createRequests: Deferred<KiroSession>[] = [];
  const createSpy = vi.spyOn(KiroSessionClass, "create").mockImplementation(() => {
    const request = deferred<KiroSession>();
    createRequests.push(request);
    return request.promise;
  });

  const manager = new SessionManager(
    { kiroBin: "kiro-cli", kiroArgs: [], cwd: tempDir, verbose: false },
    { autoCompaction: true, idleSecs: 3600, promptLockTimeoutMs },
  );
  managers.push(manager);

  return { manager, session, createRequests, createSpy, promptOrder };
}

const firstTurn: OpenAIMessage[] = [{ role: "user", content: "first turn" }];
const secondTurn: OpenAIMessage[] = [
  ...firstTurn,
  { role: "assistant", content: "first answer" },
  { role: "user", content: "second turn" },
];

describe("SessionManager cold-session creation", () => {
  it("singleflights concurrent first and second histories into one FIFO ACP session", async () => {
    const { manager, session, createRequests, createSpy, promptOrder } =
      await createColdStartHarness();

    const firstPending = manager.getOrCreate("test-session", firstTurn);
    let secondResolved = false;
    const secondPending = manager.getOrCreate("test-session", secondTurn).then((turn) => {
      secondResolved = true;
      return turn;
    });

    expect(createRequests).toHaveLength(1);
    expect(createSpy).toHaveBeenCalledTimes(1);
    createRequests[0].resolve(session);

    const first = await firstPending;
    expect(first.promptText).toBe("first turn");
    expect(secondResolved).toBe(false);
    await first.session.prompt(first.promptText, () => {});
    first.unlockPrompt?.();

    const second = await secondPending;
    expect(second.session).toBe(session);
    expect(second.promptText).toBe("second turn");
    await second.session.prompt(second.promptText, () => {});
    second.unlockPrompt?.();

    expect(createSpy).toHaveBeenCalledTimes(1);
    expect(promptOrder).toEqual(["first turn", "second turn"]);
  });

  it("cleans up a failed creation barrier so a waiting caller retries", async () => {
    const { manager, session, createRequests, createSpy } = await createColdStartHarness();
    const creationError = new Error("cold start failed");

    const firstPending = manager.getOrCreate("test-session", firstTurn);
    const retryPending = manager.getOrCreate("test-session", secondTurn);
    expect(createRequests).toHaveLength(1);

    createRequests[0].reject(creationError);
    await expect(firstPending).rejects.toBe(creationError);
    await Promise.resolve();

    expect(createRequests).toHaveLength(2);
    createRequests[1].resolve(session);
    const retry = await retryPending;

    expect(retry.session).toBe(session);
    expect(retry.promptText).toBe("first turn\n\nsecond turn");
    expect(createSpy).toHaveBeenCalledTimes(2);
    retry.unlockPrompt?.();
  });

  it("aborts a creation waiter without disturbing the owner or barrier", async () => {
    const { manager, session, createRequests, createSpy } = await createColdStartHarness();
    const controller = new AbortController();

    const firstPending = manager.getOrCreate("test-session", firstTurn);
    const abortedPending = manager.getOrCreate(
      "test-session",
      secondTurn,
      undefined,
      controller.signal,
    );
    controller.abort();

    await expect(abortedPending).rejects.toMatchObject({ name: "AbortError" });
    expect(createSpy).toHaveBeenCalledTimes(1);

    createRequests[0].resolve(session);
    const first = await firstPending;
    first.unlockPrompt?.();

    const retry = await manager.getOrCreate("test-session", secondTurn);
    expect(retry.promptText).toBe("second turn");
    expect(createSpy).toHaveBeenCalledTimes(1);
    retry.unlockPrompt?.();
  });

  it("bounds a creation waiter timeout without starting a second child", async () => {
    vi.useFakeTimers();
    const { manager, session, createRequests, createSpy } = await createColdStartHarness(25);

    const firstPending = manager.getOrCreate("test-session", firstTurn);
    const timedOutcome = manager.getOrCreate("test-session", secondTurn).then(
      () => ({ name: "acquired" }),
      (error: unknown) => error,
    );
    await vi.advanceTimersByTimeAsync(26);

    await expect(timedOutcome).resolves.toMatchObject({ name: "SessionCreationTimeoutError" });
    expect(createSpy).toHaveBeenCalledTimes(1);

    createRequests[0].resolve(session);
    const first = await firstPending;
    first.unlockPrompt?.();

    const retry = await manager.getOrCreate("test-session", secondTurn);
    expect(retry.promptText).toBe("second turn");
    expect(createSpy).toHaveBeenCalledTimes(1);
    retry.unlockPrompt?.();
  });
});

describe("SessionManager same-session compaction", () => {
  it("compacts above 60% before the next turn while preserving the ACP session", async () => {
    const { manager, session, getEvents, promptOrder } = await createHarness();
    const first = await manager.getOrCreate("test-session", firstTurn);

    await first.session.prompt(first.promptText, () => {});
    session.lastContextPct = 61;
    getEvents().onContextUsage?.(61);

    await expect(
      manager.autoCompactAfterPrompt("test-session", session, first.promptText),
    ).resolves.toMatchObject({ compacted: true, reason: "queued", beforePct: 61 });

    let secondResolved = false;
    const next = manager.getOrCreate("test-session", secondTurn).then((result) => {
      secondResolved = true;
      return result;
    });
    await Promise.resolve();
    expect(secondResolved).toBe(false);

    first.unlockPrompt?.();
    const second = await next;

    expect(promptOrder).toEqual(["first turn", "/compact"]);
    expect(second.session).toBe(session);
    expect(second.session.acpSessionId).toBe("same-acp-session");
    expect(session.lastContextPct).toBe(12);
    expect(session.kill).not.toHaveBeenCalled();
    second.unlockPrompt?.();
  });

  it("reserves serialization before evaluating delayed context metadata", async () => {
    const { manager, session, getEvents, promptOrder } = await createHarness();
    const first = await manager.getOrCreate("test-session", firstTurn);

    await first.session.prompt(first.promptText, () => {});
    session.lastContextPct = 59;

    await expect(
      manager.autoCompactAfterPrompt("test-session", session, first.promptText),
    ).resolves.toMatchObject({ compacted: true, reason: "queued", beforePct: 59 });

    // Reproduce the ACP ordering: prompt() has resolved, but its trailing
    // context metadata is delivered before the reserved queue slot runs.
    session.lastContextPct = 61;
    getEvents().onContextUsage?.(61);
    first.unlockPrompt?.();

    const next = await manager.getOrCreate("test-session", secondTurn);
    expect(promptOrder).toEqual(["first turn", "/compact"]);
    expect(next.session).toBe(session);
    expect(session.lastContextPct).toBe(12);
    next.unlockPrompt?.();
  });

  it("does not compact below the 60% threshold", async () => {
    const { manager, session } = await createHarness();
    const turn = await manager.getOrCreate("test-session", firstTurn);
    session.lastContextPct = 59.9;

    await expect(
      manager.autoCompactAfterPrompt("test-session", session, turn.promptText),
    ).resolves.toMatchObject({ compacted: true, reason: "queued", beforePct: 59.9 });
    turn.unlockPrompt?.();

    // Acquiring the next slot proves the reserved maintenance slot evaluated
    // the settled percentage and released the FIFO without compacting.
    const next = await manager.getOrCreate("test-session", secondTurn);
    expect(session.prompt).not.toHaveBeenCalledWith("/compact", expect.anything());
    next.unlockPrompt?.();
  });

  it("supports disabling only the proxy safeguard", async () => {
    const { manager, session } = await createHarness(false);
    const turn = await manager.getOrCreate("test-session", firstTurn);
    session.lastContextPct = 75;

    await expect(
      manager.autoCompactAfterPrompt("test-session", session, turn.promptText),
    ).resolves.toMatchObject({ compacted: false, reason: "disabled" });
    turn.unlockPrompt?.();

    expect(session.prompt).not.toHaveBeenCalledWith("/compact", expect.anything());
  });

  it("serves multiple prompt waiters in FIFO order", async () => {
    const { manager } = await createHarness();
    const first = await manager.getOrCreate("test-session", firstTurn);
    const thirdTurn: OpenAIMessage[] = [
      ...secondTurn,
      { role: "assistant", content: "second answer" },
      { role: "user", content: "third turn" },
    ];

    let secondResolved = false;
    let thirdResolved = false;
    const secondPending = manager.getOrCreate("test-session", secondTurn).then((turn) => {
      secondResolved = true;
      return turn;
    });
    const thirdPending = manager.getOrCreate("test-session", thirdTurn).then((turn) => {
      thirdResolved = true;
      return turn;
    });
    await Promise.resolve();
    expect(secondResolved).toBe(false);
    expect(thirdResolved).toBe(false);

    first.unlockPrompt?.();
    const second = await secondPending;
    expect(second.promptText).toBe("second turn");
    expect(thirdResolved).toBe(false);

    second.unlockPrompt?.();
    const third = await thirdPending;
    expect(third.promptText).toBe("third turn");
    third.unlockPrompt?.();
  });

  it("removes a cancelled waiter without blocking the next FIFO slot", async () => {
    const { manager } = await createHarness();
    const first = await manager.getOrCreate("test-session", firstTurn);
    const controller = new AbortController();
    const cancelledOutcome = manager
      .getOrCreate("test-session", secondTurn, undefined, controller.signal)
      .then(
        (turn) => {
          turn.unlockPrompt?.();
          return { name: "acquired" };
        },
        (error: unknown) => error,
      );
    const retryPending = manager.getOrCreate("test-session", secondTurn);

    controller.abort();
    first.unlockPrompt?.();

    await expect(cancelledOutcome).resolves.toMatchObject({ name: "AbortError" });
    const retry = await retryPending;
    expect(retry.promptText).toBe("second turn");
    retry.unlockPrompt?.();
  });

  it("times out and resets a stale prompt-lock owner", async () => {
    const { manager, session } = await createHarness(true, 20);
    const first = await manager.getOrCreate("test-session", firstTurn);
    const timedOutcome = manager.getOrCreate("test-session", secondTurn).then(
      (turn) => {
        turn.unlockPrompt?.();
        return { name: "acquired" };
      },
      (error: unknown) => error,
    );

    await new Promise<void>((resolve) => setTimeout(resolve, 40));
    first.unlockPrompt?.();

    await expect(timedOutcome).resolves.toMatchObject({ name: "PromptLockTimeoutError" });
    expect(session.kill).toHaveBeenCalledWith("auto-reset: prompt-lock-timeout-stale");
  });

  it("bounds a waiter timeout without killing a live prompt owner", async () => {
    const { manager, session } = await createHarness(true, 20);
    const first = await manager.getOrCreate("test-session", firstTurn);
    session.isPrompting = true;
    const timedOutcome = manager.getOrCreate("test-session", secondTurn).then(
      (turn) => {
        turn.unlockPrompt?.();
        return { name: "acquired" };
      },
      (error: unknown) => error,
    );

    await new Promise<void>((resolve) => setTimeout(resolve, 40));
    session.isPrompting = false;
    first.unlockPrompt?.();

    await expect(timedOutcome).resolves.toMatchObject({ name: "PromptLockTimeoutError" });
    expect(session.kill).not.toHaveBeenCalled();

    const retry = await manager.getOrCreate("test-session", secondTurn);
    expect(retry.promptText).toBe("second turn");
    retry.unlockPrompt?.();
  });

  it("runs manual compaction directly on the existing ACP child", async () => {
    const { manager, session, promptOrder } = await createHarness();
    const turn = await manager.getOrCreate("test-session", firstTurn);
    turn.unlockPrompt?.();
    session.lastContextPct = 72;

    await expect(manager.compactSession("test-session")).resolves.toMatchObject({
      compacted: true,
      reason: "completed",
      beforePct: 72,
      afterPct: 12,
    });

    expect(promptOrder).toEqual(["/compact"]);
    expect(session.acpSessionId).toBe("same-acp-session");
    expect(session.kill).not.toHaveBeenCalled();
  });

  it("advances observed messages so a plain-text /kcompact is not replayed next turn", async () => {
    const { manager, session, promptOrder } = await createHarness();
    const first = await manager.getOrCreate("test-session", firstTurn);
    first.unlockPrompt?.();
    session.lastContextPct = 72;

    const compactRequest: OpenAIMessage[] = [
      ...firstTurn,
      { role: "assistant", content: "first answer" },
      { role: "user", content: "/kcompact" },
    ];
    await expect(
      manager.compactSession("test-session", "/compact", compactRequest.length),
    ).resolves.toMatchObject({ compacted: true, reason: "completed" });

    const nextRequest: OpenAIMessage[] = [
      ...compactRequest,
      { role: "assistant", content: "compacted" },
      { role: "user", content: "next turn" },
    ];
    const next = await manager.getOrCreate("test-session", nextRequest);

    expect(next.promptText).toBe("next turn");
    expect(promptOrder).toEqual(["/compact"]);
    next.unlockPrompt?.();
  });

  it("does not replay gateway history into a resumed ACP session", async () => {
    const tempDir = mkdtempSync(join(tmpdir(), "openclaw-kiro-resume-"));
    tempDirs.push(tempDir);
    const hibernatePath = join(tempDir, "hibernated.json");
    process.env.KIRO_PROXY_HIBERNATE_PATH = hibernatePath;
    writeFileSync(
      hibernatePath,
      JSON.stringify({
        "test-session": {
          acpSessionId: "resumed-acp-session",
          cwd: tempDir,
          contextPct: 55,
          hibernatedAt: Date.now(),
        },
      }),
    );
    vi.resetModules();

    const [{ SessionManager }, { KiroSession: KiroSessionClass }] = await Promise.all([
      import("./session-manager.js"),
      import("./kiro-session.js"),
    ]);
    const resumed = {
      acpSessionId: "resumed-acp-session",
      lastTouchedAt: Date.now(),
      sentMessageCount: 0,
      consecutiveErrors: 0,
      consecutiveEmptyResponses: 0,
      lastContextPct: 55,
      alive: true,
      isPrompting: false,
      isCompacting: false,
      wasLoaded: true,
      hasStreamedFirstToken: true,
      getRssKb: vi.fn(() => 1024),
      cancel: vi.fn(async () => {}),
      kill: vi.fn(),
      prompt: vi.fn(async () => "end_turn"),
    } as unknown as FakeSession;
    vi.spyOn(KiroSessionClass, "load").mockResolvedValue(resumed);

    const manager = new SessionManager(
      { kiroBin: "kiro-cli", kiroArgs: [], cwd: tempDir, verbose: false },
      { autoCompaction: true, idleSecs: 3600 },
    );
    managers.push(manager);
    const messages: OpenAIMessage[] = [
      { role: "user", content: "old turn" },
      { role: "assistant", content: "old answer" },
      { role: "user", content: "latest turn" },
    ];

    const turn = await manager.getOrCreate("test-session", messages);

    expect(turn.session).toBe(resumed);
    expect(turn.promptText).toBe("latest turn");
    expect(KiroSessionClass.load).toHaveBeenCalledWith(
      "resumed-acp-session",
      expect.anything(),
      expect.anything(),
    );
    turn.unlockPrompt?.();
  });
});
