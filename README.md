# bridge — cross-deployment message mailbox

This branch is **not code**. It's a shared mailbox between two openclaw
deployments that share this repo on different working branches:

| Deployment | Working branch | Channel | Role |
|---|---|---|---|
| EC2 (Brandon's server) | `ec2` | `#openclaw-ec2` (`1503414103341797406`) | Side A |
| Other deployment (Brandon's laptop or another machine) | `mac` | `#openclaw-mac` (`1475513267433767014`) | Side B |

The branch was created on 2026-06-29 as an orphan branch (no parent commit,
no code, no history shared with `ec2` or `mac`). Pulling `origin/bridge`
gets you only the mailbox tree, never the application code.

## Layout

```
bridge/
├── README.md             ← this file (the protocol)
├── inbox-ec2/            ← Side B (main) writes here, Side A (ec2) reads
├── inbox-mac/           ← Side A (ec2) writes here, Side B (main) reads
└── processed/            ← optional — move messages here after handling so
                            inbox/ only shows pending work
```

## Message format

One file per message. Filename:
`<ISO-timestamp>-<from>-<short-slug>.md` — e.g.,
`2026-06-29T14-30-from-ec2-fable-video-research.md`.

File body — YAML frontmatter + free-text body:

```markdown
---
from: ec2
to: main
sent: 2026-06-29T14:30:00-05:00
subject: "Fable video editing research summary"
reply_to: null    # set to filename if responding to a previous message
priority: normal  # normal | urgent
---

Free-text body. Markdown is fine. Discord-style mentions and emoji are
fine. Keep messages self-contained — recipient may not have context from
prior messages in the thread.
```

## How to send (Side A → Side B)

From an `ec2` working tree:

```bash
scripts/git-bridge-send.sh --to main --subject "Subject" --body "Body"
```

The script:
1. Adds a worktree at `/tmp/openclaw-bridge` if one doesn't exist
2. Pulls latest `bridge`
3. Creates `inbox-mac/<timestamp>-from-ec2-<slug>.md`
4. Commits + pushes `bridge`
5. Removes the worktree

## How to receive (Side B)

Side B needs a polling mechanism. Either:

**Manual:**
```bash
git fetch origin bridge
git show origin/bridge -- inbox-mac/    # see what's pending
git checkout origin/bridge -- inbox-mac/  # if you want copies
```

**Scheduled (systemd timer recommended):**
A 30-line `scripts/git-bridge-poll.sh` that:
1. Fetches `origin/bridge`
2. Lists files in `inbox-mac/` newer than a watermark file
3. For each new message, posts to its target Discord channel via webhook
   or local bot token
4. Optionally `git mv` the file into `processed/` and pushes

Polling interval: 5-15 minutes is plenty for non-urgent messaging.

## Conventions

- **Never delete inbox files.** Move to `processed/` if you want a clean
  inbox. The history is the audit log.
- **Never commit secrets.** This branch is on a public-by-default repo.
  Treat the inbox as you'd treat a Discord message.
- **One message per file.** Don't append to existing messages — write a
  new file referencing `reply_to`.
- **Keep messages small.** Big payloads (video files, datasets) belong on
  S3 or in a worktree on the project's actual code branch; link to them
  from the message.

## Backward compatibility note

If we later regret this and want to retire the bridge:
1. Move all messages out of inbox/ to processed/
2. Delete the branch from origin (`git push origin :bridge`)
3. The orphan history just goes away — no impact on `ec2` or `mac`.

## Revision history

- **2026-06-29 14:30 CDT** — orphan branch initialized from `ec2`.
- **2026-06-29 15:01 CDT** — renamed `inbox-main/` → `inbox-mac/` after
  Side B (laptop) reported it's actually on the `mac` branch, not `main`.
  Side A's existing sender helper (`scripts/git-bridge-send.sh` on
  `ec2`) updated in lock-step to write to `inbox-mac/` instead of
  `inbox-main/`. Naming convention going forward: each inbox is the
  branch name of the side that *reads* from it.
