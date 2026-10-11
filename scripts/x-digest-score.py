#!/usr/bin/env python3
"""Invoke Kiro for x-digest scoring with retries and durable diagnostics."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def extract_scores(raw: str) -> list[dict[str, Any]] | None:
    """Find the first non-empty JSON array whose objects all contain score."""
    clean = ANSI_RE.sub("", raw)
    decoder = json.JSONDecoder()
    cursor = 0
    while True:
        cursor = clean.find("[", cursor)
        if cursor < 0:
            return None
        try:
            value, _end = decoder.raw_decode(clean, cursor)
        except ValueError:
            cursor += 1
            continue
        if (
            isinstance(value, list)
            and value
            and all(isinstance(item, dict) and "score" in item for item in value)
        ):
            return value
        cursor += 1


def validate_scores(scores: list[dict[str, Any]] | None, expected_count: int) -> str | None:
    if scores is None:
        return "no score array found"
    if len(scores) != expected_count:
        return f"score count {len(scores)} != expected {expected_count}"
    for position, item in enumerate(scores, start=1):
        if type(item.get("index")) is not int or item["index"] != position:
            return f"score object {position} has invalid index {item.get('index')!r}"
        if type(item.get("score")) is not int or not 1 <= item["score"] <= 10:
            return f"score object {position} has invalid score {item.get('score')!r}"
        if not isinstance(item.get("topic"), str) or not item["topic"]:
            return f"score object {position} has invalid topic"
        if not isinstance(item.get("lang"), str) or len(item["lang"]) != 2:
            return f"score object {position} has invalid lang"
    return None


def clean_output(raw: str) -> str:
    return ANSI_RE.sub("", raw).replace("\r", "")


def private_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)


def private_write_json(path: Path, data: dict[str, Any]) -> None:
    private_write(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def prune_old_diagnostics(root: Path, retention_days: int) -> None:
    cutoff = time.time() - retention_days * 86_400
    for child in root.iterdir():
        if not child.is_dir():
            continue
        try:
            if child.stat().st_mtime < cutoff:
                shutil.rmtree(child)
        except OSError:
            continue


def cli_version(binary: str) -> str:
    try:
        result = subprocess.run(
            [binary, "--version"], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    value = (result.stdout or result.stderr).strip().splitlines()
    return value[0] if value else "unknown"


def invoke(binary: str, prompt: str, timeout_seconds: int) -> tuple[int, bool, str, int]:
    started = time.monotonic()
    try:
        process = subprocess.Popen(
            [binary, "chat", "--model", "claude-opus-4.8", "--no-interactive", "--wrap", "never", prompt],
            cwd=Path.home(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=os.environ.copy(),
            start_new_session=True,
        )
    except OSError as exc:
        duration_ms = int((time.monotonic() - started) * 1000)
        return 127, False, f"failed to execute {binary}: {exc}", duration_ms

    try:
        output, _ = process.communicate(timeout=timeout_seconds)
        returncode = process.returncode
        timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            output = ""
        # Always kill the original process group after the grace period. A
        # TERM-resistant descendant can close stdout, letting communicate()
        # return even though the descendant is still running.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            final_output, _ = process.communicate()
            output = output or final_output
        returncode = 124
    duration_ms = int((time.monotonic() - started) * 1000)
    return returncode, timed_out, output or "", duration_ms


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Retry and diagnose x-digest Kiro scoring")
    parser.add_argument("--prompt-file", type=Path, required=True)
    parser.add_argument("--input-file", type=Path, required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    parser.add_argument("--diagnostics-dir", type=Path, required=True)
    parser.add_argument("--kiro-bin", default="kiro-cli")
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--retry-delay", type=float, default=5.0)
    parser.add_argument("--retention-days", type=int, default=30)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.expected_count <= 0:
        print("x-digest-score: expected count must be positive", file=sys.stderr)
        return 2
    if args.attempts < 1 or args.attempts > 5:
        print("x-digest-score: attempts must be between 1 and 5", file=sys.stderr)
        return 2
    if args.timeout < 1:
        print("x-digest-score: timeout must be positive", file=sys.stderr)
        return 2
    try:
        prompt = args.prompt_file.read_text(encoding="utf-8")
        scoring_input = args.input_file.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"x-digest-score: could not read scoring files: {exc}", file=sys.stderr)
        return 2

    diagnostics_root = args.diagnostics_dir.expanduser().resolve()
    diagnostics_root.mkdir(parents=True, exist_ok=True)
    diagnostics_root.chmod(0o700)
    prune_old_diagnostics(diagnostics_root, args.retention_days)
    pointer = diagnostics_root / "latest-failure.txt"
    pointer.unlink(missing_ok=True)

    stamp = datetime.now().astimezone().strftime("%Y-%m-%dT%H%M%S%z")
    run_dir = diagnostics_root / f"score-{stamp}-{os.getpid()}"
    version = cli_version(args.kiro_bin)
    had_failure = False

    for attempt in range(1, args.attempts + 1):
        returncode, timed_out, raw, duration_ms = invoke(
            args.kiro_bin, prompt, args.timeout
        )
        scores = extract_scores(raw)
        parsed_count = len(scores) if scores is not None else 0
        validation_error = validate_scores(scores, args.expected_count)
        valid = returncode == 0 and validation_error is None
        if valid:
            if had_failure:
                private_write_json(
                    run_dir / "recovery.json",
                    {
                        "status": "recovered",
                        "recovered_attempt": attempt,
                        "expected_count": args.expected_count,
                        "parsed_count": parsed_count,
                        "kiro_version": version,
                    },
                )
                print(
                    f"x-digest-score: recovered on attempt {attempt}; diagnostics: {run_dir}",
                    file=sys.stderr,
                )
            print(json.dumps(scores, ensure_ascii=False))
            return 0

        had_failure = True
        run_dir.mkdir(parents=True, exist_ok=True)
        run_dir.chmod(0o700)
        input_copy = run_dir / "sanitized-scoring-input.txt"
        if not input_copy.exists():
            private_write(input_copy, scoring_input)
        private_write(run_dir / f"attempt-{attempt}.log", clean_output(raw))
        private_write_json(
            run_dir / f"attempt-{attempt}.json",
            {
                "status": "failed",
                "attempt": attempt,
                "attempts": args.attempts,
                "returncode": returncode,
                "timed_out": timed_out,
                "duration_ms": duration_ms,
                "raw_bytes": len(raw.encode("utf-8", errors="replace")),
                "expected_count": args.expected_count,
                "parsed_count": parsed_count,
                "validation_error": validation_error,
                "kiro_version": version,
                "timestamp": datetime.now().astimezone().isoformat(),
            },
        )
        private_write(pointer, str(run_dir) + "\n")
        retrying = attempt < args.attempts
        print(
            "x-digest-score: "
            f"attempt {attempt}/{args.attempts} failed "
            f"(rc={returncode}, timeout={str(timed_out).lower()}, "
            f"scores={parsed_count}/{args.expected_count}, validation={validation_error!r}, "
            f"raw_bytes={len(raw.encode('utf-8', errors='replace'))}); "
            f"diagnostics: {run_dir}"
            + (f"; retrying in {args.retry_delay:g}s" if retrying else ""),
            file=sys.stderr,
        )
        if retrying:
            time.sleep(args.retry_delay)

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
