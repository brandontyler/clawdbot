/**
 * Proactive Discord alerts for ACP session context usage.
 *
 * Sends a message to the Discord channel when context crosses thresholds.
 * Uses the Discord bot token from openclaw config to POST via REST API.
 */

import { readFileSync } from "node:fs";
import { detectChannelId } from "./session-manager.js";

const THRESHOLDS = [60, 80, 90] as const;

const DISCORD_API = "https://discord.com/api/v10";

/** Track which thresholds have already fired per session to avoid spam. */
const firedAlerts = new Map<string, Set<number>>();

/** Resolve the Discord bot token from openclaw config. Cached after first read. */
let cachedToken: string | null = null;
function getDiscordToken(): string | null {
  if (cachedToken !== null) {
    return cachedToken;
  }
  try {
    const config = JSON.parse(readFileSync(`${process.env.HOME}/.openclaw/openclaw.json`, "utf8"));
    cachedToken = config?.channels?.discord?.token ?? null;
  } catch {
    cachedToken = null;
  }
  return cachedToken;
}

function alertMessage(pct: number): string {
  if (pct >= 90) {
    return `🚨 **Context window at ${Math.round(pct)}%** — approaching auto-reset threshold (95%). Send \`/new\` now to avoid losing your session mid-task.`;
  }
  if (pct >= 80) {
    return `⚠️ **Context window at ${Math.round(pct)}%** — getting full. Consider sending \`/new\` soon.`;
  }
  return `📊 **Context window at ${Math.round(pct)}%** — over halfway. Keep an eye on it.`;
}

/** Post a message to a Discord channel. Fire-and-forget. */
async function postToChannel(channelId: string, content: string): Promise<void> {
  const token = getDiscordToken();
  if (!token) {
    return;
  }

  try {
    await fetch(`${DISCORD_API}/channels/${channelId}/messages`, {
      method: "POST",
      headers: {
        Authorization: `Bot ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ content }),
    });
  } catch {
    // Best-effort — don't crash the proxy over an alert.
  }
}

/**
 * Check context usage and send a Discord alert if a threshold was crossed.
 * Call this from the session manager's onContextUsage callback.
 */
export function checkContextAlert(
  sessionKey: string,
  pct: number,
  log: (msg: string) => void,
): void {
  const channelId = detectChannelId(sessionKey);
  if (!channelId) {
    return;
  }

  let fired = firedAlerts.get(sessionKey);
  if (!fired) {
    fired = new Set();
    firedAlerts.set(sessionKey, fired);
  }

  for (const threshold of THRESHOLDS) {
    if (pct >= threshold && !fired.has(threshold)) {
      fired.add(threshold);
      log(
        `context alert: ${threshold}% threshold crossed (actual=${pct.toFixed(1)}%) channel=${channelId}`,
      );
      void postToChannel(channelId, alertMessage(pct));
    }
  }
}

/** Clear alert state for a session (call on session reset/destroy). */
export function clearContextAlerts(sessionKey: string): void {
  firedAlerts.delete(sessionKey);
}
