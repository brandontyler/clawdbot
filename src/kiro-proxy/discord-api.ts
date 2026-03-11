/**
 * Shared Discord REST API helpers for the kiro-proxy.
 *
 * Used by alerts.ts (context threshold warnings) and progress.ts
 * (incremental tool progress updates during long-running ACP sessions).
 */

import { readFileSync } from "node:fs";

const DISCORD_API = "https://discord.com/api/v10";

let cachedToken: string | null = null;

export function getDiscordToken(): string | null {
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

function headers(token: string): Record<string, string> {
  return { Authorization: `Bot ${token}`, "Content-Type": "application/json" };
}

const MAX_RETRY_WAIT_MS = 5_000;

/**
 * Fetch wrapper that retries once on Discord 429 (rate limit) responses.
 * Waits for the `Retry-After` header duration, capped at 5 seconds.
 */
async function discordFetch(url: string, init: RequestInit): Promise<Response> {
  const res = await fetch(url, init);
  if (res.status !== 429) {
    return res;
  }
  const retryAfter = parseFloat(res.headers.get("retry-after") ?? "1");
  const waitMs = Math.min(
    Number.isFinite(retryAfter) ? retryAfter * 1000 : 1000,
    MAX_RETRY_WAIT_MS,
  );
  await new Promise((r) => setTimeout(r, waitMs));
  return fetch(url, init);
}

/** Post a message. Returns the message ID on success, null on failure. */
export async function postMessage(channelId: string, content: string): Promise<string | null> {
  const token = getDiscordToken();
  if (!token) {
    return null;
  }
  try {
    const res = await discordFetch(`${DISCORD_API}/channels/${channelId}/messages`, {
      method: "POST",
      headers: headers(token),
      body: JSON.stringify({ content }),
    });
    if (!res.ok) {
      return null;
    }
    const body = (await res.json()) as { id?: string };
    return body.id ?? null;
  } catch {
    return null;
  }
}

/** Edit an existing message. */
export async function editMessage(
  channelId: string,
  messageId: string,
  content: string,
): Promise<void> {
  const token = getDiscordToken();
  if (!token) {
    return;
  }
  try {
    await discordFetch(`${DISCORD_API}/channels/${channelId}/messages/${messageId}`, {
      method: "PATCH",
      headers: headers(token),
      body: JSON.stringify({ content }),
    });
  } catch {
    // Best-effort.
  }
}

/** Delete a message. */
export async function deleteMessage(channelId: string, messageId: string): Promise<void> {
  const token = getDiscordToken();
  if (!token) {
    return;
  }
  try {
    await discordFetch(`${DISCORD_API}/channels/${channelId}/messages/${messageId}`, {
      method: "DELETE",
      headers: headers(token),
    });
  } catch {
    // Best-effort.
  }
}
