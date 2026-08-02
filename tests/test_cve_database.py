from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import sys
import unittest


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
            ValueError,
            "timestamp must be UTC",
        ):
            CVE_DATABASE.parse_utc("not-a-timestamp")


if __name__ == "__main__":
    unittest.main()
