#!/usr/bin/env python3
"""Verify the isolated, hash-locked KAS runtime installed by build.sh."""

from __future__ import annotations

from importlib.metadata import distributions
from pathlib import Path
import re
import sys


EXPECTED = {
    "attrs": "26.1.0",
    "distro": "1.9.0",
    "gitdb": "4.0.12",
    "gitpython": "3.1.58",
    "jsonschema": "4.25.1",
    "jsonschema-specifications": "2025.9.1",
    "kas": "5.4",
    "pyyaml": "6.0.3",
    "referencing": "0.36.2",
    "rpds-py": "0.27.1",
    "smmap": "5.0.3",
}


def canonical_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify-kas-install.py TARGET EXPECTED_KAS_VERSION")
    target = Path(sys.argv[1]).resolve(strict=True)
    expected_kas_version = sys.argv[2]
    if expected_kas_version != EXPECTED["kas"]:
        raise SystemExit("KAS version and verifier expectation disagree")

    actual = {
        canonical_name(dist.metadata["Name"]): dist.version
        for dist in distributions(path=[str(target)])
    }
    if actual != EXPECTED:
        missing = sorted(EXPECTED.keys() - actual.keys())
        extra = sorted(actual.keys() - EXPECTED.keys())
        changed = sorted(
            name
            for name in EXPECTED.keys() & actual.keys()
            if EXPECTED[name] != actual[name]
        )
        raise SystemExit(
            f"KAS closure mismatch: missing={missing}, extra={extra}, changed={changed}"
        )

    sys.path.insert(0, str(target))
    import attrs  # noqa: F401
    import distro  # noqa: F401
    import git  # noqa: F401
    import gitdb  # noqa: F401
    import jsonschema  # noqa: F401
    import jsonschema_specifications  # noqa: F401
    import referencing  # noqa: F401
    import rpds  # noqa: F401
    import smmap  # noqa: F401
    import yaml  # noqa: F401
    from kas.__version__ import __version__

    if __version__ != expected_kas_version:
        raise SystemExit(
            f"KAS module version mismatch: {__version__} != {expected_kas_version}"
        )
    print(f"Verified isolated KAS {__version__} runtime closure")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
