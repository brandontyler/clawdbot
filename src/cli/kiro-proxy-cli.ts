/**
 * CLI registration for `openclaw kiro-proxy`.
 *
 * Starts a local OpenAI-compatible HTTP server that routes all inference
 * through the locally-installed `kiro` CLI via ACP (Agent Communication
 * Protocol).  This lets every OpenClaw channel (Discord, Slack, Telegram,
 * WhatsApp, web UI…) use Kiro as the AI backend without needing separate
 * Anthropic or OpenAI API keys.
 *
 * Quick start:
 *   1. Install:  curl -fsSL https://cli.kiro.dev/install | bash
 *   2. Start proxy:                    openclaw kiro-proxy
 *   3. Start gateway:                  openclaw gateway
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { Command } from "commander";
import { startKiroProxy } from "../kiro-proxy/index.js";
import type { ChannelRoute } from "../kiro-proxy/types.js";
import { defaultRuntime } from "../runtime.js";

export function registerKiroProxyCli(program: Command): void {
  program
    .command("kiro-proxy")
    .description("Start a local OpenAI-compatible proxy backed by kiro CLI (ACP)")
    .option("-p, --port <number>", "HTTP port to listen on", "18790")
    .option("--host <host>", "Host to bind to", "127.0.0.1")
    .option("--kiro-bin <path>", "Path to kiro executable", "kiro-cli")
    .option("--kiro-args <args...>", "Extra arguments to pass after 'acp'")
    .option("--cwd <dir>", "Working directory for kiro sessions", process.cwd())
    .option("--idle-secs <number>", "Seconds before an idle session is killed", "1800")
    .option("--routes <path>", "JSON file mapping Discord channel IDs to {cwd, kiroArgs?}")
    .option("-v, --verbose", "Enable verbose logging", false)
    .addHelpText(
      "after",
      `
Examples:
  $ openclaw kiro-proxy
  $ openclaw kiro-proxy --port 18790 --verbose
  $ openclaw kiro-proxy --kiro-bin /usr/local/bin/kiro --kiro-args --workspace /my/project

Prerequisites:
  1. Install Kiro CLI   curl -fsSL https://cli.kiro.dev/install | bash
  2. Authenticate       kiro-cli login  (browser OAuth, free AWS Builder ID)
  3. Start proxy        openclaw kiro-proxy
  4. Start gateway      openclaw gateway

Config (~/.openclaw/openclaw.json, JSON5):
  { models: { providers: { kiro: {
      baseUrl: "http://127.0.0.1:18790",
      apiKey: "kiro-local",
      api: "openai-completions",
      models: [{ id: "kiro-default", name: "Kiro (AWS Bedrock)", ... }]
  }}},
  agents: { defaults: { model: { primary: "kiro/kiro-default" } } },
  gateway: { mode: "local" } }
`,
    )
    .action(async (opts) => {
      const port = parseInt(opts.port as string, 10);
      if (isNaN(port) || port < 1 || port > 65535) {
        defaultRuntime.error("--port must be a valid port number (1–65535)");
        defaultRuntime.exit(1);
        return;
      }

      const idleSecs = parseInt(opts.idleSecs as string, 10);
      if (isNaN(idleSecs) || idleSecs < 10) {
        defaultRuntime.error("--idle-secs must be at least 10");
        defaultRuntime.exit(1);
        return;
      }

      let channelRoutes: Record<string, ChannelRoute> | undefined;
      if (opts.routes) {
        try {
          const routesPath = resolve(opts.routes as string);
          channelRoutes = JSON.parse(readFileSync(routesPath, "utf8")) as Record<
            string,
            ChannelRoute
          >;
        } catch (err) {
          defaultRuntime.error(`Failed to load --routes file: ${String(err)}`);
          defaultRuntime.exit(1);
          return;
        }
      }

      let shutdown: (() => Promise<void>) | null = null;

      const cleanup = async () => {
        if (shutdown) {
          try {
            await shutdown();
          } catch {
            // ignore
          }
        }
        defaultRuntime.exit(0);
      };

      process.once("SIGINT", () => void cleanup());
      process.once("SIGTERM", () => void cleanup());

      try {
        shutdown = await startKiroProxy({
          port,
          host: opts.host as string,
          kiroBin: opts.kiroBin as string,
          kiroArgs: (opts.kiroArgs as string[] | undefined) ?? [],
          cwd: opts.cwd as string,
          channelRoutes,
          sessionIdleSecs: idleSecs,
          verbose: Boolean(opts.verbose),
        });

        // Keep the process alive
        await new Promise<void>(() => {});
      } catch (err) {
        defaultRuntime.error(`kiro-proxy failed: ${String(err)}`);
        defaultRuntime.exit(1);
      }
    });
}
