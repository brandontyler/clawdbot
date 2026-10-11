#!/usr/bin/env python3
"""Focused fixture tests for ops/install-systemd-units.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "ops" / "install-systemd-units.sh"
CADDY_DROPIN = ROOT / "ops" / "systemd" / "system-dropins" / "caddy.service.d" / "hardening.conf"


class InstallerFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="openclaw-systemd-test-")
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "repo"
        self.units_src = self.repo / "ops" / "systemd" / "units"
        self.dropins_src = self.repo / "ops" / "systemd" / "system-dropins"
        self.user_dest = self.root / "user"
        self.system_dest = self.root / "system"
        self.state_dir = self.root / "state"
        self.bin_dir = self.root / "bin"
        self.command_log = self.root / "commands.log"
        self.systemctl_log = self.root / "systemctl.log"
        for directory in (
            self.units_src,
            self.dropins_src,
            self.user_dest,
            self.system_dest,
            self.state_dir,
            self.bin_dir,
        ):
            directory.mkdir(parents=True, exist_ok=True)

        self.write(
            self.bin_dir / "sudo",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'sudo' >>"$COMMAND_LOG"
printf ' %s' "$@" >>"$COMMAND_LOG"
printf '\\n' >>"$COMMAND_LOG"
[ "${1:-}" = -n ] || exit 97
shift
exec "$@"
""",
        )
        self.write(
            self.bin_dir / "systemctl",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl' >>"$SYSTEMCTL_LOG"
printf ' %s' "$@" >>"$SYSTEMCTL_LOG"
printf '\\n' >>"$SYSTEMCTL_LOG"
""",
        )
        os.chmod(self.bin_dir / "sudo", 0o755)
        os.chmod(self.bin_dir / "systemctl", 0o755)

        self.env = os.environ.copy()
        self.env.update(
            {
                "COMMAND_LOG": str(self.command_log),
                "HOME": str(self.root / "home"),
                "OPENCLAW_SYSTEMD_REPO_DIR": str(self.repo),
                "OPENCLAW_SYSTEMD_STATE_DIR": str(self.state_dir),
                "OPENCLAW_SYSTEMD_SYSTEM_DEST": str(self.system_dest),
                "OPENCLAW_SYSTEMD_USER_DEST": str(self.user_dest),
                "PATH": f"{self.bin_dir}:{self.env['PATH']}",
                "SYSTEMCTL_LOG": str(self.systemctl_log),
            }
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    @staticmethod
    def write(path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def seed_reconciliation_fixture(self) -> None:
        self.write(self.units_src / "keep.service", "repo user unit\n")
        self.write(self.user_dest / "keep.service", "stale user unit\n")
        self.write(self.user_dest / "retired.timer", "retired user unit\n")
        self.write(self.user_dest / "external.timer", "external user unit\n")
        self.write(
            self.state_dir / "systemd-user-units.manifest",
            "keep.service\nretired.timer\n",
        )

        current = "caddy.service.d/hardening.conf"
        retired = "retired.service.d/old.conf"
        external = "external.service.d/local.conf"
        self.write(self.dropins_src / current, "repo system drop-in\n")
        self.write(self.system_dest / current, "stale system drop-in\n")
        self.write(self.system_dest / retired, "retired system drop-in\n")
        self.write(self.system_dest / external, "external system drop-in\n")
        self.write(
            self.state_dir / "systemd-system-dropins.manifest",
            f"{current}\n{retired}\n",
        )

    def run_installer(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(INSTALLER), *args],
            check=True,
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
        )

    def test_caddy_capabilities_are_cleared_then_restricted(self) -> None:
        text = CADDY_DROPIN.read_text(encoding="utf-8")
        self.assertIn(
            "CapabilityBoundingSet=\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n",
            text,
        )
        self.assertIn(
            "AmbientCapabilities=\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n",
            text,
        )
        self.assertNotIn("CAP_NET_ADMIN", text)

    def test_dry_run_and_diff_report_only_owned_changes_without_mutation(self) -> None:
        self.seed_reconciliation_fixture()

        before = {
            path.relative_to(self.root): path.read_bytes()
            for path in self.root.rglob("*")
            if path.is_file()
        }
        dry_run = self.run_installer("--dry-run")
        self.assertIn("would update: keep.service", dry_run.stdout)
        self.assertIn("would retire user unit: retired.timer", dry_run.stdout)
        self.assertIn(
            "would update system drop-in: caddy.service.d/hardening.conf",
            dry_run.stdout,
        )
        self.assertIn(
            "would retire system drop-in: retired.service.d/old.conf",
            dry_run.stdout,
        )
        self.assertNotIn("external.timer", dry_run.stdout)
        self.assertNotIn("external.service.d/local.conf", dry_run.stdout)
        after = {
            path.relative_to(self.root): path.read_bytes()
            for path in self.root.rglob("*")
            if path.is_file() and path not in {self.command_log, self.systemctl_log}
        }
        expected = {
            path: content
            for path, content in before.items()
            if path not in {self.command_log.relative_to(self.root), self.systemctl_log.relative_to(self.root)}
        }
        self.assertEqual(after, expected)
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertNotIn(" install ", commands)
        self.assertNotIn(" rm ", commands)
        self.assertFalse(self.systemctl_log.exists())

        diff = self.run_installer("--diff")
        self.assertIn("=== keep.service (would change) ===", diff.stdout)
        self.assertIn(
            "=== retired.timer (would retire — deleted from repo) ===",
            diff.stdout,
        )
        self.assertIn(
            "=== caddy.service.d/hardening.conf (system drop-in would change) ===",
            diff.stdout,
        )
        self.assertIn(
            "=== retired.service.d/old.conf (system drop-in would retire — deleted from repo) ===",
            diff.stdout,
        )

    def test_apply_reconciles_owned_files_and_uses_noninteractive_sudo(self) -> None:
        self.seed_reconciliation_fixture()

        self.run_installer()

        self.assertEqual(
            (self.user_dest / "keep.service").read_text(encoding="utf-8"),
            "repo user unit\n",
        )
        self.assertFalse((self.user_dest / "retired.timer").exists())
        self.assertTrue((self.user_dest / "external.timer").exists())
        self.assertEqual(
            (self.system_dest / "caddy.service.d/hardening.conf").read_text(
                encoding="utf-8"
            ),
            "repo system drop-in\n",
        )
        self.assertFalse((self.system_dest / "retired.service.d/old.conf").exists())
        self.assertTrue((self.system_dest / "external.service.d/local.conf").exists())
        self.assertEqual(
            (self.state_dir / "systemd-user-units.manifest").read_text(
                encoding="utf-8"
            ),
            "keep.service\n",
        )
        self.assertEqual(
            (self.state_dir / "systemd-system-dropins.manifest").read_text(
                encoding="utf-8"
            ),
            "caddy.service.d/hardening.conf\n",
        )

        sudo_calls = self.command_log.read_text(encoding="utf-8").splitlines()
        self.assertTrue(sudo_calls)
        self.assertTrue(all(call.startswith("sudo -n ") for call in sudo_calls))
        self.assertTrue(any(" install -D -m 0644 " in call for call in sudo_calls))
        self.assertTrue(any(" rm -f -- " in call for call in sudo_calls))
        self.assertIn("sudo -n systemctl daemon-reload", sudo_calls)

        systemctl_calls = self.systemctl_log.read_text(encoding="utf-8")
        self.assertIn(
            "systemctl --user disable --now retired.timer", systemctl_calls
        )
        self.assertIn("systemctl --user daemon-reload", systemctl_calls)
        self.assertIn("systemctl daemon-reload", systemctl_calls)

    def test_unit_filter_preserves_focused_user_only_behavior(self) -> None:
        self.seed_reconciliation_fixture()

        self.run_installer("--unit=keep.service")

        self.assertEqual(
            (self.user_dest / "keep.service").read_text(encoding="utf-8"),
            "repo user unit\n",
        )
        self.assertTrue((self.user_dest / "retired.timer").exists())
        self.assertEqual(
            (self.system_dest / "caddy.service.d/hardening.conf").read_text(
                encoding="utf-8"
            ),
            "stale system drop-in\n",
        )
        self.assertFalse(self.command_log.exists())
        self.assertIn(
            "systemctl --user daemon-reload",
            self.systemctl_log.read_text(encoding="utf-8"),
        )

    def test_enable_keeps_selected_timer_behavior_user_only(self) -> None:
        self.write(self.units_src / "selected.timer", "selected timer\n")
        self.write(self.units_src / "other.timer", "other timer\n")

        self.run_installer("--enable", "--unit=selected.timer")

        systemctl_calls = self.systemctl_log.read_text(encoding="utf-8")
        self.assertIn(
            "systemctl --user enable --now selected.timer", systemctl_calls
        )
        self.assertNotIn("other.timer", systemctl_calls)
        self.assertFalse(self.command_log.exists())

    def test_first_run_adopts_only_exact_historical_repository_unit(self) -> None:
        historical = "historical repository timer\n"
        self.write(self.units_src / "keep.service", "repo user unit\n")
        self.write(self.units_src / "retired.timer", historical)
        self.write(
            self.dropins_src / "caddy.service.d/hardening.conf",
            "repo system drop-in\n",
        )
        self.write(
            self.system_dest / "caddy.service.d/hardening.conf",
            "repo system drop-in\n",
        )
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "config", "user.email", "fixture@example.invalid"],
            cwd=self.repo,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Fixture"], cwd=self.repo, check=True
        )
        subprocess.run(["git", "add", "ops"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "fixture units"], cwd=self.repo, check=True
        )
        (self.units_src / "retired.timer").unlink()
        self.write(self.user_dest / "retired.timer", historical)
        self.write(self.user_dest / "external.timer", historical)

        result = self.run_installer("--dry-run")

        self.assertIn("would retire user unit: retired.timer", result.stdout)
        self.assertNotIn("external.timer", result.stdout)
        self.assertTrue((self.user_dest / "retired.timer").exists())
        self.assertTrue((self.user_dest / "external.timer").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
