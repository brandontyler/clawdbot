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
 * OpenClaw config (~/.openclaw/openclaw.json, JSON5):
 *   models: { providers: { kiro: {
 *     baseUrl: "http://127.0.0.1:18790",
 *     apiKey: "kiro-local",
 *     api: "openai-completions",
 *     models: [{ id: "kiro-default", name: "Kiro (AWS Bedrock)", ... }]
 *   }}}
 *   agents: { defaults: { model: { primary: "kiro/kiro-default" } } }
 */

import { createKiroProxyServer } from "./server.js";
import { SessionManager } from "./session-manager.js";
import type { KiroProxyOptions } from "./types.js";

export { KiroSession } from "./kiro-session.js";
export { SessionManager, detectChannelId } from "./session-manager.js";
export { createKiroProxyServer } from "./server.js";
export type { KiroProxyOptions, ChannelRoute } from "./types.js";

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

  const log = verbose ? (msg: string) => process.stderr.write(`[kiro-proxy] ${msg}\n`) : () => {};

  log(`starting (kiro=${kiroBin}, port=${port}, idle=${idleSecs}s)`);

  const manager = new SessionManager(
    { kiroBin, kiroArgs, cwd, verbose },
    { channelRoutes: opts.channelRoutes, idleSecs, log },
  );

  const server = createKiroProxyServer(manager, opts);

  await new Promise<void>((resolve, reject) => {
    server.listen(port, host, () => resolve());
    server.once("error", reject);
  });

  const addr = `http://${host}:${port}`;
  process.stderr.write(`[kiro-proxy] listening on ${addr}\n`);

  // Startup summary for diagnostics
  const routeCount = Object.keys(opts.channelRoutes ?? {}).length;
  const routeList = Object.entries(opts.channelRoutes ?? {})
    .map(([chId, r]) => `  ${chId} → ${r.cwd}`)
    .join("\n");
  process.stderr.write(
    `[kiro-proxy] config: kiro=${kiroBin} idle=${idleSecs}s routes=${routeCount}\n`,
  );
  if (routeList) {
    process.stderr.write(`[kiro-proxy] routes:\n${routeList}\n`);
  }

  process.stderr.write(`[kiro-proxy] add to ~/.openclaw/openclaw.json:\n`);
  process.stderr.write(
    [
      `  // models.providers.kiro`,
      `  {`,
      `    models: { providers: { kiro: {`,
      `      baseUrl: "${addr}",`,
      `      apiKey: "kiro-local",`,
      `      api: "openai-completions",`,
      `      models: [{`,
      `        id: "kiro-default",`,
      `        name: "Kiro (AWS Bedrock)",`,
      `        reasoning: false,`,
      `        input: ["text"],`,
      `        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },`,
      `        contextWindow: 1000000,`,
      `        maxTokens: 16384,`,
      `      }],`,
      `    }}},`,
      `    agents: { defaults: { model: { primary: "kiro/kiro-default" } } },`,
      `    gateway: { mode: "local" },`,
      `  }`,
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
