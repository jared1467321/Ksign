"""Regression coverage for the device-only LIEF logger initialization crash."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "prepare_lief_tests", ROOT / ".github/scripts/prepare_ipa_patch_lief.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class SDKPreparationTests(unittest.TestCase):
    def test_redirect_changes_only_the_default_filename_without_moving_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "libLIEF.a"
            prefix, suffix = b"archive index and relocations\0", b"\0following symbols and data"
            original = prefix + b"/tmp/lief.log\0" + suffix
            library.write_bytes(original)
            helper.patch_ios_logging(library)
            output = library.read_bytes()
            self.assertEqual(len(output), len(original))
            self.assertEqual(output, prefix + b"/dev/null\0\0\0\0\0" + suffix)
            self.assertNotIn(b"/tmp/lief.log", output)

    def test_unknown_or_duplicate_default_filename_fails_without_modification(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "libLIEF.a"
            for data in [b"unknown SDK", b"/tmp/lief.log\0" * 2]:
                with self.subTest(data=data):
                    library.write_bytes(data)
                    with self.assertRaisesRegex(RuntimeError, "review the pinned SDK"):
                        helper.patch_ios_logging(library)
                    self.assertEqual(library.read_bytes(), data)

    def prepare_fixture(self, temporary, target, *, bad_checksum=False):
        root = Path(temporary)
        archive = io.BytesIO()
        library = b"archive metadata\0/tmp/lief.log\0following object data"
        with tarfile.open(fileobj=archive, mode="w:gz") as package:
            for name, data in [("lib/libLIEF.a", library), ("include/LIEF/MachO.hpp", b"header")]:
                entry = tarfile.TarInfo("LIEF-test/" + name)
                entry.size = len(data)
                package.addfile(entry, io.BytesIO(data))
        data = archive.getvalue()
        config = root / "lief.json"
        record = {"name": "sdk.tar.gz", "sha256": "bad" if bad_checksum else hashlib.sha256(data).hexdigest()}
        config.write_text(json.dumps({"release": "https://example.invalid", "archives": {
            "ios-arm64": record, "Linux-x86_64": record}}))
        # Simulate a restored pre-fix cache. Its old stamp must not bypass the fix.
        destination = root / ".build/ipa-patch-lief" / target
        (destination / "lib").mkdir(parents=True)
        (destination / "lib/libLIEF.a").write_bytes(library)
        key = "ios-arm64" if target == "ios" else "Linux-x86_64"
        (destination / ".version").write_text(hashlib.sha256(config.read_bytes() + key.encode()).hexdigest())
        return root, config, destination, data, library

    def test_device_preparation_replaces_legacy_cache_and_reuses_fixed_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, config, destination, data, library = self.prepare_fixture(temporary, "ios")
            with mock.patch.object(helper, "ROOT", root), mock.patch.object(helper, "CONFIG", config), \
                 mock.patch.object(helper.urllib.request, "urlopen", return_value=io.BytesIO(data)) as download:
                self.assertEqual(helper.prepare("ios"), destination)
                fixed = (destination / "lib/libLIEF.a").read_bytes()
                self.assertEqual(len(fixed), len(library))
                self.assertIn(b"/dev/null\0", fixed)
                self.assertNotIn(b"/tmp/lief.log", fixed)
                self.assertEqual(helper.prepare("ios"), destination)
                self.assertEqual((destination / "lib/libLIEF.a").read_bytes(), fixed)
                download.assert_called_once()

    def test_host_sdk_is_not_modified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, config, destination, data, library = self.prepare_fixture(temporary, "host")
            with mock.patch.object(helper, "ROOT", root), mock.patch.object(helper, "CONFIG", config), \
                 mock.patch.object(helper.platform, "system", return_value="Linux"), \
                 mock.patch.object(helper.platform, "machine", return_value="x86_64"), \
                 mock.patch.object(helper.urllib.request, "urlopen", return_value=io.BytesIO(data)):
                helper.prepare("host")
                self.assertEqual((destination / "lib/libLIEF.a").read_bytes(), library)

    def test_checksum_failure_preserves_existing_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, config, destination, data, library = self.prepare_fixture(temporary, "ios", bad_checksum=True)
            with mock.patch.object(helper, "ROOT", root), mock.patch.object(helper, "CONFIG", config), \
                 mock.patch.object(helper.urllib.request, "urlopen", return_value=io.BytesIO(data)):
                with self.assertRaisesRegex(RuntimeError, "checksum"):
                    helper.prepare("ios")
                self.assertEqual((destination / "lib/libLIEF.a").read_bytes(), library)
