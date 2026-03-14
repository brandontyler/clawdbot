/**
 * /diag command handler — returns ACP session diagnostics inline in Discord.
 *
 * Kiro-only file (no upstream equivalent). Fetches live data from the
 * kiro-proxy /sessions endpoint and system memory, then formats a compact
 * Discord-friendly summary.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const PROXY_SESSIONS_URL = "http://127.0.0.1:18801/sessions";
const CORRUPTION_LOG = "/tmp/kiro-proxy-corruption.jsonl";
const ROUTES_PATH = resolve(process.cwd(), "kiro-proxy-routes.json");

type SessionInfo = {
  key: string;
  alive: boolean;
  pid: number | undefined;
  rssMb: number | undefined;
  contextPct: number;
  idleSecs: number;
  consecutiveErrors: number;
  sentMessages: number;
  isPrompting: boolean;
  promptingSecs: number | null;
};

type RouteEntry = { cwd: string };

function loadRoutes(): Record<string, RouteEntry> {
  try {
    return JSON.parse(readFileSync(ROUTES_PATH, "utf-8"));
  } catch {
    return {};
  }
}

function formatIdle(secs: number): string {
  if (secs < 60) {
    return `${secs}s`;
  }
  if (secs < 3600) {
    return `${Math.round(secs / 60)}m`;
  }
  const h = Math.floor(secs / 3600);
  const m = Math.round((secs % 3600) / 60);
  return m > 0 ? `${h}h${m}m` : `${h}h`;
}

function friendlyName(key: string, routes: Record<string, RouteEntry>): string {
  const match = key.match(/channel:(\d+)$/);
  if (!match) {
    return key.slice(0, 16);
  }
  const channelId = match[1];
  const route = routes[channelId];
  if (route?.cwd) {
    const base = route.cwd.split("/").pop() ?? channelId.slice(-4);
    return base;
  }
  return `ch:${channelId.slice(-4)}`;
}

function sessionLine(s: SessionInfo, routes: Record<string, RouteEntry>): string {
  const name = friendlyName(s.key, routes).padEnd(14);
  const ctx = `ctx=${s.contextPct}%`.padEnd(8);
  const idle = `idle=${formatIdle(s.idleSecs)}`.padEnd(12);
  const rss = s.rssMb != null ? `${s.rssMb}MB` : "?MB";
  const status = s.isPrompting
    ? `⏳ prompting${s.promptingSecs != null ? ` ${formatIdle(s.promptingSecs)}` : ""}`
    : "✅ idle";
  const errs = s.consecutiveErrors > 0 ? ` ⚠️${s.consecutiveErrors}err` : "";
  return `  ${name} ${ctx} ${idle} ${rss.padEnd(5)} ${status}${errs}`;
}

function readMemory(): string {
  try {
    const meminfo = readFileSync("/proc/meminfo", "utf-8");
    const get = (key: string) => {
      const m = meminfo.match(new RegExp(`${key}:\\s+(\\d+)`));
      return m ? parseInt(m[1], 10) : 0;
    };
    const totalKb = get("MemTotal");
    const availKb = get("MemAvailable");
    const usedKb = totalKb - availKb;
    const swapTotal = get("SwapTotal");
    const swapFree = get("SwapFree");
    const swapUsed = swapTotal - swapFree;
    const gb = (kb: number) => (kb / 1024 / 1024).toFixed(1);
    return `💾 Memory: ${gb(usedKb)}GB / ${gb(totalKb)}GB used (${gb(availKb)}GB avail), Swap: ${gb(swapUsed)}GB / ${gb(swapTotal)}GB`;
  } catch {
    return "💾 Memory: unavailable";
  }
}

function readRecentCorruption(maxLines = 3): string[] {
  try {
    const raw = readFileSync(CORRUPTION_LOG, "utf-8").trim();
    if (!raw) {
      return [];
    }
    const lines = raw.split("\n").slice(-maxLines);
    return lines.map((l) => {
      try {
        const e = JSON.parse(l);
        const ts = e.timestamp ? new Date(e.timestamp).toISOString().slice(0, 16) : "?";
        return `  ${ts} — ${e.type || "unknown"} (${e.session || "?"})`;
      } catch {
        return `  (unparseable entry)`;
      }
    });
  } catch {
    return [];
  }
}

export async function handleDiagCommand(
  params: { command: { commandBodyNormalized: string; isAuthorizedSender: boolean } },
  allowTextCommands: boolean,
): Promise<{ shouldContinue: boolean; reply?: { text: string } } | null> {
  if (!allowTextCommands && params.command.commandBodyNormalized !== "/diag") {
    return null;
  }
  if (!/^\/diag\b/i.test(params.command.commandBodyNormalized)) {
    return null;
  }
  if (!params.command.isAuthorizedSender) {
    return { shouldContinue: false };
  }

  let sessions: SessionInfo[] = [];
  let proxyOk = false;
  try {
    const res = await fetch(PROXY_SESSIONS_URL, { signal: AbortSignal.timeout(3000) });
    if (res.ok) {
      const data = (await res.json()) as { sessions?: SessionInfo[] };
      sessions = data.sessions ?? [];
      proxyOk = true;
    }
  } catch {
    // proxy unreachable
  }

  const routes = loadRoutes();
  const parts: string[] = ["📊 **System Diagnostics**", ""];
  parts.push(readMemory());
  parts.push("");

  if (!proxyOk) {
    parts.push("🔌 Kiro Proxy: ❌ unreachable (http://127.0.0.1:18801)");
  } else if (sessions.length === 0) {
    parts.push("🔌 ACP Sessions: none active");
  } else {
    const totalRss = sessions.reduce((sum, s) => sum + (s.rssMb ?? 0), 0);
    parts.push(`🔌 ACP Sessions (${sessions.length} active, ${totalRss}MB total RSS):`);
    sessions.sort((a, b) => {
      if (a.isPrompting !== b.isPrompting) {
        return a.isPrompting ? -1 : 1;
      }
      return b.contextPct - a.contextPct;
    });
    for (const s of sessions) {
      parts.push(sessionLine(s, routes));
    }
  }

  const corruption = readRecentCorruption();
  if (corruption.length > 0) {
    parts.push("");
    parts.push(`⚠️ Recent corruption events:`);
    parts.push(...corruption);
  }

  return {
    shouldContinue: false,
    reply: { text: parts.join("\n") },
  };
}
