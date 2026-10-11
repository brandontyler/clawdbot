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
SERVICE = SCRIPT.parent.parent / "ops/systemd/units/sermon-notes-print.service"


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

    def test_all_content_work_runs_directly_in_the_sermon_project(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'SERMON_CHANNEL_ID="${SERMON_NOTES_DISCORD_CHANNEL_ID:-1538537707696029757}"',
            source,
        )
        self.assertIn('DISCORD_CHANNEL="$SERMON_CHANNEL_ID"', source)
        self.assertIn(
            'SERMON_PROJECT_DIR="${SERMON_NOTES_PROJECT_DIR:-$HOME/code/personal/sermon}"',
            source,
        )
        for prohibited in (
            "bridge-send",
            "sessions.send",
            "sessions_send",
            "--trust-all-tools",
            "fs_write",
            "execute_bash",
        ):
            self.assertNotIn(prohibited, source)
        self.assertNotIn("sermon-print-job", source)
        self.assertEqual(source.count('run_sermon_agent "$qfile" 600'), 2)
        self.assertIn("timeout --kill-after=10s \"$timeout_seconds\"", source)
        self.assertIn('[[ "$_agent_result" != "SERMON_AGENT_OK" ]]', source)
        self.assertEqual(
            source.count("--trust-tools=fs_read,grep,glob,web_search,web_fetch"), 1
        )
        self.assertIn("kiro-cli chat --agent default --effort xhigh", source)
        service = SERVICE.read_text(encoding="utf-8")
        self.assertIn("WorkingDirectory=/home/ubuntu/code/personal/sermon", service)
        self.assertNotIn("1503414103341797406", source)
        self.assertIn('post_discord "🖨️ Sermon notes print started', source)

    def test_routing_check_posts_to_sermon_without_print_or_email(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            curl_log = root / "curl.log"
            fake_jq = fake_bin / "jq"
            fake_jq.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == \"-r\" ]]; then printf 'fake-token\\n'; "
                "else printf '{\"content\":\"routing check\"}\\n'; fi\n"
            )
            fake_jq.chmod(0o755)
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$MOCK_CURL_LOG\"\n"
                "printf '200'\n"
            )
            fake_curl.chmod(0o755)
            (root / ".openclaw").mkdir()
            (root / ".openclaw/openclaw.json").write_text("{}", encoding="utf-8")
            env = os.environ.copy()
            env.update({
                "HOME": str(root),
                "PATH": f"{fake_bin}:{env['PATH']}",
                "MOCK_CURL_LOG": str(curl_log),
                "TZ": "America/Chicago",
            })
            result = subprocess.run(
                ["bash", str(SCRIPT), "--routing-check"],
                cwd=SCRIPT.parent.parent,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("no printer or email action", result.stdout.lower())
            request = curl_log.read_text(encoding="utf-8")
            self.assertIn("/channels/1538537707696029757/messages", request)
            self.assertNotIn("hpeprint", request.lower())
            self.assertNotIn("dentonbible", request.lower())

    def test_agent_check_runs_headlessly_inside_sermon_project_without_bridge(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "sermon"
            project.mkdir()
            fake_bin = root / "bin"
            fake_bin.mkdir()
            agent_log = root / "agent.log"
            curl_log = root / "curl.log"
            fake_kiro = fake_bin / "kiro-cli"
            fake_kiro.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$PWD\" > \"$MOCK_AGENT_LOG\"\n"
                "printf '%s\\n' \"$*\" >> \"$MOCK_AGENT_LOG\"\n"
                "printf 'UNTRUSTED CLI BANNER\\n> SERMON_AGENT_OK\\n'\n"
            )
            fake_kiro.chmod(0o755)
            fake_jq = fake_bin / "jq"
            fake_jq.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == \"-r\" ]]; then printf 'fake-token\\n'; "
                "else printf '{\"content\":\"agent check\"}\\n'; fi\n"
            )
            fake_jq.chmod(0o755)
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$MOCK_CURL_LOG\"\n"
                "printf '200'\n"
            )
            fake_curl.chmod(0o755)
            (root / ".openclaw").mkdir()
            (root / ".openclaw/openclaw.json").write_text("{}", encoding="utf-8")
            env = os.environ.copy()
            env.update({
                "HOME": str(root),
                "PATH": f"{fake_bin}:{env['PATH']}",
                "MOCK_AGENT_LOG": str(agent_log),
                "MOCK_CURL_LOG": str(curl_log),
                "SERMON_NOTES_PROJECT_DIR": str(project),
                "TZ": "America/Chicago",
            })
            result = subprocess.run(
                ["bash", str(SCRIPT), "--agent-check"],
                cwd=SCRIPT.parent.parent,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("no printer or email action", result.stdout.lower())
            lines = agent_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines[0], str(project))
            self.assertIn("chat --agent default --effort xhigh", lines[1])
            self.assertIn("--trust-tools=fs_read,grep,glob,web_search,web_fetch", lines[1])
            self.assertIn("--no-interactive --wrap never", lines[1])
            self.assertNotIn("bridge", lines[1].lower())
            request = curl_log.read_text(encoding="utf-8")
            self.assertIn("/channels/1538537707696029757/messages", request)
            self.assertNotIn("hpeprint", request.lower())
            self.assertNotIn("dentonbible", request.lower())

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
