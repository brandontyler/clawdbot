#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import re
import sys
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def load_script():
    spec = importlib.util.spec_from_file_location("denton_crime_watch", HERE / "denton-crime-watch.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


crime_watch = load_script()


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self._body = io.BytesIO(json.dumps(payload).encode())

    def __enter__(self):
        return self

    def __exit__(self, *_args) -> None:
        return None

    def read(self) -> bytes:
        return self._body.read()


class DentonCrimeWatchTests(unittest.TestCase):
    def test_sql_query_passes_the_bounded_fetch_timeout(self) -> None:
        payload = {"success": True, "result": {"records": []}}
        with mock.patch.object(
            crime_watch.urllib.request,
            "urlopen",
            return_value=FakeResponse(payload),
        ) as urlopen:
            self.assertEqual(crime_watch.sql_query("SELECT 1", timeout=7.5), [])
        self.assertEqual(urlopen.call_args.kwargs["timeout"], 7.5)

    def test_private_address_and_bounded_delivery_contract(self) -> None:
        script = (HERE / "denton-crime-watch.sh").read_text(encoding="utf-8")
        service = (ROOT / "ops/systemd/units/denton-crime-watch.service").read_text(
            encoding="utf-8"
        )

        self.assertIsNone(re.search(r"\b\d{3,5}\s+Headlee\b", script, re.IGNORECASE))
        self.assertIn('HOME_ADDRESS="${DENTON_HOME_ADDRESS:-}"', script)
        self.assertIn(
            "EnvironmentFile=-/home/ubuntu/.config/openclaw/denton-crime-watch.env",
            service,
        )
        self.assertIn("--fetch-timeout \"$FETCH_TIMEOUT_SECS\"", script)
        self.assertIn("^2[0-9][0-9]$", script)
        self.assertIn("posted and verified weekly crime digest", script)

        timeout_match = re.search(r"^TimeoutStartSec=(\d+)$", service, re.MULTILINE)
        self.assertIsNotNone(timeout_match)
        # Script maxima: 3 × (30 + 5) fetch, 180 model, 6 × 30 Discord.
        self.assertGreaterEqual(int(timeout_match.group(1)), 3 * 35 + 180 + 6 * 30)


if __name__ == "__main__":
    unittest.main()
