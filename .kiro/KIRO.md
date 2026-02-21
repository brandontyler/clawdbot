# Kiro Agent Guide — OpenClaw Codebase

## Your Tools

You have these built-in tools — use them directly, don't shell out for things they cover:

| Tool                       | Use for                                                                                      |
| -------------------------- | -------------------------------------------------------------------------------------------- |
| `code`                     | Symbol search, AST pattern search/rewrite, file structure. **Prefer over fs_read for code.** |
| `grep`                     | Literal text/regex search across files.                                                      |
| `glob`                     | Find files by path pattern.                                                                  |
| `fs_read`                  | Read file contents, list directories, search within files, view images.                      |
| `fs_write`                 | Create, edit (str_replace), insert, or append to files.                                      |
| `execute_bash`             | Run shell commands. Don't use for grep/find — use the dedicated tools.                       |
| `use_aws`                  | AWS CLI calls.                                                                               |
| `web_search` / `web_fetch` | Look up external docs or current info.                                                       |
| `use_subagent`             | Delegate independent subtasks in parallel (up to 4).                                         |

## Context Management

- You're loaded with `AGENTS.md` (codebase rules) and this file. That's your baseline.
- Use `/context add <path>` to pull in additional docs on-demand when a task needs them.
- Use `/compact` if the conversation gets long — it summarizes history to free space.
- Prefer loading docs lazily over stuffing everything upfront.

## Upstream Fork Management

This is a fork of OpenClaw customized for `kiro-cli`. Read `UPSTREAM.md` before
touching any upstream files. Key rules:

- Kiro-specific logic goes in **separate files** (never weave into upstream code).
- Upstream file patches must be **surgical** (a few lines max).
- When you add or change a patch to an upstream file, **update `UPSTREAM.md`** —
  add the file to the "Upstream Files We Patch" table with what changed and why.
- When you add a new Kiro-only file, add it to the "Kiro-Only Files" table.
- After syncing upstream: check patched files listed in `UPSTREAM.md`, re-run
  `pnpm canvas:a2ui:bundle` for generated files, then `pnpm build && pnpm check`.

## On-Demand Doc Map

When working in a specific area, pull in the relevant doc:

| Area                       | Load                                                               |
| -------------------------- | ------------------------------------------------------------------ |
| Upstream fork / sync       | `UPSTREAM.md`                                                      |
| Gateway / WS protocol      | `docs/architecture.md`, `docs/gateway/protocol.md`                 |
| Agent loop / auto-reply    | `docs/concepts/agent-loop.md`                                      |
| Multi-agent routing        | `docs/concepts/multi-agent.md`                                     |
| Sessions / compaction      | `docs/concepts/session.md`                                         |
| System prompt construction | `docs/concepts/system-prompt.md`                                   |
| Context window / messages  | `docs/concepts/context.md`                                         |
| Skills system              | `docs/tools/skills.md`                                             |
| Tool execution / sandbox   | `docs/tools/exec.md`                                               |
| Testing                    | `docs/help/testing.md`                                             |
| Debugging                  | `docs/help/debugging.md`                                           |
| Environment / config       | `docs/help/environment.md`                                         |
| Gateway config reference   | `docs/gateway/configuration-reference.md` (large — use grep first) |
| Channel-specific work      | `docs/channels/<channel>.md`                                       |
| Provider-specific work     | `docs/providers/<provider>.md`                                     |
| Plugin / extension dev     | `docs/plugins/manifest.md`                                         |
| Memory / QMD               | `docs/concepts/memory.md`                                          |
| Cron / automation          | `docs/cron.md`                                                     |
| macOS app                  | `docs/mac/` (load specific file)                                   |
| OpenProse                  | `extensions/open-prose/skills/prose/SKILL.md`                      |

## Codebase Quick Ref

- **Runtime**: Node 22+, Bun for dev/scripts, pnpm for package management.
- **Source**: `src/` — CLI in `src/cli`, commands in `src/commands`, gateway in `src/gateway`, agents in `src/agents`.
- **Tests**: Colocated `*.test.ts`. Run with `pnpm test` or target specific: `bun test <file>`.
- **Build**: `pnpm build`. Type-check: `pnpm check`.
- **Extensions**: `extensions/*` — workspace packages with own `package.json`.
- **Config**: `src/config/` — TypeBox/ArkType schemas.
- **Channels**: Core in `src/telegram`, `src/discord`, `src/slack`, `src/signal`, `src/imessage`, `src/web`, `src/channels`. Extensions in `extensions/*`.

## Issue Tracking (Beads)

Uses **br** (beads-rust) — local-only SQLite task tracker. Prefix: `oc-`. `.beads/` is gitignored — beads stays local, never committed.

| Command                          | Purpose                                     |
| -------------------------------- | ------------------------------------------- |
| `br ready`                       | Find work with no blockers (START HERE)     |
| `br show <id>`                   | View details + blockers                     |
| `br update <id> --claim`         | Claim work (atomic: assignee + in_progress) |
| `br close <id> --reason "..."`   | Complete work                               |
| `br create "Title" -p 1 -t task` | Create task (P0-P3)                         |
| `br dep add <child> <parent>`    | Add blocker                                 |
| `br list`                        | List all open issues                        |

Issue IDs: `oc-xxx` (lowercase). Types: epic, feature, task, bug. Priorities: P0 (critical) → P3 (low).

**Do NOT commit `.beads/`.**

## Session Completion

Work is NOT complete until verified. Before ending:

1. File issues for remaining work (`br create`)
2. Close finished beads (`br close <id> --reason "..."`)
3. Update in-progress items
4. Run quality checks if code changed (`pnpm build && pnpm check`)

## Workflow Tips

- Before editing, use `code search_symbols` or `code get_document_symbols` to understand structure.
- For large files, use `grep` to find the relevant section before reading.
- When touching shared logic (routing, pairing, allowlists), remember all channels are affected — check `AGENTS.md` for the full list.
- Don't modify tests unless explicitly asked.
- Don't add tests unless explicitly asked.
- Keep PRs focused — one concern per change.
