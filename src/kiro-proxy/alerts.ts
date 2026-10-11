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
    return `🚨 **Context window at ${Math.round(pct)}%** — direct same-session compaction is being forced as soon as this turn ends. \`/kcompact\` retries the same safe path; \`/new\` is only a last resort.`;
  }
  if (pct >= 80) {
    return `⚠️ **Context window at ${Math.round(pct)}%** — the proxy will compact this same ACP session immediately after the current response.`;
  }
  return `🧹 **Context window at ${Math.round(pct)}%** — automatic same-session compaction is queued for immediately after this response.`;
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

  const threshold = THRESHOLDS.toReversed().find((candidate) => pct >= candidate);
  if (threshold !== undefined && !fired.has(threshold)) {
    for (const crossed of THRESHOLDS) {
      if (crossed <= threshold) {
        fired.add(crossed);
      }
    }
    log(
      `context alert: ${threshold}% threshold crossed (actual=${pct.toFixed(1)}%) channel=${channelId}`,
    );
    void postMessage(channelId, alertMessage(pct));
  }
}

/** Clear alert state for a session (call on session reset/destroy). */
export function clearContextAlerts(sessionKey: string): void {
  firedAlerts.delete(sessionKey);
}
