"""Keep cached app products from shipping the obsolete two-library resources."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_ipa", ROOT / ".github/scripts/package_ipa.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PatchPackagingTests(unittest.TestCase):
    def test_unified_resource_replaces_stale_cached_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            for name in ("blatantsPatch.dylib.bin", "asignIdentity.dylib.bin"):
                (app / name).write_bytes(b"old")
            data = b"AsignPatch/v1\0AsignCompatibilityPatch/v1\0AsignCloudKitPatch/v1\0@rpath/asignpatch.dylib\0"
            (app / "asignpatch.dylib.bin").write_bytes(data)
            packager.validate_patch_library(app)
            self.assertEqual([p.name for p in app.iterdir()], ["asignpatch.dylib.bin"])
            self.assertEqual((app / "asignpatch.dylib.bin").read_bytes(), data)

    def test_missing_or_incomplete_replacement_is_rejected_before_cleanup(self):
        for data in (None, b"AsignPatch/v1\0", b"AsignCompatibilityPatch/v1\0@rpath/asignpatch.dylib\0"):
            with self.subTest(data=data), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary)
                old = app / "asignIdentity.dylib.bin"
                old.write_bytes(b"old")
                if data is not None:
                    (app / "asignpatch.dylib.bin").write_bytes(data)
                with self.assertRaises(RuntimeError):
                    packager.validate_patch_library(app)
                self.assertEqual(old.read_bytes(), b"old")
