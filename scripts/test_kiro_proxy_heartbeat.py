#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "kiro-proxy-heartbeat.sh"
SERVICE = ROOT / "ops/systemd/units/kiro-proxy-heartbeat.service"


class HealthMonitorTimeoutTests(unittest.TestCase):
    def test_over_budget_overrides_fail_before_any_probe(self) -> None:
        for variable, value in (
            ("OPENCLAW_HEALTH_PROBE_TIMEOUT_SECS", "11"),
            ("OPENCLAW_HEALTH_RECOVERY_HEALTH_ATTEMPTS", "31"),
            ("OPENCLAW_HEALTH_RECOVERY_READY_ATTEMPTS", "31"),
        ):
            with self.subTest(variable=variable), tempfile.TemporaryDirectory() as home:
                env = os.environ.copy()
                env.update(
                    {
                        "HOME": home,
                        "OPENCLAW_HEALTH_PUBLISH_METRICS": "0",
                        variable: value,
                    }
                )
                result = subprocess.run(
                    ["bash", str(SCRIPT)],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=env,
                    check=False,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("service-timeout budget", result.stderr)
                self.assertFalse((Path(home) / ".openclaw").exists())

    def test_service_timeout_covers_enforced_worst_case(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        service = SERVICE.read_text(encoding="utf-8")
        timeout_match = re.search(r"^TimeoutStartSec=(\d+)$", service, re.MULTILINE)
        self.assertIsNotNone(timeout_match)

        # 4 initial 10s probes + 4s metadata + 15s metrics + 170s capture,
        # then 5s sessions + 15s event + 45s restart + two (30*10+29)s
        # probe loops + 15s status + 15s result metric.
        worst_case = 4 * 10 + 4 + 15 + 170 + 5 + 15 + 45 + 2 * 329 + 15 + 15
        self.assertEqual(worst_case, 982)
        self.assertGreaterEqual(int(timeout_match.group(1)), worst_case + 120)
        self.assertIn('timeout "$AWS_CALL_TIMEOUT_SECS" "$AWS_BIN"', script)
        self.assertIn('timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" ss -ltnp', script)
        self.assertIn('timeout "$RESTART_TIMEOUT_SECS" "$SYSTEMCTL_BIN"', script)


if __name__ == "__main__":
    unittest.main()
