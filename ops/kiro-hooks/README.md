# kiro-hooks — agent safety guards

`guard-image-read.sh` is a kiro-cli **preToolUse** hook (matcher `read`) that
blocks oversized image reads before they poison a session. LLM providers cap
image inputs; an over-cap image stays in history and re-breaks later turns until
`/compact`. The hook exits 2 and directs the model to create a model-safe JPEG.

`guard-openclaw-dist.sh` is a **preToolUse** hook (matcher `shell`) that blocks
build/clean/run wrappers capable of wiping the live `~/openclaw/dist` tree. It
keeps normal tests, formatters, linters, and staged deploys available while
preventing another partial-build outage. Agent configs reference the deployed
copies under `~/.kiro/hooks`; this directory is their versioned source.

## Install on a box

```bash
mkdir -p ~/.kiro/hooks
cp ops/kiro-hooks/*.sh ~/.kiro/hooks/ && chmod +x ~/.kiro/hooks/*.sh
bash ~/.kiro/hooks/deploy-image-guard.sh
bash ~/.kiro/hooks/deploy-dist-guard.sh
```

New sessions pick up the hook on spawn (agent config is read at session start).
