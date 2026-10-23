"""Regression checks for renamed extensions left in cached Xcode products."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_ipa", ROOT / ".github/scripts/package_ipa.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class CachedExtensionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Asign.app"
        self.app.mkdir()

    def extension(self, name, identifier):
        extension = self.app / "PlugIns" / name
        extension.mkdir(parents=True)
        (extension / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        return extension

    def test_cached_old_extensions_are_removed_and_new_ones_are_kept(self):
        # This reproduces build 316: two old/new pairs shared their bundle IDs.
        expected = set()
        for stem, suffix in (("DeviceTunnel", "DeviceTunnel"), ("LiveActivity", "LiveActivity")):
            identifier = "test.asign." + suffix
            self.extension("Ksign" + stem + ".appex", identifier)
            expected.add(self.extension("Asign" + stem + ".appex", identifier).name)
        (self.app / "ksign_extension.png").write_bytes(b"old icon")
        (self.app / "asign_extension.png").write_bytes(b"new icon")
        with self.assertRaisesRegex(RuntimeError, "Duplicate extension"):
            packager.validate_extension_identifiers(self.app)
        packager.remove_obsolete_branding(self.app)
        packager.validate_extension_identifiers(self.app)
        self.assertEqual({p.name for p in (self.app / "PlugIns").iterdir()}, expected)
        self.assertFalse((self.app / "ksign_extension.png").exists())
        self.assertEqual((self.app / "asign_extension.png").read_bytes(), b"new icon")
        # Packaging the same clean bundle again is harmless.
        packager.remove_obsolete_branding(self.app)
        packager.validate_extension_identifiers(self.app)

    def test_missing_replacement_preserves_old_extension_and_rejects_package(self):
        old = self.extension("KsignDeviceTunnel.appex", "test.asign.DeviceTunnel")
        with self.assertRaisesRegex(RuntimeError, "without its replacement"):
            packager.remove_obsolete_branding(self.app)
        self.assertTrue(old.is_dir())

    def test_different_identity_is_not_silently_removed(self):
        old = self.extension("KsignDeviceTunnel.appex", "test.other.DeviceTunnel")
        self.extension("AsignDeviceTunnel.appex", "test.asign.DeviceTunnel")
        with self.assertRaisesRegex(RuntimeError, "different identity"):
            packager.remove_obsolete_branding(self.app)
        self.assertTrue(old.is_dir())

    def test_unexpected_duplicate_extensions_reject_package(self):
        self.extension("AsignDeviceTunnel.appex", "test.asign.DeviceTunnel")
        self.extension("UnexpectedTunnel.appex", "test.asign.DeviceTunnel")
        packager.remove_obsolete_branding(self.app)
        with self.assertRaisesRegex(RuntimeError, "Duplicate extension"):
            packager.validate_extension_identifiers(self.app)

    def test_unrelated_extension_is_preserved(self):
        extension = self.extension("Share.appex", "test.asign.Share")
        packager.remove_obsolete_branding(self.app)
        packager.validate_extension_identifiers(self.app)
        self.assertTrue(extension.is_dir())


if __name__ == "__main__":
    unittest.main()
