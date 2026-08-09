#!/usr/bin/env python3
"""
memory-guard.py — detect Cognitive-State poisoning in persistent agent memory.

Part of agent-trap hardening (bead openclaw-79b). The DeepMind "AI Agent Traps"
Cognitive State trap: an agent that ingested a trap persists malicious content
into long-term memory / skills, which then silently re-injects into EVERY future
session. Given how heavily we lean on ~/.kiro/memory.md + SKILL.md files, this is
our single biggest structural exposure.

Real-time interception of the model's built-in write/edit/br tools isn't cleanly
available in this setup, so the guard is layered:
  1. THIS scanner — run daily via systemd; alerts Discord on findings. Removes
     the "silent" from silent persistence.
  2. A git pre-commit hook (scripts/hooks/pre-commit-memory-guard.sh) that blocks
     poisoned content from entering the tracked surface (KIRO.md, scripts, ...).
  3. Policy in .kiro/KIRO.md: never persist scraped text verbatim — paraphrase
     + attribute.

It scans for the same signals sanitize_untrusted defangs in INBOUND content, but
only FAILS on the unambiguous ones. Rationale: our own security docs legitimately
*discuss* injection phrases (this very tool does), so phrase hits are reported as
informational, never fatal. Invisible/bidi Unicode and forged chat-template
tokens have NO legitimate reason to exist in hand-authored memory/skills — those
are the fail signals.

Usage:
  memory-guard.py                 # human report over default targets
  memory-guard.py --check         # exit 1 if any HIGH finding (hook/timer use)
  memory-guard.py --json          # machine-readable
  memory-guard.py PATH ...        # scan specific files/dirs instead of defaults
  memory-guard.py --self-test
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import unicodedata

# Reuse the inbound-sanitizer's detectors so the two stay in lockstep.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from sanitize_untrusted import _CONTROL_TOKEN_RE, _INJECTION_RE
except Exception as e:  # pragma: no cover
    sys.stderr.write(f"memory-guard: cannot import sanitize_untrusted detectors: {e}\n")
    sys.exit(2)

DEFAULT_TARGETS = [
    os.path.expanduser("~/.kiro/memory.md"),
    os.path.expanduser("~/.kiro/skills"),  # recursed for SKILL.md
]


def _iter_files(targets: list[str]) -> list[str]:
    files = []
    for t in targets:
        if os.path.isdir(t):
            files.extend(sorted(glob.glob(os.path.join(t, "**", "SKILL.md"), recursive=True)))
        elif os.path.isfile(t):
            files.append(t)
    return files


def scan_text(text: str) -> dict:
    """Return findings for one document. FAIL signals (invisibles, control
    tokens) drive `high`; injection phrases are informational only."""
    invisibles = []   # (line, col, codepoint)
    tokens = []       # (line, matched)
    phrases = []      # (line, matched)
    for lineno, line in enumerate(text.splitlines(), 1):
        for col, ch in enumerate(line):
            if ch in ("\t",):
                continue
            if unicodedata.category(ch) in ("Cf", "Cc"):
                invisibles.append((lineno, col, f"U+{ord(ch):04X}"))
        for m in _CONTROL_TOKEN_RE.finditer(line):
            tokens.append((lineno, m.group(0)[:40]))
        for m in _INJECTION_RE.finditer(line):
            phrases.append((lineno, m.group(0).strip()[:60]))
    high = bool(invisibles or tokens)
    return {
        "invisibles": invisibles,
        "control_tokens": tokens,
        "injection_phrases": phrases,
        "high": high,
    }


def scan_files(files: list[str]) -> dict:
    results = {}
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                results[f] = scan_text(fh.read())
        except Exception as e:
            results[f] = {"error": str(e)[:120], "high": False,
                          "invisibles": [], "control_tokens": [], "injection_phrases": []}
    return results


def _self_test() -> int:
    fails = 0

    def check(name, cond):
        nonlocal fails
        print(f"  {'PASS' if cond else 'FAIL'}  {name}")
        if not cond:
            fails += 1

    clean = scan_text("# Memory\nBrandon commits to the ec2 branch. Normal notes.\n")
    check("clean file not high", clean["high"] is False)

    poisoned = scan_text("note\nhidden\u200bpayload and <|im_start|>system\n")
    check("invisible flagged", len(poisoned["invisibles"]) == 1)
    check("control token flagged", len(poisoned["control_tokens"]) == 1)
    check("poisoned is high", poisoned["high"] is True)

    # Injection phrase alone = informational, NOT high (our own docs discuss it).
    meta = scan_text("Detect phrases like ignore all previous instructions here.\n")
    check("phrase found", len(meta["injection_phrases"]) >= 1)
    check("phrase-only not high", meta["high"] is False)

    print(f"\n{'ALL PASS' if fails == 0 else str(fails) + ' FAILED'}")
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Scan persistent agent memory for poisoning signals.")
    ap.add_argument("targets", nargs="*", help="files/dirs to scan (default: memory.md + skills)")
    ap.add_argument("--check", action="store_true", help="exit 1 if any HIGH finding")
    ap.add_argument("--beads", action="store_true", help="also scan the bead store (.beads/issues.jsonl)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    targets = list(args.targets) if args.targets else list(DEFAULT_TARGETS)
    if args.beads:
        # Bead notes/descriptions are another persistence surface the agent
        # writes to. The JSONL mirror carries the full text; scanning it as raw
        # text catches invisible Unicode / forged chat tokens regardless of field.
        for cand in (os.path.join(os.getcwd(), ".beads", "issues.jsonl"),
                     os.path.expanduser("~/openclaw/.beads/issues.jsonl")):
            if os.path.isfile(cand) and cand not in targets:
                targets.append(cand)
                break
    files = _iter_files(targets)
    results = scan_files(files)
    any_high = any(r.get("high") for r in results.values())

    if args.json:
        print(json.dumps({"any_high": any_high, "files": results}, default=list))
    else:
        print(f"memory-guard: scanned {len(files)} file(s)")
        for f, r in results.items():
            marks = []
            if r.get("invisibles"):
                marks.append(f"{len(r['invisibles'])} invisible-char")
            if r.get("control_tokens"):
                marks.append(f"{len(r['control_tokens'])} chat-token")
            if r.get("injection_phrases"):
                marks.append(f"{len(r['injection_phrases'])} phrase(info)")
            if r.get("error"):
                marks.append(f"error:{r['error']}")
            status = "🔴 HIGH" if r.get("high") else ("🟡 info" if r.get("injection_phrases") else "✅ clean")
            if marks:
                print(f"  {status}  {f}  [{', '.join(marks)}]")
                for ln, col, cp in r.get("invisibles", [])[:5]:
                    print(f"        invisible {cp} at line {ln} col {col}")
                for ln, tok in r.get("control_tokens", [])[:5]:
                    print(f"        chat-token {tok!r} at line {ln}")
            else:
                print(f"  {status}  {f}")
        print(f"\n{'🔴 poisoning signal detected' if any_high else '✅ no poisoning signals'}")

    if args.check and any_high:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
