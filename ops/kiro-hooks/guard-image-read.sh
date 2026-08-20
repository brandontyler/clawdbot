#!/usr/bin/env bash
# guard-image-read.sh — kiro-cli preToolUse guard for the `read` tool.
#
# WHY: LLM providers cap image inputs. In "many-image" requests (several images
# already in the conversation) the per-image dimension cap drops to ~2000px, and
# an over-cap image is NOT a one-time failure — it stays in session history and
# re-breaks EVERY subsequent turn (even text-only) with InternalServerError until
# /compact or a new session (verified 2026-08-20; matches Anthropic claude-code
# issues #46656/#34025). A preToolUse hook can't rewrite the input, but it CAN
# block the read and return guidance to the model (exit 2 → STDERR to the LLM).
#
# Wire via agent config: hooks.preToolUse[{ "matcher": "read", "command": "~/.kiro/hooks/guard-image-read.sh" }]
# Exit 0 = allow · Exit 2 = block (STDERR shown to the model).
set -euo pipefail
EVENT="$(cat)"
BLOCKED="$(EVENT="$EVENT" python3 - <<'PY'
import os, json, sys
try:
    ev = json.loads(os.environ["EVENT"])
except Exception:
    sys.exit(0)  # unparseable → don't block
ops = ((ev.get("tool_input") or {}).get("operations")) or []
img_ops = [o for o in ops if (o.get("mode") or "").lower() == "image"]
if not img_ops:
    sys.exit(0)  # not an image read → fast allow, no PIL import
MAXEDGE, MAXMP, MAXBYTES = 1568, 1_600_000, 1_200_000
try:
    from PIL import Image
except Exception:
    Image = None
offending = []
for o in img_ops:
    for p in (o.get("image_paths") or []):
        try:
            sz = os.path.getsize(p)
        except OSError:
            continue
        w = h = None
        if Image is not None:
            try:
                with Image.open(p) as im:
                    w, h = im.size
            except Exception:
                pass
        toobig = (w and max(w, h) > MAXEDGE) or (w and w * h > MAXMP) or (sz > MAXBYTES)
        if toobig:
            offending.append(f"{p} ({(str(w)+'x'+str(h)) if w else '?dims'}, {sz:,} bytes)")
if offending:
    print("\n".join(offending))
PY
)"
if [ -n "$BLOCKED" ]; then
  {
    echo "BLOCKED image read — too large to send to the model safely. This would return InternalServerError AND poison the session (every later turn re-sends it and fails until /compact)."
    echo "Offending:"
    echo "$BLOCKED"
    echo ""
    echo "FIX — downscale first, then read the .safe.jpg it prints:"
    echo "  bash ~/.kiro/skills/video-creation/scripts/model-safe-image.sh <path>"
    echo "Safe zone: <=1568px long edge, <=~1.15MP JPEG (<300KB ideal)."
  } >&2
  exit 2
fi
exit 0
