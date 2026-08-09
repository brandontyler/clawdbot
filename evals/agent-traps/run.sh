#!/usr/bin/env bash
# Adversarial eval suite for agent-trap defenses (bead openclaw-79b).
# Exercises sanitize_untrusted + memory-guard against known trap inputs per
# trap type, and asserts benign content is not flagged. Exit non-zero on fail.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec python3 run.py "$@"
