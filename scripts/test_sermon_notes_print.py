#!/usr/bin/env python3
"""Behavior tests for the Sunday sermon-notes print selector."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).with_name("sermon-notes-print.sh")


class SermonNotesPrintTests(unittest.TestCase):
    def run_dry_job(self, filename: str, reference_date: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    output=""
                    url=""
                    while (( $# )); do
                      case "$1" in
                        -o) output="$2"; shift 2 ;;
                        -*) shift ;;
                        *) url="$1"; shift ;;
                      esac
                    done
                    if [[ -n "$output" ]]; then
                      head -c 2048 /dev/zero > "$output"
                    elif [[ "$url" == *"/media/publications/"* ]]; then
                      printf '<a href="/article/mock-sermon">Mock sermon</a>\n'
                    elif [[ "$url" == *"/article/mock-sermon"* ]]; then
                      printf '%s\n' "$MOCK_MEDIA_URL"
                    else
                      printf 'unexpected URL: %s\n' "$url" >&2
                      exit 2
                    fi
                    """
                )
            )
            fake_curl.chmod(0o755)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(root),
                    "MOCK_MEDIA_URL": (
                        "https://s3.amazonaws.com/account-media/21140/uploaded/s/" + filename
                    ),
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "SERMON_NOTES_REFERENCE_DATE": reference_date,
                    "TZ": "America/Chicago",
                }
            )
            return subprocess.run(
                ["bash", str(SCRIPT), "--dry-run"],
                cwd=SCRIPT.parent.parent,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
            )

    def assert_nothing_would_print(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("would send:", result.stdout)
        self.assertNotIn("falling back to first", result.stdout)
        self.assertNotIn("Detected passage:", result.stdout)

    def test_rejects_last_sundays_notes_when_this_sunday_has_none(self) -> None:
        result = self.run_dry_job(
            "0e21468381_1789677435_sermon-notes-092026.pdf", "2026-09-27"
        )
        self.assert_nothing_would_print(result)
        self.assertIn("No sermon notes dated 2026-09-27", result.stdout)

    def test_does_not_fall_back_to_an_unrelated_pdf(self) -> None:
        result = self.run_dry_job("read-the-bible-in-a-year-plan.pdf", "2026-09-27")
        self.assert_nothing_would_print(result)
        self.assertIn("No sermon notes dated 2026-09-27", result.stdout)

    def test_accepts_notes_dated_for_the_current_sunday(self) -> None:
        result = self.run_dry_job("sermon-notes-092726.pdf", "2026-09-27")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Current Sunday 2026-09-27", result.stdout)
        self.assertIn("[DRY RUN] would send: sermon-notes-092726.pdf", result.stdout)

    def test_persistent_monday_catchup_targets_the_immediately_previous_sunday(self) -> None:
        result = self.run_dry_job("sermon-notes-092826.docx", "2026-09-28")
        self.assert_nothing_would_print(result)
        self.assertIn("No sermon notes dated 2026-09-27", result.stdout)


if __name__ == "__main__":
    unittest.main()
