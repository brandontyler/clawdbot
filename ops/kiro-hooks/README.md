# kiro-hooks — image-input safety guard

`guard-image-read.sh` is a kiro-cli **preToolUse** hook (matcher `read`) that
BLOCKS oversized image reads before they poison a session. LLM providers cap
image inputs (~2000px/image in many-image requests); an over-cap image stays in
history and re-breaks every later turn with InternalServerError until `/compact`
(verified 2026-08-20; matches Anthropic claude-code #46656/#34025). The hook
exits 2 and tells the model to downscale first via
`~/.kiro/skills/video-creation/scripts/model-safe-image.sh` (<=1568px JPEG).

## Install on a box

```bash
mkdir -p ~/.kiro/hooks
cp ops/kiro-hooks/*.sh ~/.kiro/hooks/ && chmod +x ~/.kiro/hooks/*.sh
bash ~/.kiro/hooks/deploy-image-guard.sh   # wires the hook into every agent config (idempotent)
```

New sessions pick up the hook on spawn (agent config is read at session start).
