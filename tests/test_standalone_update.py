"""Exercise the real standalone updater with isolated storage and signatures."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
UPDATER = None
if os.name == "posix":
    spec = importlib.util.spec_from_file_location(
        "cosmopod_update", ROOT / "meta-cosmopod/recipes-core/cosmopod-config/files/cosmopod-update.py")
    UPDATER = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(UPDATER)


@unittest.skipUnless(UPDATER and shutil.which("openssl"), "requires POSIX and OpenSSL")
class StandaloneUpdateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cosmopod-update-test-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.state = self.base / "state"
        self.state.mkdir(mode=0o700)
        self.key = self.base / "public.pem"
        self.private = self.base / "private.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                        "ec_paramgen_curve:P-256", "-out", str(self.private)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(self.private), "-pubout",
                        "-out", str(self.key)], check=True, capture_output=True)
        self.device = self.base / "device_type"
        self.device.write_text("device_type=cosmopod-rpi4-64\n")
        self.os_release = self.base / "os-release"
        self.os_release.write_text('ID=cosmopod\nVERSION_ID="0.73.0"\n')
        self.boot = self.base / "boot-id"
        self.boot.write_text("boot-1\n")
        for name, value in (("STATE", self.state), ("KEY", self.key), ("DEVICE_TYPE", self.device),
                            ("OS_RELEASE", self.os_release), ("BOOT_ID", self.boot)):
            patch = mock.patch.object(UPDATER, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.filename = "Cosmopod-OS-0.74.0-pi4.mender"
        self.payload = b"signed artifact fixture; Mender itself is mocked"
        self.index = self.base / "index"
        self.index.write_text(f"{hashlib.sha256(self.payload).hexdigest()}  ./{self.filename}\n")
        self.signature = self.base / "index.sig"
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.private),
                        "-out", str(self.signature), str(self.index)], check=True, capture_output=True)
        self.calls = []
        self.real_run = UPDATER.run

    def fake_download(self, url, destination, limit):
        if url.endswith("SHA256SUMS-pi4"):
            destination.write_bytes(self.index.read_bytes())
        elif url.endswith("SHA256SUMS-pi4.sig"):
            destination.write_bytes(self.signature.read_bytes())
        elif url.endswith(self.filename):
            destination.write_bytes(self.payload)
        else:
            self.fail(f"Unexpected URL: {url}")

    def fake_run(self, *args):
        if args[0] == UPDATER.MENDER:
            self.calls.append(args)
        else:
            self.real_run(*args)

    def install(self):
        with mock.patch.object(UPDATER, "download", side_effect=self.fake_download), \
             mock.patch.object(UPDATER, "run", side_effect=self.fake_run):
            UPDATER.install_release("0.74.0", "pi4")

    def test_signed_index_hash_and_board_install_then_explicit_commit(self):
        self.install()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][:2], (UPDATER.MENDER, "install"))
        with self.assertRaisesRegex(ValueError, "Reboot"):
            UPDATER.finish_update("commit", "pi4")
        self.boot.write_text("boot-2")
        self.os_release.write_text('ID=cosmopod\nVERSION_ID="0.74.0"\n')
        with mock.patch.object(UPDATER, "run", side_effect=self.fake_run):
            UPDATER.finish_update("commit", "pi4")
        self.assertEqual(self.calls[-1], (UPDATER.MENDER, "commit"))
        self.assertFalse((self.state / "update.json").exists())

    def test_tampered_index_never_reaches_mender(self):
        self.index.write_text(self.index.read_text().replace(self.filename, "other.mender"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(self.calls, [])
        self.assertFalse((self.state / "update.json").exists())

    def test_wrong_key_never_reaches_mender(self):
        other = self.base / "other.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                        "ec_paramgen_curve:P-256", "-out", str(other)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(other), "-pubout",
                        "-out", str(self.key)], check=True, capture_output=True)
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(self.calls, [])

    def test_unsigned_index_never_reaches_mender(self):
        self.signature.write_bytes(b"")
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(self.calls, [])

    def test_tampered_artifact_never_reaches_mender(self):
        self.payload += b"tampered"
        with self.assertRaisesRegex(ValueError, "signed checksum"):
            self.install()
        self.assertEqual(self.calls, [])

    def test_install_failure_retains_recovery_record_and_blocks_commit(self):
        def fail_install(*args):
            if args[0] == UPDATER.MENDER:
                raise subprocess.CalledProcessError(1, args)
            self.real_run(*args)
        with mock.patch.object(UPDATER, "download", side_effect=self.fake_download), \
             mock.patch.object(UPDATER, "run", side_effect=fail_install):
            with self.assertRaises(subprocess.CalledProcessError):
                UPDATER.install_release("0.74.0", "pi4")
        self.assertEqual(json.loads((self.state / "update.json").read_text())["state"], "installing")
        with self.assertRaisesRegex(ValueError, "Reboot"):
            UPDATER.finish_update("commit", "pi4")

    def test_no_commit_after_automatic_rollback(self):
        self.install()
        self.boot.write_text("boot-2")
        with self.assertRaisesRegex(ValueError, "Running version"):
            UPDATER.finish_update("commit", "pi4")

    def test_same_version_downgrade_and_pending_update_rejected(self):
        for value in ("0.73.0", "0.72.0"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                UPDATER.install_release(value, "pi4")
        UPDATER.save_pending({"state": "installing"})
        with self.assertRaisesRegex(ValueError, "already pending"):
            self.install()

    def test_board_mismatch_never_commits(self):
        UPDATER.save_pending({"board": "pi5"})
        with self.assertRaisesRegex(ValueError, "another device"):
            UPDATER.finish_update("commit", "pi4")

    def test_checksum_parser_rejects_duplicates_paths_and_missing_board(self):
        digest = "a" * 64
        for text in (f"{digest}  ../bad\n", f"{digest}  ./x\n{digest}  ./x\n",
                     f"{digest}  ./other.mender\n", "not a checksum"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                UPDATER.artifact_digest(text, self.filename)

    def test_version_and_device_selection(self):
        for value in ("../evil", "1.0.0-dev", "01.0.0", "v1.0.0", "1.0.0?x"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                UPDATER.release_version(value)
        self.assertEqual(UPDATER.device_board(), "pi4")
        self.device.write_text("device_type=cosmopod-rpi5")
        self.assertEqual(UPDATER.device_board(), "pi5")
        self.device.unlink()
        with self.assertRaisesRegex(ValueError, "no Pi"):
            UPDATER.device_board()

    def test_latest_release_rejects_draft_and_prerelease(self):
        for draft, prerelease, tag in ((True, False, "v1.0.0"), (False, True, "v1.0.0"),
                                       (False, False, "v../evil")):
            def fetch(url, destination, limit):
                destination.write_text(json.dumps(dict(draft=draft, prerelease=prerelease, tag_name=tag)))
            with mock.patch.object(UPDATER, "download", side_effect=fetch), self.assertRaises(ValueError):
                UPDATER.release_version()

    def test_rollback_calls_mender_before_clearing_record(self):
        UPDATER.save_pending({"board": "pi4"})
        with mock.patch.object(UPDATER, "run", side_effect=self.fake_run):
            UPDATER.finish_update("rollback", "pi4")
        self.assertEqual(self.calls[-1], (UPDATER.MENDER, "rollback"))
        self.assertFalse((self.state / "update.json").exists())

    def test_missing_or_overridden_signature_key_and_unmasked_daemon_rejected(self):
        config = self.base / "config.json"
        persistent = self.base / "persistent.json"
        units = self.base / "units"
        units.mkdir()
        for name in ("mender-updated.service", "mender-authd.service"):
            (units / name).symlink_to("/dev/null")
        config.write_text(json.dumps({"ArtifactVerifyKey": str(self.key)}))
        with mock.patch.multiple(UPDATER, CONFIG=config, PERSISTENT_CONFIG=persistent, UNITS=units):
            UPDATER.verify_configuration()
            persistent.write_text(json.dumps({"ArtifactVerifyKey": "/untrusted.pem"}))
            with self.assertRaisesRegex(ValueError, "signature"):
                UPDATER.verify_configuration()
            persistent.unlink()
            (units / "mender-updated.service").unlink()
            with self.assertRaisesRegex(ValueError, "masked"):
                UPDATER.verify_configuration()

    def test_download_requires_tls_for_initial_url_and_redirects(self):
        destination = self.base / "download"
        def fetch(*args):
            self.assertEqual(args[:2], ("curl", "--disable"))
            self.assertIn("--proto", args)
            self.assertEqual(args[args.index("--proto") + 1], "=https")
            self.assertEqual(args[args.index("--proto-redir") + 1], "=https")
            destination.write_bytes(b"ok")
        with mock.patch.object(UPDATER, "run", side_effect=fetch):
            UPDATER.download("https://github.com/example", destination, 3)
            with self.assertRaisesRegex(ValueError, "size limit"):
                UPDATER.download("https://github.com/example", destination, 1)

    def test_publisher_rejects_unsafe_versions_without_running_gh(self):
        for version in ("../evil", "v1.0.0", "1.0.0-dev", "01.2.3"):
            result = subprocess.run(["bash", str(ROOT / "scripts/publish-release.sh"), version],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
