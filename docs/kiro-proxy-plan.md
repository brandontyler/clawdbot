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
  kiro-proxy HTTP Server   ←→   Session Pool
        ↓                           ↓
  ACP Client (JSON-RPC/stdio)   kiro-cli process
        ↓                       (one per conversation_id)
     kiro CLI
        ↓
   AWS Bedrock (Claude / Nova)
```

## Key Design Decisions

1. **One kiro-cli process per OpenClaw session** — Kiro maintains conversation history internally; mapping OpenClaw `sessionId` → Kiro process gives us persistent session memory for free.
2. **OpenAI-compatible HTTP interface** — pi-ai already knows how to call `openai-completions` API style; we speak that dialect so zero changes needed to OpenClaw internals.
3. **Server-Sent Events (SSE) streaming** — pi-ai expects chunked `text/event-stream` responses; we stream Kiro ACP deltas as `data: {"choices":[{"delta":{"content":"..."}}]}` lines.
4. **Graceful process lifecycle** — idle sessions time out after N minutes; processes restart on crash; SIGTERM handled cleanly.
5. **Authentication** — user authenticates Kiro CLI manually (`kiro auth login`); the proxy inherits the current user's Kiro credentials automatically.

## Files to Create

| File | Purpose |
|------|---------|
| `src/kiro-proxy/acp-client.ts` | JSON-RPC 2.0 client over stdio to a single kiro process |
| `src/kiro-proxy/session-pool.ts` | Maps sessionId → AcpClient; handles lifecycle, timeouts, restart |
| `src/kiro-proxy/stream-transformer.ts` | Converts Kiro ACP event stream → OpenAI SSE format |
| `src/kiro-proxy/server.ts` | HTTP server: `/v1/chat/completions`, `/v1/models`, health |
| `src/kiro-proxy/index.ts` | Entry point, starts server + pool, handles signals |
| `scripts/kiro-proxy.mjs` | Runner (mirrors `scripts/gateway.mjs` pattern) |

## OpenClaw Configuration (~/.openclaw/config.yaml)

```yaml
models:
  providers:
    kiro:
      baseUrl: http://127.0.0.1:18790
      auth: api-key
      apiKey: kiro-local          # any non-empty string; auth is handled by kiro CLI itself
      api: openai-completions
      models:
        - id: kiro-default
          name: Kiro (AWS Bedrock)
          api: openai-completions
          contextWindow: 200000
          maxTokens: 8192
          input: [text, image]
          reasoning: false
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }

agents:
  default:
    model: kiro:kiro-default
```

## ACP Protocol Notes

Kiro CLI exposes its agent via the Agent Communication Protocol (ACP), a JSON-RPC 2.0 dialect over stdio:

```jsonc
// Request (stdin)
{ "jsonrpc": "2.0", "id": 1, "method": "agent/chat", "params": { "messages": [...], "stream": true } }

// Response stream (stdout) — one JSON object per line
{ "jsonrpc": "2.0", "id": 1, "result": { "type": "delta", "content": "Hello" } }
{ "jsonrpc": "2.0", "id": 1, "result": { "type": "done", "usage": { "inputTokens": 42, "outputTokens": 18 } } }
```

The proxy translates this into standard OpenAI SSE:
```
data: {"id":"kiro-1","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"}}]}

data: [DONE]
```

## Session Memory

Kiro CLI maintains the full conversation history internally per process. By keeping one process alive per `sessionId`, every subsequent message is automatically in context — no need to resend history from OpenClaw's side.

## Manual Steps (User)

1. Install Kiro CLI: `curl -fsSL https://kiro.dev/install.sh | sh` (or equivalent)
2. Authenticate: `kiro auth login`
3. Start the proxy: `pnpm kiro-proxy` (or `node scripts/kiro-proxy.mjs`)
4. Start OpenClaw gateway: `pnpm gateway`
5. Done — all channels now route through Kiro

## Future Work

- Auto-start kiro-proxy from within gateway startup
- Model selection passthrough (pick Claude vs Nova via config)
- Kiro tool use / file editing bridging (Level 2 — Kiro as full agent)
- Health check endpoint surfaced in `openclaw doctor`
