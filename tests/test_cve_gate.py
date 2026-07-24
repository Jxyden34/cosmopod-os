from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from uuid import uuid4


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/check-cve-report.py"
TEST_TEMP_ROOT = MODULE_PATH.parents[1] / ".test-tmp"
TEST_TEMP_ROOT.mkdir(exist_ok=True)
SPEC = importlib.util.spec_from_file_location("cosmopod_cve_gate", MODULE_PATH)
assert SPEC and SPEC.loader
CVE_GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CVE_GATE
SPEC.loader.exec_module(CVE_GATE)


def report(status: str, score: str) -> dict[str, object]:
    return {
        "version": "1",
        "package": [
            {
                "name": "openssl",
                "issue": [
                    {
                        "id": "CVE-2026-12345",
                        "status": status,
                        "scorev3": score,
                    }
                ],
            }
        ],
    }


def database() -> object:
    checked = datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc)
    return CVE_GATE.DatabaseEvidence(
        "e" * 64,
        "c" * 64,
        100_000_000,
        checked - timedelta(seconds=60),
        250_000,
        500_000,
        checked - timedelta(hours=1),
        checked - timedelta(hours=2),
        checked,
        checked,
        60,
        172800,
        3600,
        1209600,
    )


def coverage() -> object:
    return CVE_GATE.CoverageEvidence("d" * 64, frozenset({"openssl"}))


def database_evidence_text() -> str:
    return "\n".join(
        [
            "format=cosmopod-cve-database-evidence-v1",
            f"database_sha256={'c' * 64}",
            "database_bytes=100000000",
            "database_mtime_utc=2026-07-16T11:59:00Z",
            "database_nvd_rows=250000",
            "database_products_rows=500000",
            "database_latest_modified_utc=2026-07-16T11:00:00Z",
            "build_started_at=2026-07-16T10:00:00Z",
            "checked_at=2026-07-16T12:00:00Z",
            "database_age_seconds=60",
            "database_max_age_seconds=172800",
            "database_content_age_seconds=3600",
            "database_content_max_age_seconds=1209600",
            "database_integrity=ok",
            "database_refreshed_during_build=true",
            "",
        ]
    )


class CveGateTests(unittest.TestCase):
    def render(self, status: str, score: str) -> tuple[str, bool]:
        recipes, findings = CVE_GATE.parse_report(report(status, score))
        return CVE_GATE.render_evidence(
            "a" * 64,
            "b" * 64,
            date(2026, 7, 16),
            recipes,
            findings,
            set(),
            0,
            database(),
            coverage(),
        )

    def test_blocks_high_unpatched_issue(self) -> None:
        evidence, passed = self.render("Unpatched", "8.1")
        self.assertFalse(passed)
        self.assertIn("decision=FAIL", evidence)

    def test_allows_low_unpatched_issue(self) -> None:
        evidence, passed = self.render("Unpatched", "5.4")
        self.assertTrue(passed)
        self.assertIn("decision=PASS", evidence)

    def test_scoped_reviewed_waiver_allows_issue(self) -> None:
        waivers = {
            "format": "cosmopod-cve-waivers-v1",
            "waivers": [
                {
                    "package": "openssl",
                    "cve": "CVE-2026-12345",
                    "expires": "2026-07-17",
                    "justification": "Exposure reviewed and mitigated in deployment.",
                    "approver": "Security owner",
                    "tracking_url": "https://example.invalid/CVE-2026-12345",
                }
            ],
        }
        active, expired = CVE_GATE.parse_waivers(waivers, date(2026, 7, 16))
        self.assertEqual(active, {("openssl", "CVE-2026-12345")})
        self.assertEqual(expired, 0)

    def test_expired_waiver_fails_gate(self) -> None:
        waivers = {
            "format": "cosmopod-cve-waivers-v1",
            "waivers": [
                {
                    "package": "openssl",
                    "cve": "CVE-2026-12345",
                    "expires": "2026-07-15",
                    "justification": "Exposure reviewed and mitigated in deployment.",
                    "approver": "Security owner",
                    "tracking_url": "https://example.invalid/CVE-2026-12345",
                }
            ],
        }
        active, expired = CVE_GATE.parse_waivers(waivers, date(2026, 7, 16))
        self.assertEqual(active, set())
        self.assertEqual(expired, 1)

    def test_report_must_cover_every_licensed_recipe(self) -> None:
        recipes, findings = CVE_GATE.parse_report(report("Patched", "8.1"))
        incomplete = CVE_GATE.CoverageEvidence(
            "d" * 64, frozenset({"openssl", "busybox"})
        )
        with self.assertRaisesRegex(CVE_GATE.InputError, "coverage differs"):
            CVE_GATE.render_evidence(
                "a" * 64,
                "b" * 64,
                date(2026, 7, 16),
                recipes,
                findings,
                set(),
                0,
                database(),
                incomplete,
            )

    def test_license_coverage_normalizes_metadata_recipes(self) -> None:
        path = TEST_TEMP_ROOT / f"license-{uuid4().hex}.manifest"
        try:
            path.write_bytes(
                b"PACKAGE NAME: glibc-locale\nRECIPE NAME: glibc-locale\n"
                b"LICENSE: GPL-2.0-or-later\n\n"
                b"PACKAGE NAME: packagegroup-core-boot\n"
                b"RECIPE NAME: packagegroup-core-boot\nLICENSE: MIT\n\n"
                b"PACKAGE NAME: openssl\nRECIPE NAME: openssl\n"
                b"LICENSE: Apache-2.0\n"
            )
            parsed = CVE_GATE.parse_license_manifest(path)
            self.assertEqual(parsed.recipes, frozenset({"glibc", "openssl"}))
        finally:
            path.unlink(missing_ok=True)

    def test_stale_database_is_rejected_at_signing_time(self) -> None:
        path = TEST_TEMP_ROOT / f"database-{uuid4().hex}.txt"
        try:
            path.write_bytes(database_evidence_text().encode("utf-8"))
            evaluated = datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc)
            with self.assertRaisesRegex(CVE_GATE.InputError, "database is stale"):
                CVE_GATE.parse_database_evidence(path, evaluated)
        finally:
            path.unlink(missing_ok=True)

    def test_fresh_cached_database_is_accepted(self) -> None:
        path = TEST_TEMP_ROOT / f"database-{uuid4().hex}.txt"
        try:
            evidence = database_evidence_text().replace(
                "build_started_at=2026-07-16T10:00:00Z",
                "build_started_at=2026-07-16T12:00:00Z",
            ).replace(
                "database_refreshed_during_build=true",
                "database_refreshed_during_build=false",
            )
            path.write_bytes(evidence.encode("utf-8"))
            evaluated = datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc)
            parsed = CVE_GATE.parse_database_evidence(path, evaluated)
            self.assertEqual(parsed.age_seconds, 60)
        finally:
            path.unlink(missing_ok=True)

    def test_cli_records_database_and_recipe_coverage(self) -> None:
        root = TEST_TEMP_ROOT
        token = uuid4().hex
        paths = []
        try:
            report_path = root / f"report-{token}.json"
            waivers_path = root / f"waivers-{token}.json"
            license_path = root / f"license-{token}.manifest"
            database_path = root / f"database-{token}.txt"
            output_path = root / f"gate-{token}.txt"
            paths = [report_path, waivers_path, license_path, database_path, output_path]
            report_path.write_text(json.dumps(report("Patched", "8.1")), encoding="utf-8")
            waivers_path.write_text(
                json.dumps({"format": "cosmopod-cve-waivers-v1", "waivers": []}),
                encoding="utf-8",
            )
            license_path.write_bytes(
                b"PACKAGE NAME: openssl\nRECIPE NAME: openssl\nLICENSE: Apache-2.0\n"
            )
            database_path.write_bytes(database_evidence_text().encode("utf-8"))
            result = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--report",
                    str(report_path),
                    "--waivers",
                    str(waivers_path),
                    "--license-manifest",
                    str(license_path),
                    "--database-evidence",
                    str(database_path),
                    "--verification-at",
                    "2026-07-16T12:00:00Z",
                    "--output",
                    str(output_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = output_path.read_text(encoding="utf-8")
            self.assertIn("format=cosmopod-cve-gate-v3", evidence)
            self.assertIn("database_age_seconds=60", evidence)
            self.assertIn("coverage_complete=true", evidence)
        finally:
            for path in paths:
                path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
