#!/usr/bin/env python3
"""Fast repository checks that do not require a Yocto build."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    raise AssertionError(message)


def check_pins() -> None:
    text = (ROOT / "kas/common.yml").read_text(encoding="utf-8")
    commits = re.findall(r"^\s+commit:\s+([0-9a-f]+)\s*$", text, re.MULTILINE)
    if len(commits) < 7:
        fail("kas/common.yml must pin every upstream repository")
    if any(len(commit) != 40 for commit in commits):
        fail("all kas commit pins must be full 40-character SHAs")
    if re.search(r"^\s+(branch|refspec):", text, re.MULTILINE):
        fail("floating branch/refspec found in reproducible kas config")


def check_distro_identity() -> None:
    kas = (ROOT / "kas/common.yml").read_text(encoding="utf-8")
    distro = (ROOT / "meta-cosmopod/conf/distro/cosmopod.conf").read_text(
        encoding="utf-8"
    )
    if not re.search(r"^distro:\s+cosmopod\s*$", kas, re.MULTILINE):
        fail("KAS must select the cosmopod distro")
    if not re.search(r'^DISTRO\s*=\s*"cosmopod"\s*$', distro, re.MULTILINE):
        fail("cosmopod.conf must restore DISTRO after requiring poky.conf")
    if not re.search(
        r'^DISTROOVERRIDES\s*=\s*"poky:cosmopod"\s*$', distro, re.MULTILINE
    ):
        fail("cosmopod.conf must preserve poky and cosmopod overrides")


def check_vm_image_scoping() -> None:
    text = (ROOT / "kas/vm-x86_64.yml").read_text(encoding="utf-8")
    for variable in ("IMAGE_FSTYPES:append", "IMAGE_INSTALL:append"):
        if re.search(rf"^\s+{re.escape(variable)}\s*=", text, re.MULTILINE):
            fail(f"{variable} must be scoped to pn-cosmopod-image")
        if not re.search(
            rf"^\s+{re.escape(variable)}:pn-cosmopod-image\s*=", text, re.MULTILINE
        ):
            fail(f"missing scoped {variable} for the VM image")
    wks = (ROOT / "meta-cosmopod/wic/cosmopod-vm.wks").read_text(encoding="utf-8")
    if "${" in wks or 'loader=grub-efi' not in wks:
        fail("VM WKS must use an explicit Wic EFI loader")
    if not re.search(r"part /data .*--fsoptions=\"[^\"]*nodev[^\"]*nosuid", wks):
        fail("persistent VM /data partition must disable device and set-ID files")
    wrapper = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    for suffix in ("rootfs.iso", "rootfs.wic.qcow2"):
        if f"cosmopod-image-$machine.{suffix}" not in wrapper:
            fail(f"VM exporter must use Yocto's {suffix} deploy symlink")
    vm_config = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-vm-config/cosmopod-vm-config_1.0.bb"
    ).read_text(encoding="utf-8")
    if "install -d -m 0755 ${D}/data" not in vm_config:
        fail("VM image must pre-create /data for its read-only live ISO root")
    image_recipe = (
        ROOT / "meta-cosmopod/recipes-core/images/cosmopod-image.bb"
    ).read_text(encoding="utf-8")
    if (
        "ROOTFS_POSTPROCESS_COMMAND:append:genericx86-64" not in image_recipe
        or "/media/boot-sr0" not in image_recipe
    ):
        fail("VM image must pre-create live optical-media mount point")
    if "cosmopod-vm-remount-condition" not in vm_config:
        fail("VM image must skip root remount only when live root is read-only")
    if "cosmopod-weston-vm.conf" not in vm_config:
        fail("VM Weston failures must remain visible on the boot console")
    for smoke_file in (
        "cosmopod-vm-smoke-condition",
        "cosmopod-vm-smoke",
        "cosmopod-vm-smoke.service",
    ):
        if smoke_file not in vm_config:
            fail(f"VM image must install fixed smoke reporter file: {smoke_file}")
    smoke_condition = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-vm-config/files/"
        "cosmopod-vm-smoke-condition"
    ).read_text(encoding="utf-8")
    smoke_reporter = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-vm-config/files/cosmopod-vm-smoke"
    ).read_text(encoding="utf-8")
    smoke_host = (ROOT / "scripts/smoke-vm.sh").read_text(encoding="utf-8")
    for marker in ("COSMOPOD-SMOKE-ISO", "COSMOPOD-SMOKE-QCOW2"):
        if marker not in smoke_condition or marker not in smoke_host:
            fail(f"VM smoke activation marker missing: {marker}")
    for evidence in (
        "sshd -T",
        "boot.serial-console",
        "weston.socket",
        "mount.data",
        "persistence.state",
        "wayland-info",
        "drm.connected-output",
        "weston.stable",
        "COSMOPOD_SMOKE_SCREENSHOT_READY",
        "COSMOPOD_WESTON_LOG_BEGIN",
        "COSMOPOD_SMOKE_RESULT=",
    ):
        if evidence not in smoke_reporter:
            fail(f"VM smoke reporter does not capture required evidence: {evidence}")
    for host_control in (
        "-cpu max",
        "-smbios",
        "-drive",
        "readonly=on",
        "q35,accel=tcg",
        "-vga none",
        "restrict=on",
        "hostfwd=tcp:127.0.0.1",
        "sendkey down",
        "sendkey ret",
        "qmp_screendump",
        "validate_ppm",
        "ssh-keyscan",
        "detect_image_format",
        "check_qcow2_persistence",
        "qcow2.boot1",
        "qcow2.boot2",
        "COSMOPOD_QEMU_KEYMAP",
    ):
        if host_control not in smoke_host:
            fail(f"VM smoke host lacks required QEMU control: {host_control}")
    if re.search(r"\bread\b", smoke_reporter):
        fail("fixed VM smoke reporter must not accept interactive guest commands")
    nfs_append = (
        ROOT / "meta-cosmopod/recipes-connectivity/nfs-utils/nfs-utils_%.bbappend"
    ).read_text(encoding="utf-8")
    if "sysinit.target.wants/proc-fs-nfsd.mount" not in nfs_append:
        fail("disabled NFS server must not mount NFSD during normal boot")


def check_board_package_scoping() -> None:
    common = (ROOT / "kas/common.yml").read_text(encoding="utf-8")
    if "kernel-devicetree" in common:
        fail("kernel-devicetree is Pi-only and must not leak into VM config")
    for board in ("raspberrypi4.yml", "raspberrypi5.yml"):
        text = (ROOT / "kas" / board).read_text(encoding="utf-8")
        if not re.search(
            r'^\s+IMAGE_INSTALL:append:pn-cosmopod-image\s*=\s*" kernel-devicetree"$',
            text,
            re.MULTILINE,
        ):
            fail(f"{board} must install its device trees in the product image")


def check_host_compatibility_patches() -> None:
    recipes = {
        "Mesa": (
            "meta-cosmopod/recipes-graphics/mesa/mesa_%.bbappend",
            "files/0001-c11-threads-fix-build-on-c23.patch",
        ),
        "virglrenderer": (
            "meta-cosmopod/recipes-graphics/virglrenderer/virglrenderer_%.bbappend",
            "files/0001-c11-use-glibc-once-flag.patch",
        ),
    }
    for name, (append_name, patch_name) in recipes.items():
        append = ROOT / append_name
        patch = append.parent / patch_name
        if not append.is_file() or not patch.is_file():
            fail(f"{name} glibc 2.43 compatibility backport is missing")
        if "SRC_URI:append:class-native" not in append.read_text(encoding="utf-8"):
            fail(f"{name} host compatibility patch must be native-only")
        if "__once_flag_defined" not in patch.read_text(encoding="utf-8"):
            fail(f"{name} compatibility patch does not guard system once_flag")


def check_product_features() -> None:
    common = (ROOT / "kas/common.yml").read_text(encoding="utf-8")
    distro = (ROOT / "meta-cosmopod/conf/distro/cosmopod.conf").read_text(
        encoding="utf-8"
    )
    packagegroup = (
        ROOT / "meta-cosmopod/recipes-core/packagegroups/packagegroup-cosmopod.bb"
    ).read_text(encoding="utf-8")
    sshd = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-config/files/50-cosmopod-sshd.conf"
    ).read_text(encoding="utf-8")
    mender = (
        ROOT / "meta-cosmopod/recipes-mender/mender/mender_%.bbappend"
    ).read_text(encoding="utf-8")

    if 'MENDER_SERVER_URL ?= "https://kys.dpdns.org"' not in common:
        fail("default Mender server must be https://kys.dpdns.org")
    if (
        'MENDER_PERSISTENT_CONFIGURATION_VARS:append = " ServerURL TenantToken"'
        not in common
    ):
        fail("Mender server and tenant selection must survive A/B updates")
    for recipe in ("nfs-utils", "rpcbind"):
        if f'SYSTEMD_AUTO_ENABLE:pn-{recipe} = "disable"' not in common:
            fail(f"{recipe} network daemons must be disabled by default")
    if "wayland" not in distro or re.search(
        r'^DISTRO_FEATURES:remove = "[^"]*x11', distro, re.MULTILINE
    ) is None:
        fail("Cosmopod distro must enable Wayland and remove X11")

    required_packages = {
        "openssh",
        "networkmanager",
        "nftables",
        "weston",
        "wayland-utils",
        "git",
        "curl",
        "python3",
        "gcc",
        "g++",
        "make",
        "cmake",
        "vim",
        "nano",
        "tmux",
        "htop",
        "nmap",
        "tcpdump",
    }
    words = set(re.findall(r"[A-Za-z0-9+_.-]+", packagegroup))
    missing = sorted(required_packages - words)
    if missing:
        fail(f"useful package set is missing: {', '.join(missing)}")

    required_sshd = {
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "PermitRootLogin no",
        "PermitEmptyPasswords no",
        "PubkeyAuthentication yes",
        "AuthenticationMethods publickey",
        "AllowUsers cosmopod",
    }
    ssh_lines = {
        line.strip()
        for line in sshd.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    missing_sshd = sorted(required_sshd - ssh_lines)
    if missing_sshd:
        fail(f"SSH public-key-only policy is missing: {', '.join(missing_sshd)}")

    if "artifact-verify-key.pem" not in mender:
        fail("Mender public artifact verification key is not installed")


def check_no_private_key() -> None:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    prefix = b"-----BEGIN "
    markers = tuple(
        prefix + (kind + b" " if kind else b"") + b"PRIVATE KEY-----"
        for kind in (b"", b"RSA", b"EC", b"DSA", b"OPENSSH")
    )
    for relative in filter(None, result.stdout.split(b"\0")):
        path = ROOT / relative.decode("utf-8")
        if not path.is_file():
            continue
        content = path.read_bytes()
        if any(marker in content for marker in markers):
            fail(f"private key leaked into source: {path.relative_to(ROOT)}")


def check_firstboot_module() -> None:
    path = ROOT / "meta-cosmopod/recipes-core/cosmopod-config/files/cosmopod-firstboot.py"
    spec = importlib.util.spec_from_file_location("cosmopod_firstboot", path)
    if spec is None or spec.loader is None:
        fail("could not load firstboot module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    parsed = module.parse_config_text("COSMOPOD_HOSTNAME=pod-1\nWIFI_PASSWORD=$(touch /tmp/nope)\n")
    if parsed["WIFI_PASSWORD"] != "$(touch /tmp/nope)":
        fail("firstboot parser must treat shell syntax as inert data")
    for bad in ("NOPE=value", "COSMOPOD_HOSTNAME", "COSMOPOD_HOSTNAME=a\nCOSMOPOD_HOSTNAME=b"):
        try:
            module.parse_config_text(bad)
        except ValueError:
            pass
        else:
            fail(f"firstboot parser accepted invalid config: {bad!r}")


def check_python_syntax() -> None:
    paths = list(ROOT.rglob("*.py"))
    result = subprocess.run(
        [sys.executable, "-m", "py_compile", *map(str, paths)],
        text=True,
        capture_output=True,
    )
    if result.returncode:
        fail(result.stderr.strip())


def main() -> int:
    checks = (
        check_pins,
        check_distro_identity,
        check_vm_image_scoping,
        check_board_package_scoping,
        check_host_compatibility_patches,
        check_product_features,
        check_no_private_key,
        check_firstboot_module,
        check_python_syntax,
    )
    for check in checks:
        check()
        print(f"PASS {check.__name__}")
    print(f"PASS {len(checks)} repository checks")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        raise SystemExit(1)
