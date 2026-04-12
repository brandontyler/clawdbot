/**
 * Proactive Discord alerts for ACP session context usage.
 *
 * Sends a message to the Discord channel when context crosses thresholds.
 */

import { postMessage } from "./discord-api.js";
import { detectChannelId } from "./session-manager.js";

const THRESHOLDS = [60, 80, 90] as const;

/** Track which thresholds have already fired per session to avoid spam. */
const firedAlerts = new Map<string, Set<number>>();

function alertMessage(pct: number): string {
  if (pct >= 90) {
    return `🚨 **Context window at ${Math.round(pct)}%** — approaching auto-reset threshold (95%). Send \`/new\` now to avoid losing your session mid-task.`;
  }
  if (pct >= 80) {
    return `⚠️ **Context window at ${Math.round(pct)}%** — getting full. Consider sending \`/new\` soon.`;
  }
  return `📊 **Context window at ${Math.round(pct)}%** — over halfway. Keep an eye on it.`;
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
      void postMessage(channelId, alertMessage(pct));
    }
  }
}

/** Clear alert state for a session (call on session reset/destroy). */
export function clearContextAlerts(sessionKey: string): void {
  firedAlerts.delete(sessionKey);
}
