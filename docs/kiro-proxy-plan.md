# Kiro Proxy — Integration Plan

## Goal

Run **Kiro CLI** as the LLM/agent backend powering all of OpenClaw. No Bedrock API keys, no Claude subscriptions — just Kiro CLI authenticated by the user. OpenClaw handles all channels (Discord, Slack, Telegram, WhatsApp, Web), session routing, skills, and tool invocation; Kiro handles all AI inference.

## Architecture

```
Discord / Slack / Telegram / Web
        ↓
  OpenClaw Gateway (ws://127.0.0.1:18789)
        ↓
  pi-ai ModelRegistry → POST http://127.0.0.1:18790/v1/chat/completions
        ↓
  kiro-proxy HTTP Server   ←→   SessionManager
        ↓                           ↓
  ACP ClientSideConnection      kiro-cli process
  (NDJSON over stdio)           (one per conversation)
        ↓
     kiro-cli acp
        ↓
   AWS Bedrock (Claude / Nova)
```

## Key Design Decisions

1. **One kiro-cli process per OpenClaw session** — Kiro maintains conversation history internally; mapping OpenClaw session fingerprint → Kiro process gives us persistent session memory for free.
2. **OpenAI-compatible HTTP interface** — pi-ai already knows how to call `openai-completions` API style; we speak that dialect so zero changes needed to OpenClaw internals.
3. **Server-Sent Events (SSE) streaming** — pi-ai expects chunked `text/event-stream` responses; we stream Kiro ACP deltas as `data: {"choices":[{"delta":{"content":"..."}}]}` lines.
4. **Graceful process lifecycle** — idle sessions time out after N minutes (default 30); processes restart on crash; SIGTERM handled cleanly.
5. **Authentication** — user authenticates Kiro CLI manually (`kiro-cli auth login`); the proxy inherits the current user's Kiro credentials automatically.

## Implemented Files

| File | Purpose |
|------|---------|
| `src/kiro-proxy/types.ts` | OpenAI wire types + `KiroProxyOptions` |
| `src/kiro-proxy/kiro-session.ts` | Single kiro-cli ACP session wrapper |
| `src/kiro-proxy/session-manager.ts` | Session pool, fingerprinting, idle GC |
| `src/kiro-proxy/server.ts` | OpenAI-compatible HTTP server |
| `src/kiro-proxy/index.ts` | `startKiroProxy()` entry + exports |
| `src/cli/kiro-proxy-cli.ts` | `openclaw kiro-proxy` CLI command |

## OpenClaw Configuration (~/.openclaw/config.yaml)

The proxy prints this exact snippet to stderr on startup:

```yaml
models:
  providers:
    kiro:
      baseUrl: http://127.0.0.1:18790
      apiKey: kiro-local          # any non-empty string; auth is kiro-cli's job
      api: openai-completions
      models:
        - id: kiro-default
          name: "Kiro (AWS Bedrock)"
          api: openai-completions
          contextWindow: 200000
          maxTokens: 8192
          input: [text]
          reasoning: false
          cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}

agents:
  default:
    model: kiro:kiro-default
```

## ACP Protocol (Confirmed)

Kiro CLI implements the [Agent Client Protocol](https://agentclientprotocol.com) from
`@agentclientprotocol/sdk` (author: Zed Industries, Apache-2.0).

- **Binary**: `kiro-cli` (not `kiro`) — typically `~/.local/bin/kiro-cli`
- **Subcommand**: `kiro-cli acp`
- **Transport**: JSON-RPC 2.0 over newline-delimited JSON (**NDJSON**) on stdio

The proxy's ACP lifecycle per session:

```
spawn("kiro-cli", ["acp"])
  ↓
ClientSideConnection.initialize({ protocolVersion: 1 })
  ↓
ClientSideConnection.newSession({ cwd, mcpServers: [] }) → { sessionId }
  ↓
ClientSideConnection.prompt({ sessionId, prompt: [{ type: "text", text }] })
  → agent sends session/update notifications (agent_message_chunk events)
  → proxy forwards each chunk as OpenAI SSE
  → prompt() resolves with { stopReason: "end_turn" | "cancelled" | ... }
```

Key ACP types used:

```typescript
// Streaming chunks arrive via sessionUpdate callback (before prompt() resolves):
SessionUpdate = ContentChunk & { sessionUpdate: "agent_message_chunk" }
ContentChunk  = { content: ContentBlock }
ContentBlock  = { type: "text", text: string }  // (also image, audio, resource_link, etc.)
```

## Session Identity & Memory

pi-ai sends the **full conversation** in every OpenAI request. The proxy:

1. Extracts a **fingerprint**: SHA-256 of the first `system` + first `user` message (stable across all turns).
2. Looks up an existing `KiroSession` for that fingerprint, or creates a new one.
3. Computes the **delta** — only the new messages since `sentMessageCount` — and sends them to Kiro.
4. Kiro maintains its own context window internally → full session memory.

Callers can also pass an explicit session key via:
- `X-Kiro-Session-Id` HTTP header
- OpenAI `user` field in the request body

## Manual Steps (User)

```bash
# 1. Install Kiro CLI
curl -fsSL https://cli.kiro.dev/install | bash
# (also: brew install --cask kiro-cli  or  .deb at https://desktop-release.q.us-east-1.amazonaws.com/latest/kiro-cli.deb)

# 2. Authenticate (opens browser OAuth — requires free AWS Builder ID)
kiro-cli login

# 3. Start the proxy (terminal 1)
openclaw kiro-proxy
#   Or with full path if not on $PATH:
openclaw kiro-proxy --kiro-bin ~/.local/bin/kiro-cli

# 4. Add the printed config snippet to ~/.openclaw/config.yaml

# 5. Start the gateway (terminal 2)
openclaw gateway
```

All channels (Discord, Slack, Telegram, WhatsApp, web UI) now route through Kiro.

## Available CLI Options

```
openclaw kiro-proxy [options]

  -p, --port <number>       HTTP port to listen on (default: 18790)
  --host <host>             Host to bind to (default: 127.0.0.1)
  --kiro-bin <path>         Path to kiro-cli executable (default: kiro-cli)
  --kiro-args <args...>     Extra arguments after 'acp'
  --cwd <dir>               Working directory for kiro sessions
  --idle-secs <number>      Kill idle sessions after N seconds (default: 1800)
  -v, --verbose             Verbose logging to stderr
```

## Future Work

- Auto-start kiro-proxy from within gateway startup
- Model selection passthrough (pick Claude vs Nova via `--kiro-args --model`)
- Kiro tool use / file editing bridging (Level 2 — Kiro as full agent)
- Health check endpoint surfaced in `openclaw doctor`
- `openclaw kiro-proxy install` as a launchd/systemd service
