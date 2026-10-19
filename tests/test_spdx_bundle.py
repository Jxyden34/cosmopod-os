import copy
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "spdx_check", Path(__file__).resolve().parents[1] / "scripts/validate-spdx.py"
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def document(board="pi4"):
    return {"@graph": [
        {"type": "SpdxDocument", "name": CHECK.IMAGE_NAMES[board] + "-20260908",
         "creationInfo": {"specVersion": "3.0.1"}, "rootElement": ["urn:sbom"]},
        {"type": "software_Sbom", "spdxId": "urn:sbom"},
        {"type": "software_Package", "name": "busybox"},
    ]}


def bundle(payload, board="pi4", member_type=tarfile.REGTYPE, name=None, duplicate=False):
    stream = io.BytesIO()
    member = tarfile.TarInfo(name or CHECK.IMAGE_NAMES[board] + ".spdx.json")
    member.type = member_type
    member.linkname = "missing-timestamped.spdx.json" if member_type == tarfile.SYMTYPE else ""
    member.size = len(payload) if member_type == tarfile.REGTYPE else 0
    with tarfile.open(fileobj=stream, mode="w") as archive:
        archive.addfile(member, io.BytesIO(payload))
        if duplicate:
            archive.addfile(member, io.BytesIO(payload))
    stream.seek(0)
    return stream


class SpdxBundleTests(unittest.TestCase):
    def test_regular_document_all_boards(self):
        for board in CHECK.IMAGE_NAMES:
            with self.subTest(board=board):
                self.assertEqual(CHECK.validate_bundle(bundle(json.dumps(document(board)).encode(), board), board), 1)

    def test_links_special_files_and_duplicates_rejected(self):
        payload = json.dumps(document()).encode()
        for member_type in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.DIRTYPE):
            with self.subTest(member_type=member_type), self.assertRaises(ValueError):
                CHECK.validate_bundle(bundle(payload, member_type=member_type), "pi4")
        with self.assertRaises(ValueError):
            CHECK.validate_bundle(bundle(payload, duplicate=True), "pi4")

    def test_wrong_names_and_traversal_rejected(self):
        for name in ("../escape.spdx.json", "/escape.spdx.json", "other.spdx.json",
                     CHECK.IMAGE_NAMES["pi5"] + ".spdx.json"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                CHECK.validate_bundle(bundle(json.dumps(document()).encode(), name=name), "pi4")

    def test_empty_invalid_and_non_spdx_json_rejected(self):
        for payload in (b"", b"{", b"[]", b"{}", b'{"@graph":[]}', b'{"@graph":[null]}'):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                CHECK.validate_bundle(bundle(payload), "pi4")

    def test_incomplete_or_wrong_image_graph_rejected(self):
        valid = document()
        variants = [document("pi5")]
        for field, value in (("name", None), ("creationInfo", {}), ("rootElement", ["missing"])):
            changed = copy.deepcopy(valid)
            changed["@graph"][0][field] = value
            variants.append(changed)
        variants.extend([
            {"@graph": valid["@graph"][1:]},
            {"@graph": valid["@graph"] + [valid["@graph"][0]]},
            {"@graph": valid["@graph"][:2]},
        ])
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                CHECK.validate_bundle(bundle(json.dumps(variant).encode()), "pi4")

    def test_truncated_tar_rejected(self):
        stream = bundle(json.dumps(document()).encode())
        with self.assertRaises((ValueError, tarfile.TarError)):
            CHECK.validate_bundle(io.BytesIO(stream.getvalue()[:530]), "pi4")


if __name__ == "__main__":
    unittest.main()
