/**
 * kiro-proxy entry point.
 *
 * Starts an OpenAI-compatible HTTP server that routes all inference through
 * the locally-installed `kiro` CLI via the Agent Communication Protocol (ACP).
 *
 * Usage:
 *   node dist/kiro-proxy/index.js [options]
 *   openclaw kiro-proxy [options]
 *   pnpm kiro-proxy
 *
 * OpenClaw config:
 *   models:
 *     providers:
 *       kiro:
 *         baseUrl: http://127.0.0.1:18790
 *         apiKey: kiro-local
 *         api: openai-completions
 *         models:
 *           - id: kiro-default
 *             name: Kiro (AWS Bedrock)
 *             api: openai-completions
 *             contextWindow: 200000
 *             maxTokens: 8192
 *             input: [text]
 *             reasoning: false
 *             cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
 */

import { SessionManager } from "./session-manager.js";
import { createKiroProxyServer } from "./server.js";
import type { KiroProxyOptions } from "./types.js";

export { KiroSession } from "./kiro-session.js";
export { SessionManager } from "./session-manager.js";
export { createKiroProxyServer } from "./server.js";
export type { KiroProxyOptions } from "./types.js";

const DEFAULT_PORT = 18790;
const DEFAULT_HOST = "127.0.0.1";

export async function startKiroProxy(opts: KiroProxyOptions = {}): Promise<() => Promise<void>> {
  const port = opts.port ?? DEFAULT_PORT;
  const host = opts.host ?? DEFAULT_HOST;
  const kiroBin = opts.kiroBin ?? "kiro-cli";
  const kiroArgs = opts.kiroArgs ?? [];
  const cwd = opts.cwd ?? process.cwd();
  const idleSecs = opts.sessionIdleSecs ?? 1800;
  const verbose = opts.verbose ?? false;

  const log = verbose
    ? (msg: string) => process.stderr.write(`[kiro-proxy] ${msg}\n`)
    : () => {};

  log(`starting (kiro=${kiroBin}, port=${port}, idle=${idleSecs}s)`);

  const manager = new SessionManager(
    { kiroBin, kiroArgs, cwd, verbose },
    { idleSecs },
  );

  const server = createKiroProxyServer(manager, opts);

  await new Promise<void>((resolve, reject) => {
    server.listen(port, host, () => resolve());
    server.once("error", reject);
  });

  const addr = `http://${host}:${port}`;
  process.stderr.write(`[kiro-proxy] listening on ${addr}\n`);
  process.stderr.write(`[kiro-proxy] add to ~/.openclaw/config.yaml:\n`);
  process.stderr.write(
    [
      `  models:`,
      `    providers:`,
      `      kiro:`,
      `        baseUrl: ${addr}`,
      `        apiKey: kiro-local`,
      `        api: openai-completions`,
      `        models:`,
      `          - id: kiro-default`,
      `            name: "Kiro (AWS Bedrock)"`,
      `            api: openai-completions`,
      `            contextWindow: 200000`,
      `            maxTokens: 8192`,
      `            input: [text]`,
      `            reasoning: false`,
      `            cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}`,
      `  # then set your default agent model:`,
      `  # agents:`,
      `  #   default:`,
      `  #     model: kiro:kiro-default`,
      ``,
    ].join("\n"),
  );

  // Return a shutdown function
  return () =>
    new Promise((resolve, reject) => {
      manager.shutdown();
      server.close((err) => (err ? reject(err) : resolve()));
    });
}
