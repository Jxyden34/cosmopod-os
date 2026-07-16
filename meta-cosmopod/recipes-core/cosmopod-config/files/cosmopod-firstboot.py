#!/usr/bin/env python3
"""One-time, non-eval provisioning for Cosmopod OS."""

from __future__ import annotations

import base64
import binascii
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlparse


BOOT_CONFIGS = (
    Path("/uboot/cosmopod.conf"),
    Path("/boot/efi/cosmopod.conf"),
    Path("/boot/cosmopod.conf"),
)
STATE_DIR = Path("/data/cosmopod")
MENDER_CONFIG = Path("/data/mender/mender.conf")
ALLOWED_KEYS = {
    "COSMOPOD_HOSTNAME",
    "SSH_PUBLIC_KEY",
    "WIFI_COUNTRY",
    "WIFI_SSID",
    "WIFI_PASSWORD",
    "MENDER_SERVER_URL",
    "MENDER_TENANT_TOKEN",
    "ALLOW_INSECURE_MENDER",
}
SSH_TYPES = {"ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"}


def parse_config_text(text: str) -> dict[str, str]:
    """Parse strict KEY=VALUE data without shell evaluation."""
    if "\x00" in text:
        raise ValueError("NUL byte is not allowed")

    result: dict[str, str] = {}
    for number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"line {number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key not in ALLOWED_KEYS:
            raise ValueError(f"line {number}: unknown key {key!r}")
        if key in result:
            raise ValueError(f"line {number}: duplicate key {key!r}")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        if "\n" in value or "\r" in value:
            raise ValueError(f"line {number}: newline in value")
        result[key] = value
    return result


def validate_hostname(value: str) -> str:
    if len(value) > 63 or not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", value):
        raise ValueError("COSMOPOD_HOSTNAME must be a valid single-label hostname")
    return value.lower()


def validate_ssh_key(value: str) -> str:
    fields = value.split()
    if len(fields) < 2 or fields[0] not in SSH_TYPES:
        raise ValueError("SSH_PUBLIC_KEY must be an ed25519, RSA, or P-256 OpenSSH public key")
    try:
        decoded = base64.b64decode(fields[1], validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("SSH_PUBLIC_KEY contains invalid base64") from exc
    if len(decoded) < 4:
        raise ValueError("SSH_PUBLIC_KEY contains a truncated OpenSSH blob")
    type_length = int.from_bytes(decoded[:4], "big")
    embedded_type = decoded[4 : 4 + type_length]
    if type_length < 1 or embedded_type != fields[0].encode("ascii"):
        raise ValueError("SSH_PUBLIC_KEY type does not match its OpenSSH blob")
    return " ".join(fields)


def validate_server_url(value: str, allow_insecure: bool) -> str:
    parsed = urlparse(value)
    if not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("MENDER_SERVER_URL must be a plain absolute server URL")
    if parsed.scheme != "https" and not (allow_insecure and parsed.scheme == "http"):
        raise ValueError("MENDER_SERVER_URL must use HTTPS; lab HTTP needs ALLOW_INSECURE_MENDER=true")
    return value.rstrip("/")


def atomic_json_write(path: Path, data: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def provision(config: dict[str, str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    hostname = validate_hostname(config.get("COSMOPOD_HOSTNAME", "cosmopod"))
    (STATE_DIR / "hostname").write_text(hostname + "\n", encoding="utf-8")
    Path("/etc/hostname").write_text(hostname + "\n", encoding="utf-8")
    run("hostnamectl", "set-hostname", hostname, check=False)

    ssh_key = config.get("SSH_PUBLIC_KEY", "").strip()
    if ssh_key:
        ssh_dir = STATE_DIR / "home" / ".ssh"
        ssh_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(ssh_dir, 0o700)
        authorized_keys = ssh_dir / "authorized_keys"
        authorized_keys.write_text(validate_ssh_key(ssh_key) + "\n", encoding="utf-8")
        os.chmod(authorized_keys, 0o600)
        run("chown", "-R", "cosmopod:cosmopod", str(ssh_dir))

    country = config.get("WIFI_COUNTRY", "GB").upper()
    if not re.fullmatch(r"[A-Z]{2}", country):
        raise ValueError("WIFI_COUNTRY must be a two-letter country code")
    (STATE_DIR / "wifi-country").write_text(country + "\n", encoding="utf-8")
    run("iw", "reg", "set", country, check=False)

    ssid = config.get("WIFI_SSID", "")
    wifi_password = config.get("WIFI_PASSWORD", "")
    if ssid:
        if len(ssid.encode("utf-8")) > 32:
            raise ValueError("WIFI_SSID is longer than 32 bytes")
        run("nmcli", "connection", "delete", "cosmopod-wifi", check=False)
        run("nmcli", "connection", "add", "type", "wifi", "ifname", "wlan0", "con-name", "cosmopod-wifi", "ssid", ssid)
        if wifi_password:
            if not 8 <= len(wifi_password.encode("utf-8")) <= 63:
                raise ValueError("WIFI_PASSWORD must be 8-63 UTF-8 bytes for WPA-PSK")
            run("nmcli", "connection", "modify", "cosmopod-wifi", "wifi-sec.key-mgmt", "wpa-psk")
        run("nmcli", "connection", "modify", "cosmopod-wifi", "connection.autoconnect", "yes")
        if wifi_password:
            password_path: Path | None = None
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", prefix="cosmopod-nmcli-", dir="/run", delete=False
                ) as password_file:
                    password_path = Path(password_file.name)
                    os.chmod(password_path, 0o600)
                    password_file.write(f"802-11-wireless-security.psk:{wifi_password}\n")
                    password_file.flush()
                    os.fsync(password_file.fileno())
                run(
                    "nmcli", "connection", "up", "id", "cosmopod-wifi",
                    "passwd-file", str(password_path),
                )
            finally:
                if password_path is not None:
                    password_path.unlink(missing_ok=True)
        else:
            run("nmcli", "connection", "up", "id", "cosmopod-wifi", check=False)

    if MENDER_CONFIG.exists():
        with MENDER_CONFIG.open(encoding="utf-8") as stream:
            mender = json.load(stream)
    else:
        mender = {}

    server_url = config.get("MENDER_SERVER_URL", "").strip()
    if server_url:
        allow_insecure = config.get("ALLOW_INSECURE_MENDER", "false").lower() == "true"
        mender["ServerURL"] = validate_server_url(server_url, allow_insecure)
    token = config.get("MENDER_TENANT_TOKEN", "").strip()
    if token:
        if len(token) > 8192:
            raise ValueError("MENDER_TENANT_TOKEN is unreasonably long")
        mender["TenantToken"] = token
    atomic_json_write(MENDER_CONFIG, mender)

def main() -> int:
    config_path = next((path for path in BOOT_CONFIGS if path.is_file()), None)
    if config_path is None:
        print("Cosmopod: no cosmopod.conf on boot partition; provisioning deferred")
        return 0

    try:
        config = parse_config_text(config_path.read_text(encoding="utf-8"))
        provision(config)
        receipt = config_path.with_name("cosmopod-provisioned.txt")
        receipt.write_text("Provisioning complete. Remove this card only after clean shutdown.\n", encoding="utf-8")
        config_path.unlink()
        os.sync()
        marker = STATE_DIR / "provisioned-v1"
        marker.write_text("Cosmopod OS provisioning complete\n", encoding="utf-8")
        os.sync()
        run("systemctl", "try-restart", "mender-authd.service", "mender-updated.service", check=False)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"Cosmopod provisioning failed: {exc}", file=sys.stderr)
        return 1

    print("Cosmopod provisioning complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
