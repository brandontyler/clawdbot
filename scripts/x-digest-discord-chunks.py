#!/usr/bin/env python3
"""Split an x-digest Markdown file into Discord-safe message chunks."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

TWEET_URL_RE = re.compile(r"https://x\.com/[^/\s]+/status/(\d+)")


def split_oversized_block(block: str, limit: int) -> list[str]:
    if len(block) <= limit:
        return [block]
    pieces: list[str] = []
    current = ""
    for line in block.splitlines(keepends=True):
        while len(line) > limit:
            if current:
                pieces.append(current)
                current = ""
            pieces.append(line[:limit])
            line = line[limit:]
        if current and len(current) + len(line) > limit:
            pieces.append(current)
            current = ""
        current += line
    if current:
        pieces.append(current)
    return pieces


def tweet_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    current = ""
    for line in text.splitlines(keepends=True):
        if line.startswith("**@") and current:
            blocks.append(current)
            current = ""
        current += line
    if current:
        blocks.append(current)
    return blocks


def make_chunks(text: str, limit: int) -> list[str]:
    chunks: list[str] = []
    current = ""
    for block in tweet_blocks(text):
        for piece in split_oversized_block(block, limit):
            if current and len(current) + len(piece) > limit:
                chunks.append(current.rstrip())
                current = ""
            current += piece
    if current:
        chunks.append(current.rstrip())
    if not chunks:
        raise ValueError("digest is empty")
    if any(len(chunk) > limit for chunk in chunks):
        raise ValueError("internal error: oversized Discord chunk")
    return chunks


def tweet_ids(text: str) -> list[str]:
    return list(dict.fromkeys(TWEET_URL_RE.findall(text)))


def merge_checkpoint(checkpoint: Path, ids_path: Path) -> list[str]:
    values: set[str] = set()
    for path in (checkpoint, ids_path):
        if path == checkpoint and not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.isdigit():
                raise ValueError(f"invalid tweet id in {path}")
            values.add(line)
    ordered = sorted(values, key=int)
    checkpoint.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    checkpoint.parent.chmod(0o700)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=checkpoint.parent,
            prefix=".checkpoint.",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write("".join(f"{tweet_id}\n" for tweet_id in ordered))
        temporary.chmod(0o600)
        os.replace(temporary, checkpoint)
        checkpoint.chmod(0o600)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return ordered


def main() -> int:
    parser = argparse.ArgumentParser(description="Create Discord-safe x-digest chunks")
    parser.add_argument("digest", type=Path, nargs="?")
    parser.add_argument("output_dir", type=Path, nargs="?")
    parser.add_argument("--limit", type=int, default=1900)
    parser.add_argument(
        "--checkpoint",
        nargs=2,
        type=Path,
        metavar=("CHECKPOINT", "IDS_FILE"),
        help="atomically merge a sent chunk's IDs into a persistent checkpoint",
    )
    args = parser.parse_args()
    if args.checkpoint:
        try:
            merged = merge_checkpoint(*args.checkpoint)
        except (OSError, ValueError) as exc:
            print(f"x-digest-discord-chunks: {exc}", file=sys.stderr)
            return 1
        print(len(merged))
        return 0
    if args.digest is None or args.output_dir is None:
        parser.error("digest and output_dir are required unless --checkpoint is used")
    if args.limit < 100 or args.limit > 2000:
        print("x-digest-discord-chunks: limit must be between 100 and 2000", file=sys.stderr)
        return 2
    try:
        text = args.digest.read_text(encoding="utf-8")
        chunks = make_chunks(text, args.limit)
        if args.output_dir.exists():
            shutil.rmtree(args.output_dir)
        args.output_dir.mkdir(parents=True, mode=0o700)
        args.output_dir.chmod(0o700)
        for index, chunk in enumerate(chunks, start=1):
            path = args.output_dir / f"{index:03d}.txt"
            path.write_text(chunk, encoding="utf-8")
            path.chmod(0o600)
            ids_path = args.output_dir / f"{index:03d}.ids"
            ids = tweet_ids(chunk)
            ids_path.write_text("".join(f"{tweet_id}\n" for tweet_id in ids), encoding="utf-8")
            ids_path.chmod(0o600)
    except (OSError, ValueError) as exc:
        print(f"x-digest-discord-chunks: {exc}", file=sys.stderr)
        return 1
    print(len(chunks))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
