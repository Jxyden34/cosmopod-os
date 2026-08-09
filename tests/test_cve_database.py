from datetime import datetime, timezone
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/inspect-cve-database.py"
SPEC = importlib.util.spec_from_file_location("cosmopod_cve_database", MODULE_PATH)
assert SPEC and SPEC.loader
CVE_DATABASE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CVE_DATABASE
SPEC.loader.exec_module(CVE_DATABASE)


class CveDatabaseTests(unittest.TestCase):
    def test_release_timestamp_is_utc(self) -> None:
        parsed = CVE_DATABASE.parse_utc("2026-07-24T01:17:47Z")
        self.assertEqual(
            parsed,
            datetime(2026, 7, 24, 1, 17, 47, tzinfo=timezone.utc),
        )

    def test_invalid_release_timestamp_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            CVE_DATABASE.argparse.ArgumentTypeError,
            "timestamp must be UTC",
        ):
            CVE_DATABASE.parse_utc("not-a-timestamp")

    def test_checkout_time_is_captured_before_git_status_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "cvelist"
            subprocess.run(["git", "init", "-q", source], check=True)
            subprocess.run(["git", "-C", source, "config", "user.name", "Test"], check=True)
            subprocess.run(
                ["git", "-C", source, "config", "user.email", "test@example.invalid"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    source,
                    "remote",
                    "add",
                    "origin",
                    CVE_DATABASE.EXPECTED_SOURCES["cvelist"],
                ],
                check=True,
            )
            (source / "entry.json").write_text("{}\n", encoding="utf-8")
            subprocess.run(["git", "-C", source, "add", "entry.json"], check=True)
            subprocess.run(["git", "-C", source, "commit", "-qm", "fixture"], check=True)

            index = source / ".git" / "index"
            original_epoch = 1_700_000_000
            refreshed_epoch = original_epoch + 600
            os.utime(index, (original_epoch, original_epoch))
            original_git = CVE_DATABASE.git

            def refreshing_git(path, *args, **kwargs):
                if args and args[0] == "status":
                    os.utime(index, (refreshed_epoch, refreshed_epoch))
                    return ""
                return original_git(path, *args, **kwargs)

            with mock.patch.object(CVE_DATABASE, "git", side_effect=refreshing_git):
                evidence = CVE_DATABASE.inspect_git_database(
                    root,
                    "cvelist",
                    CVE_DATABASE.EXPECTED_SOURCES["cvelist"],
                )

            self.assertEqual(evidence.checkout_time.timestamp(), original_epoch)


if __name__ == "__main__":
    unittest.main()
