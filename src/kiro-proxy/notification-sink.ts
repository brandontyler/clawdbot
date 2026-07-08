/**
 * NotificationSink — abstraction for sending messages to a channel.
 *
 * Decouples the proxy core from Discord-specific REST calls so the same
 * session management, alerts, and progress reporting can work with any
 * messaging backend (Discord, webhooks, stdout, OpenClaw sessions_send, etc.).
 */

export type NotificationSink = {
  /** Post a new message. Returns a message ID on success, null on failure. */
  postMessage(channelId: string, content: string): Promise<string | null>;
  /** Edit an existing message by ID. */
  editMessage(channelId: string, messageId: string, content: string): Promise<void>;
  /** Delete a message by ID (best-effort). */
  deleteMessage(channelId: string, messageId: string): Promise<void>;
};
