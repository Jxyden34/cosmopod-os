from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "meta-cosmopod/recipes-core/cosmopod-config/files/cosmopod-firstboot.py"
)
SPEC = importlib.util.spec_from_file_location("cosmopod_firstboot", MODULE_PATH)
assert SPEC and SPEC.loader
FIRSTBOOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIRSTBOOT)


class ConfigParserTests(unittest.TestCase):
    def test_parses_comments_quotes_and_spaces(self) -> None:
        parsed = FIRSTBOOT.parse_config_text(
            "# test\nCOSMOPOD_HOSTNAME=pod-1\nSSH_PUBLIC_KEY='ssh-ed25519 AAAA comment'\n"
        )
        self.assertEqual(parsed["COSMOPOD_HOSTNAME"], "pod-1")
        self.assertEqual(parsed["SSH_PUBLIC_KEY"], "ssh-ed25519 AAAA comment")

    def test_shell_content_stays_inert(self) -> None:
        parsed = FIRSTBOOT.parse_config_text("WIFI_PASSWORD=$(touch /tmp/pwned)\n")
        self.assertEqual(parsed["WIFI_PASSWORD"], "$(touch /tmp/pwned)")

    def test_rejects_unknown_and_duplicate_keys(self) -> None:
        for value in (
            "UNKNOWN=x\n",
            "COSMOPOD_HOSTNAME=a\nCOSMOPOD_HOSTNAME=b\n",
            "COSMOPOD_HOSTNAME\n",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                FIRSTBOOT.parse_config_text(value)

    def test_hostname_validation(self) -> None:
        self.assertEqual(FIRSTBOOT.validate_hostname("Pod-01"), "pod-01")
        for value in ("-pod", "pod_1", "a" * 64):
            with self.subTest(value=value), self.assertRaises(ValueError):
                FIRSTBOOT.validate_hostname(value)

    def test_server_requires_https_by_default(self) -> None:
        self.assertEqual(
            FIRSTBOOT.validate_server_url("https://mender.example.com/", False),
            "https://mender.example.com",
        )
        with self.assertRaises(ValueError):
            FIRSTBOOT.validate_server_url("http://mender.local", False)
        self.assertEqual(
            FIRSTBOOT.validate_server_url("http://mender.local", True),
            "http://mender.local",
        )

    def test_ssh_key_blob_type_must_match(self) -> None:
        valid_blob = "AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        self.assertEqual(
            FIRSTBOOT.validate_ssh_key(f"ssh-ed25519 {valid_blob} operator"),
            f"ssh-ed25519 {valid_blob} operator",
        )
        for value in (
            "ssh-ed25519 AAAA operator",
            f"ssh-rsa {valid_blob} operator",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                FIRSTBOOT.validate_ssh_key(value)


if __name__ == "__main__":
    unittest.main()
