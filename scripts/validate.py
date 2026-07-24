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


def check_build_supply_chain() -> None:
    build = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    lock_path = ROOT / "scripts/requirements-kas-5.4-linux-x86_64.txt"
    lock = lock_path.read_text(encoding="utf-8")
    verifier = (ROOT / "scripts/verify-kas-install.py").read_text(encoding="utf-8")

    required_build_controls = (
        "KAS_VERSION=5.4",
        "ghcr.io/siemens/kas/kas:5.4@sha256:"
        "11f076b79b84f57cb7d933941ff619f09a7c17e562e1643d13836d5f8d0a92f3",
        "KAS_CONTAINER_SCRIPT_SHA256="
        "9707355d1eba19e334e663ab9fcf6881ac323aed16ff7f4fd7e217f879a3894c",
        "kas-container wrapper checksum mismatch",
        "requirements-kas-$KAS_VERSION-linux-x86_64.txt",
        "--require-hashes",
        "--only-binary=:all:",
        "--no-deps",
        "--index-url https://pypi.org/simple",
        "kas_requirements_sha256=",
        "kas-python-$KAS_VERSION-$kas_requirements_sha256",
        "kas-wheels-$kas_requirements_sha256",
        "pip download",
        "--no-index",
        "scripts/verify-kas-install.py",
        'mv -T -- "$kas_pythonpath_tmp" "$kas_pythonpath"',
        'export PYTHONPATH="$kas_pythonpath"',
        'kas_runner=("$host_python" -S -m kas)',
        'export DL_DIR="$downloads_dir"',
        'export SSTATE_DIR="$sstate_dir"',
    )
    for marker in required_build_controls:
        if marker not in build:
            fail(f"build supply-chain control missing: {marker}")
    if "KAS_VERSION=4.8.1" in build:
        fail("known-vulnerable kas 4.8.1 must not be used")
    if ".cosmopod-tree.sha256" in build or "kas_cache_valid" in build:
        fail("writable kas installed-tree markers must not be trusted")
    if "KAS_DL_DIR=" in build or "KAS_SSTATE_DIR=" in build:
        fail("KAS 5.4 wrapper cache variables must be DL_DIR and SSTATE_DIR")

    expected_versions = {
        "attrs": "26.1.0",
        "distro": "1.9.0",
        "gitpython": "3.1.52",
        "gitdb": "4.0.12",
        "jsonschema": "4.25.1",
        "jsonschema-specifications": "2025.9.1",
        "kas": "5.4",
        "pyyaml": "6.0.3",
        "referencing": "0.36.2",
        "rpds-py": "0.27.1",
        "smmap": "5.0.3",
    }
    records = re.findall(
        r"(?ms)^([A-Za-z0-9_-]+)==([^\s\\]+)(.*?)(?=^[A-Za-z0-9_-]+==|\Z)",
        lock,
    )
    actual_versions = {name.lower(): version for name, version, _ in records}
    if actual_versions != expected_versions:
        fail("kas native dependency lock package set or versions changed")
    for name, version in expected_versions.items():
        if f'"{name}": "{version}"' not in verifier:
            fail(f"KAS closure verifier version disagrees for {name}")
    for import_name in (
        "attrs",
        "distro",
        "git",
        "gitdb",
        "jsonschema",
        "jsonschema_specifications",
        "referencing",
        "rpds",
        "smmap",
        "yaml",
    ):
        if f"import {import_name}" not in verifier:
            fail(f"KAS closure verifier does not import {import_name}")
    for name, _, continuation in records:
        if "--hash=sha256:" not in continuation:
            fail(f"kas native dependency lacks a hash: {name}")
    hashes = re.findall(r"--hash=sha256:([0-9a-f]{64})(?:\s|$)", lock)
    if len(hashes) != 21 or len(set(hashes)) != 21:
        fail("kas native dependency lock must contain 21 unique SHA-256 hashes")
    if "f63a964068c1db73075faf10185b0ab5386d6876e8ff5f28560354075e8890f1" not in hashes:
        fail("official kas 5.4 wheel hash is missing")


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
    for release_control in (".iso.xz", "xz -T0 -6 --keep --force", "2147483648"):
        if release_control not in wrapper:
            fail(f"VM exporter lacks GitHub-safe ISO control: {release_control}")
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
    initramfs_guard = (
        ROOT
        / "meta-cosmopod/recipes-core/images/core-image-minimal-initramfs.bbappend"
    ).read_text(encoding="utf-8")
    for tool in ("cat", "grep", "mkdir", "mount", "sed", "sh", "touch"):
        if tool not in initramfs_guard:
            fail(f"live initramfs executable guard is missing: {tool}")
    if "ROOTFS_POSTPROCESS_COMMAND:append" not in initramfs_guard:
        fail("live initramfs executable guard must run after rootfs assembly")
    if "readlink" not in initramfs_guard or '${IMAGE_ROOTFS}${target}' not in initramfs_guard:
        fail("live initramfs guard must resolve absolute links inside the image root")
    if "cosmopod-weston-vm.conf" not in vm_config:
        fail("VM Weston failures must remain visible on the boot console")
    weston_vm = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-vm-config/files/"
        "cosmopod-weston-vm.conf"
    ).read_text(encoding="utf-8")
    if "--renderer=pixman" not in weston_vm:
        fail("VM Weston must use its DRM-compatible software renderer")
    if "cosmopod-seatd.service" not in vm_config:
        fail("VM image must install its privileged seat broker")
    seatd_service = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-vm-config/files/"
        "cosmopod-seatd.service"
    ).read_text(encoding="utf-8")
    for seatd_control in (
        "ExecStart=/usr/bin/seatd -g wayland",
        "NoNewPrivileges=yes",
        "ProtectSystem=strict",
        "RestrictAddressFamilies=AF_UNIX",
    ):
        if seatd_control not in seatd_service:
            fail(f"VM seat broker hardening missing: {seatd_control}")
    if "Requires=cosmopod-seatd.service" not in weston_vm:
        fail("VM Weston must require its seat broker")
    kernel_append = (
        ROOT / "meta-cosmopod/recipes-kernel/linux/linux-yocto_%.bbappend"
    ).read_text(encoding="utf-8")
    kernel_fragment = (
        ROOT / "meta-cosmopod/recipes-kernel/linux/files/cosmopod-hyperv.cfg"
    ).read_text(encoding="utf-8")
    if "SRC_URI:append:genericx86-64" not in kernel_append:
        fail("Hyper-V kernel fragment must be scoped to the x86 VM")
    for kernel_control in (
        "CONFIG_HYPERVISOR_GUEST=y",
        "CONFIG_HYPERV_NET=y",
        "CONFIG_HYPERV_STORAGE=y",
        "CONFIG_HYPERV_KEYBOARD=y",
        "CONFIG_HID_HYPERV_MOUSE=y",
        "CONFIG_DRM_HYPERV=y",
        "# CONFIG_FB_HYPERV is not set",
        "CONFIG_DRM_SIMPLEDRM=y",
        "CONFIG_DRM_VIRTIO_GPU=y",
    ):
        if kernel_control not in kernel_fragment:
            fail(f"VM kernel integration missing: {kernel_control}")
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
        "COSMOPOD_PERSIST_LOG_BEGIN",
        "COSMOPOD_SMOKE_RESULT=",
    ):
        if evidence not in smoke_reporter:
            fail(f"VM smoke reporter does not capture required evidence: {evidence}")
    vm_kas = (ROOT / "kas/vm-x86_64.yml").read_text(encoding="utf-8")
    if 'APPEND:append:pn-cosmopod-image = " console=ttyS0,115200 console=tty0"' not in vm_kas:
        fail("VM ISO must expose kernel and smoke diagnostics on ttyS0")
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


def check_release_provenance() -> None:
    build = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
    common = (ROOT / "scripts/release-common.sh").read_text(encoding="utf-8")
    signer = (ROOT / "scripts/sign-release.sh").read_text(encoding="utf-8")
    validator = (ROOT / "scripts/validate-artifacts.sh").read_text(encoding="utf-8")
    required = (
        "source_commit=",
        "source_tree=",
        "source_content_sha256=",
        "source_dirty=",
        "mender_server_url=",
        "BUILD-MANIFEST.txt",
        "--allow-dirty",
        "--replace-output",
        "Release build refused: source tree is dirty",
        "Release output already exists",
        "--mender-server-url",
        'source "$script_dir/release-common.sh"',
        "release_input_paths",
        "flock --exclusive --nonblock",
        "Release source changed while the build was running",
        "build_override_vars=(",
        "KAS_MACHINE KAS_PREMIRRORS",
        "environment_sanitized=true",
        "ensure_cache_dir",
        "COSMOPOD_BUILD_ROOT must resolve under",
        "Unsafe or symlinked cache directory",
        'find . -maxdepth 1 -type f ! -name SHA256SUMS',
        "spdx.tar.zst",
        "cve_gate_as_of=",
        "BUILD-KAS-OVERLAY.yml",
        "kas_overlay_sha256=",
        '${TOPDIR}/../../downloads',
        "verify_overlay",
        "Exported KAS overlay does not match consumed configuration",
        'deploy_dir="$tmp_dir/deploy/images/$machine"',
        'evidence_image_name="cosmopod-image-$machine.rootfs"',
        'license_source="$tmp_dir/deploy/licenses/${machine//-/_}/$evidence_image_name"',
        "output_channel=development",
        "release_qualified=false",
        "Development media is unqualified",
    )
    for marker in required:
        if marker not in build:
            fail(f"release provenance/export control missing: {marker}")
    for marker in (
        "validate_https_origin",
        "git_source_fingerprint",
        "release_input_paths",
        "scripts/requirements-kas-$kas_version-linux-x86_64.txt",
        "scripts/check-cve-report.py",
        "security/cve-waivers.json",
        "65535",
    ):
        if marker not in common:
            fail(f"shared release validation missing: {marker}")
    for marker in (
        "BUILD-MANIFEST.txt",
        "source_dirty=false",
        "environment_sanitized=true",
        "cosmopod-signing-record-v2",
        "Unsigned artifact unexpectedly passed",
        "wrong-key validation",
        "--approve-server-url",
        "--approve-build-index-sha256",
        "--approve-unsigned-sha256",
        "cp --archive --reflink=auto",
        "SHA256SUMS.sig",
        "release_index_authenticated=true",
        "Recorded CVE gate evidence does not reproduce from trusted inputs",
        "Release directory does not match the approved unsigned Pi file set",
        "KAS overlay does not reproduce from recorded build inputs",
        "spdx_bundle_sha256=",
    ):
        if marker not in signer:
            fail(f"offline signing evidence gate missing: {marker}")
    for marker in (
        "validate_security_evidence",
        "spdx.tar.zst",
        "scripts/check-cve-report.py",
        "security/cve-waivers.json",
        "Recorded CVE gate evidence does not reproduce from trusted inputs",
        "Release directory does not match the approved unsigned file set",
        "KAS overlay does not reproduce from recorded build inputs",
        "Signed Pi release sidecars are incomplete",
        "validate_checksum_index",
        "SHA256SUMS.sig",
        "SPDX archive contains no SPDX JSON document",
        "database_fresh=true",
        'validate "$signed" -k "$public"',
    ):
        if marker not in validator:
            fail(f"artifact security evidence validation missing: {marker}")


def check_release_security_evidence() -> None:
    common = (ROOT / "kas/common.yml").read_text(encoding="utf-8")
    gate = (ROOT / "scripts/check-cve-report.py").read_text(encoding="utf-8")
    keygen = (ROOT / "scripts/generate-signing-key.sh").read_text(encoding="utf-8")
    waivers = (ROOT / "security/cve-waivers.json").read_text(encoding="utf-8")
    for marker in (
        'INHERIT += "create-spdx cve-check"',
        'CVE_CHECK_CREATE_MANIFEST = "1"',
        'CVE_CHECK_MANIFEST_JSON_SUFFIX = "cve.json"',
        'COPY_LIC_MANIFEST = "1"',
        'COPY_LIC_DIRS = "1"',
    ):
        if marker not in common:
            fail(f"Yocto release evidence control missing: {marker}")
    for marker in (
        "BLOCKING_SCORE = 7.0",
        'status in ("Unpatched", "Unknown")',
        "expired_waivers",
        "tracking_url",
        "report_sha256",
        "database_age_seconds",
        "database_fresh=true",
        "CVE database is stale",
    ):
        if marker not in gate:
            fail(f"CVE release gate control missing: {marker}")
    if '"format": "cosmopod-cve-waivers-v1"' not in waivers:
        fail("CVE waiver file has wrong format")
    for marker in ("-algorithm EC", "ec_paramgen_curve:P-256"):
        if marker not in keygen:
            fail("key generator must create ECDSA P-256 keys")


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
    pseudo = (
        ROOT / "meta-cosmopod/recipes-devtools/pseudo/pseudo_%.bbappend"
    ).read_text(encoding="utf-8")
    if 'PV = "1.9.8"' not in pseudo:
        fail("pseudo must include stable symlink fixes from 1.9.8")
    if "823895ba708c63f6ae4dcbfc266210f26c02c698" not in pseudo:
        fail("pseudo 1.9.8 must be pinned by full source revision")
    pseudo_openat2 = ROOT / (
        "meta-cosmopod/recipes-devtools/pseudo/files/"
        "0001-openat2-fallback-to-enosys.patch"
    )
    if not pseudo_openat2.is_file():
        fail("pseudo openat2 ENOSYS fallback patch is missing")
    fallback = pseudo_openat2.read_text(encoding="utf-8")
    if "errno = ENOSYS" not in fallback or "return -1" not in fallback:
        fail("pseudo openat2 fallback must return ENOSYS")
    if "mainpath, mainpath" not in fallback or "&& pseudo_client_ignore_path" not in fallback:
        fail("pseudo preserved-path wrapper must handle failed canonicalization")
    wpa = ROOT / (
        "meta-cosmopod/recipes-connectivity/wpa-supplicant/"
        "wpa-supplicant_%.bbappend"
    )
    if not wpa.is_file() or 'PARALLEL_MAKEINST = ""' not in wpa.read_text(
        encoding="utf-8"
    ):
        fail("wpa-supplicant install must be serialized to avoid directory races")
    opkg = ROOT / (
        "meta-cosmopod/recipes-devtools/opkg-utils/opkg-utils_%.bbappend"
    )
    opkg_patch = ROOT / (
        "meta-cosmopod/recipes-devtools/opkg-utils/files/"
        "0001-update-alternatives-avoid-tail-pipeline.patch"
    )
    if not opkg.is_file() or not opkg_patch.is_file():
        fail("native update-alternatives host compatibility patch is missing")
    if "SRC_URI:append:class-native" not in opkg.read_text(encoding="utf-8"):
        fail("update-alternatives host compatibility patch must be native-only")
    alternatives_fix = opkg_patch.read_text(encoding="utf-8")
    added_lines = [
        line for line in alternatives_fix.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    ]
    if any("tail -n 1" in line for line in added_lines) or not any(
        "sed -n '$s/ [^ ]*$//p'" in line for line in added_lines
    ):
        fail("update-alternatives must select the final provider without tail")


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
    persist_unit = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-config/files/"
        "cosmopod-persist.service"
    ).read_text(encoding="utf-8")
    persist_script = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-config/files/cosmopod-persist.sh"
    ).read_text(encoding="utf-8")
    config_recipe = (
        ROOT
        / "meta-cosmopod/recipes-core/cosmopod-config/cosmopod-config_1.0.bb"
    ).read_text(encoding="utf-8")

    if "After=data.mount local-fs.target sshdgenkeys.service" not in persist_unit:
        fail("persistent setup must run after OpenSSH host-key generation")
    if (
        "Before=cosmopod-persist.service" not in config_recipe
        or "sshdgenkeys.service.d" not in config_recipe
    ):
        fail("OpenSSH host-key generator must precede persistent setup")
    if "ssh-keygen -q -t" in persist_script or "ssh-keygen -y -f" not in persist_script:
        fail("persistent setup must validate SSH keys without racing their generator")

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
        check_build_supply_chain,
        check_distro_identity,
        check_vm_image_scoping,
        check_board_package_scoping,
        check_release_provenance,
        check_release_security_evidence,
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
