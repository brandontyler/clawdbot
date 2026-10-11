#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "x-digest-foryou.sh"
HELPER = HERE / "x-digest-discord-chunks.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("x_digest_discord_chunks", HELPER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


chunks = load_helper()


class XDigestDeliveryTests(unittest.TestCase):
    def test_chunk_helper_writes_exact_item_id_manifests(self) -> None:
        digest = """# Daily X Digest

**@one**
First item
https://x.com/one/status/111

**@two**
Second item
https://x.com/two/status/222
https://x.com/two/status/222
"""
        with tempfile.TemporaryDirectory() as temporary_dir:
            root = Path(temporary_dir)
            digest_path = root / "digest.md"
            output_dir = root / "chunks"
            digest_path.write_text(digest, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(HELPER), str(digest_path), str(output_dir), "--limit", "100"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest_ids: list[str] = []
            checkpoint = root / "state" / "sent.ids"
            for ids_path in sorted(output_dir.glob("*.ids")):
                manifest_ids.extend(ids_path.read_text(encoding="utf-8").splitlines())
                checkpoint_result = subprocess.run(
                    [
                        sys.executable,
                        str(HELPER),
                        "--checkpoint",
                        str(checkpoint),
                        str(ids_path),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(checkpoint_result.returncode, 0, checkpoint_result.stderr)
            self.assertEqual(manifest_ids, ["111", "222"])
            self.assertEqual(checkpoint.read_text(encoding="utf-8").splitlines(), ["111", "222"])
            self.assertEqual(checkpoint.stat().st_mode & 0o777, 0o600)
            self.assertEqual(checkpoint.parent.stat().st_mode & 0o777, 0o700)
            self.assertTrue(
                all(path.stat().st_mode & 0o777 == 0o600 for path in output_dir.glob("*"))
            )

    def test_shell_checkpoints_each_success_before_next_chunk_and_reuses_it(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        dedup = script.index('load_delivery_checkpoint_ids >> "$SEEN_FILE"')
        fresh_scan = script.index('while IFS= read -r row; do', dedup)
        send = script.index('if ! curl --silent --show-error --fail-with-body --max-time 30')
        checkpoint = script.index('checkpoint_sent_ids "$chunk_ids_file"', send)
        next_delay = script.index('[ "$sent" -lt "$chunk_count" ] && sleep 1', checkpoint)
        reconcile = script.index('load_delivery_checkpoint_ids', next_delay)
        mark = script.index('batch_mark_seen "$FINAL_MARK_FILE"', reconcile)
        clear = script.index("-name '*.ids' -delete", mark)

        self.assertLess(dedup, fresh_scan)
        self.assertLess(send, checkpoint)
        self.assertLess(checkpoint, next_delay)
        self.assertLess(reconcile, mark)
        self.assertLess(mark, clear)
        self.assertIn("successfully sent item IDs remain checkpointed", script)


if __name__ == "__main__":
    unittest.main()
