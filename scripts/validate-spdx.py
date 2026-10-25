#!/usr/bin/env python3
"""Check Cosmopod's single-document Yocto SPDX 3 export from an uncompressed tar.

This checks the release payload contract, not full SPDX schema conformance.
Nothing is extracted to disk. The caller decompresses with zstd and pipefail.
"""

import argparse
import json
import sys
import tarfile


IMAGE_NAMES = {
    "pi4": "cosmopod-image-cosmopod-rpi4-64",
    "pi5": "cosmopod-image-cosmopod-rpi5",
    "vm": "cosmopod-image-genericx86-64.rootfs",
}
MAX_DOCUMENT_BYTES = 256 * 1024 * 1024


def validate_bundle(stream, board):
    image_name = IMAGE_NAMES[board]
    count = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            count += 1
            if count != 1 or member.name != image_name + ".spdx.json":
                raise ValueError("expected exactly one board-matched SPDX JSON member")
            if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or member.sparse:
                raise ValueError("SPDX member must be a regular file, not a link or special file")
            if not 0 < member.size <= MAX_DOCUMENT_BYTES:
                raise ValueError("SPDX document is empty or exceeds the 256 MiB limit")
            with archive.extractfile(member) as payload:
                document = json.load(payload)
            if not isinstance(document, dict) or not isinstance(document.get("@graph"), list):
                raise ValueError("SPDX document must contain a JSON-LD graph")
            graph = document["@graph"]
            if not graph or not all(isinstance(element, dict) for element in graph):
                raise ValueError("SPDX graph is empty or contains invalid elements")
            roots = [element for element in graph if element.get("type") == "SpdxDocument"]
            if len(roots) != 1:
                raise ValueError("SPDX graph must contain exactly one SpdxDocument")
            root = roots[0]
            name = root.get("name", "")
            if not isinstance(name, str) or not (name == image_name or name.startswith(image_name + "-")):
                raise ValueError("SPDX document identifies the wrong image")
            creation = root.get("creationInfo")
            if not isinstance(creation, dict) or creation.get("specVersion") != "3.0.1":
                raise ValueError("SPDX document is not the expected Yocto SPDX 3.0.1 export")
            sbom_ids = {
                element.get("spdxId") for element in graph
                if element.get("type") == "software_Sbom" and isinstance(element.get("spdxId"), str)
            }
            root_ids = root.get("rootElement")
            if not isinstance(root_ids, list) or not any(
                isinstance(root_id, str) and root_id in sbom_ids for root_id in root_ids
            ):
                raise ValueError("SPDX document has no resolvable software SBOM root")
            packages = sum(element.get("type") == "software_Package" for element in graph)
            if not packages:
                raise ValueError("SPDX graph contains no software packages")
    if count != 1:
        raise ValueError("SPDX archive contains no SPDX JSON document")
    return packages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", choices=IMAGE_NAMES, required=True)
    args = parser.parse_args()
    try:
        packages = validate_bundle(sys.stdin.buffer, args.board)
    except (ValueError, tarfile.TarError, OSError, EOFError) as error:
        print(f"SPDX validation failed: {error}", file=sys.stderr)
        return 1
    print(f"SPDX payload PASS: {args.board}, {packages} software packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
