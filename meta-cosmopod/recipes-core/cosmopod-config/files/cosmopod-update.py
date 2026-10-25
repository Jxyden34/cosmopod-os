#!/usr/bin/env python3
"""Install signed public Pi releases with Mender's standalone A/B installer."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REPOSITORY = "Jxyden34/cosmopod-os"
STATE = Path("/data/cosmopod")
KEY = Path("/etc/mender/artifact-verify-key.pem")
DEVICE_TYPE = Path("/var/lib/mender/device_type")
OS_RELEASE = Path("/etc/os-release")
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
MENDER = "/usr/bin/mender-update"
CONFIG = Path("/etc/mender/mender.conf")
PERSISTENT_CONFIG = Path("/data/mender/mender.conf")
UNITS = Path("/etc/systemd/system")
DEVICES = {"cosmopod-rpi4-64": "pi4", "cosmopod-rpi5": "pi5"}


def version_tuple(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("Expected a stable version such as 1.0.0")
    return tuple(map(int, value.split(".")))


def device_board():
    if not DEVICE_TYPE.is_file():
        raise ValueError("This image has no Pi A/B update layout; VM media must be replaced separately")
    device = DEVICE_TYPE.read_text().strip()
    if device.startswith("device_type="):
        device = device.removeprefix("device_type=")
    if device not in DEVICES:
        raise ValueError("Unsupported Mender device type")
    return DEVICES[device]


def installed_version():
    values = dict(line.split("=", 1) for line in OS_RELEASE.read_text().splitlines()
                  if "=" in line and not line.startswith("#"))
    if values.get("ID", "").strip('"') != "cosmopod":
        raise ValueError("This is not a Cosmopod OS image")
    value = values["VERSION_ID"].strip('"').removesuffix("-dev")
    version_tuple(value)
    return value


def run(*args):
    subprocess.run(args, check=True)


def download(url, destination, limit):
    # No bearer tokens or user-controlled URLs; redirects must also use TLS.
    run("curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--max-redirs", "5",
        "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15",
        "--max-time", "1800", "--max-filesize", str(limit),
        "--output", str(destination), url)
    if not 0 < destination.stat().st_size <= limit:
        raise ValueError("Download is empty or exceeds the size limit")


def release_version(requested=None):
    if requested:
        version_tuple(requested)
        return requested
    with tempfile.TemporaryDirectory(prefix="cosmopod-release-") as directory:
        metadata = Path(directory) / "release.json"
        download(f"https://api.github.com/repos/{REPOSITORY}/releases/latest", metadata, 1048576)
        release = json.loads(metadata.read_text())
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("Latest release is not a published stable release")
    tag = release.get("tag_name", "")
    if not isinstance(tag, str) or not tag.startswith("v"):
        raise ValueError("Release tag must be vVERSION")
    version_tuple(tag[1:])
    return tag[1:]


def artifact_digest(index, filename):
    entries = {}
    for line in index.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (?:\./)?([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
        if not match or match[2] in entries:
            raise ValueError("Malformed or duplicate signed checksum entry")
        entries[match[2]] = match[1]
    if filename not in entries:
        raise ValueError("Signed index does not contain this board's update")
    return entries[filename]


def verify_configuration():
    config = json.loads(CONFIG.read_text())
    if PERSISTENT_CONFIG.exists():
        config.update(json.loads(PERSISTENT_CONFIG.read_text()))
    if config.get("ArtifactVerifyKey") != str(KEY) or config.get("ArtifactVerifyKeys") or not KEY.is_file():
        raise ValueError("Mender artifact-signature verification is not configured")
    for unit in ("mender-updated.service", "mender-authd.service"):
        mask = UNITS / unit
        if not mask.is_symlink() or os.readlink(mask) != "/dev/null":
            raise ValueError("Managed Mender services must be masked for standalone updates")


def save_pending(record):
    target = STATE / "update.json"
    with tempfile.NamedTemporaryFile(mode="w", dir=STATE, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(record, stream)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, target)
            directory = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


def install_release(version, board):
    if version_tuple(version) <= version_tuple(installed_version()):
        raise ValueError("Refusing a same-version update or downgrade")
    if (STATE / "update.json").exists():
        raise ValueError("An update is already pending; inspect status before recovery")
    filename = f"Cosmopod-OS-{version}-{board}.mender"
    base = f"https://github.com/{REPOSITORY}/releases/download/v{version}"
    with tempfile.TemporaryDirectory(prefix="update-", dir=STATE) as directory:
        directory = Path(directory)
        # Each board has its own signed index; release asset names must be unique.
        index = directory / "SHA256SUMS"
        signature = directory / "SHA256SUMS.sig"
        download(f"{base}/SHA256SUMS-{board}", index, 1048576)
        download(f"{base}/SHA256SUMS-{board}.sig", signature, 16384)
        run("openssl", "dgst", "-sha256", "-verify", str(KEY),
            "-signature", str(signature), str(index))
        digest = artifact_digest(index.read_text(), filename)
        limit = min(1073741824, shutil.disk_usage(STATE).free - 67108864)
        if limit <= 0:
            raise ValueError("Insufficient space on /data for an update")
        artifact = directory / filename
        download(f"{base}/{filename}", artifact, limit)
        with artifact.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
                raise ValueError("Downloaded artifact does not match the signed checksum")
        # Persist intent before touching slots so interrupted installs are visible.
        pending = {"version": version, "board": board,
                   "boot_id": BOOT_ID.read_text().strip(), "state": "installing"}
        save_pending(pending)
        run(MENDER, "install", str(artifact))
        pending["state"] = "awaiting-reboot"
        save_pending(pending)
    print("Installed, not committed. Reboot, reconnect over SSH, then run sudo cosmopod-update commit.")
    print("If the new system is unhealthy, do not commit; use rollback and reboot.")


def finish_update(action, board):
    pending = json.loads((STATE / "update.json").read_text())
    if pending.get("board") != board:
        raise ValueError("Pending update belongs to another device type")
    if action == "commit":
        if pending.get("state") != "awaiting-reboot" or pending.get("boot_id") == BOOT_ID.read_text().strip():
            raise ValueError("Reboot into the new OS before committing")
        if pending.get("version") != installed_version():
            raise ValueError("Running version does not match the pending update; rollback may have occurred")
    # Mender executes ArtifactCommit health scripts before accepting a commit.
    run(MENDER, action)
    (STATE / "update.json").unlink()
    os.sync()
    print("Update committed." if action == "commit" else "Rollback requested. Reboot to the previous OS.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "install", "status", "commit", "rollback"))
    parser.add_argument("--version", help="explicit stable version; otherwise use the latest public release")
    args = parser.parse_args(argv)
    if args.version and args.action not in ("check", "install"):
        parser.error("--version is only valid for check/install")
    try:
        board = device_board()
        if args.action == "check":
            version = release_version(args.version)
            current = installed_version()
            print(f"Board: {board}; installed: {current}; release: {version}")
            print("Update available." if version_tuple(version) > version_tuple(current) else "No newer stable release.")
            return 0
        if args.action == "status":
            print(f"Board: {board}; installed: {installed_version()}")
            if os.geteuid() != 0:
                print("Run sudo cosmopod-update status to inspect the private update journal.")
                return 0
            path = STATE / "update.json"
            print(path.read_text() if path.exists() else "No wrapper-managed update pending.")
            return 0
        if os.geteuid() != 0:
            raise ValueError("Run install/commit/rollback with sudo")
        if not os.path.ismount("/data") or not STATE.is_dir():
            raise ValueError("Persistent /data must be mounted and initialized")
        if STATE.stat().st_uid != 0 or STATE.stat().st_mode & 0o077:
            raise ValueError("/data/cosmopod must be root-owned and mode 0700")
        verify_configuration()
        descriptor = os.open(STATE / "update.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.action == "install":
                install_release(release_version(args.version), board)
            else:
                finish_update(args.action, board)
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Cosmopod update failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
