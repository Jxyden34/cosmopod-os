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
    wrapper = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    for suffix in ("rootfs.iso", "rootfs.wic.qcow2"):
        if f"cosmopod-image-$machine.{suffix}" not in wrapper:
            fail(f"VM exporter must use Yocto's {suffix} deploy symlink")


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
