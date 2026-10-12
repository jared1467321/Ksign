"""Regression checks for IPA packaging; run with python3 on Linux or macOS."""
import importlib.util
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("package_ipa", Path(__file__).with_name("package_ipa.py"))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def bundle(self, path, name, mode=0o755):
        path.mkdir(parents=True)
        (path / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name}))
        # Only the Mach-O header is needed for the packaging format check;
        # codesign is mocked because it requires macOS and a complete binary.
        (path / name).write_bytes(bytes.fromhex("cffaedfe") + bytes(28))
        (path / name).chmod(mode)

    def test_read_only_framework_is_writable_in_single_ipa(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ASign.app"
            self.bundle(app, "ASign")
            self.bundle(app / "PlugIns/KsignDeviceTunnel.appex", "KsignDeviceTunnel")
            self.bundle(app / "Frameworks/OpenSSL.framework", "OpenSSL", mode=0o555)
            (app / "resource.txt").write_text("resource")
            (app / "resource.txt").chmod(0o644)
            output = root / "packages"
            output.mkdir()
            real_run = subprocess.run
            signed = []

            def run(args, **kwargs):
                if args[0] == "codesign":
                    signed.append(Path(args[-1]).name)
                    return subprocess.CompletedProcess(args, 0)
                return real_run(args, **kwargs)

            with patch.object(packaging.subprocess, "run", side_effect=run):
                packaging.package(app, output)
            self.assertEqual([p.name for p in output.iterdir()], ["ASign.ipa"])
            with zipfile.ZipFile(output / "ASign.ipa") as archive:
                entry = archive.getinfo("Payload/ASign.app/Frameworks/OpenSSL.framework/OpenSSL")
                self.assertEqual(stat.S_IMODE(entry.external_attr >> 16), 0o755)
                self.assertEqual(archive.read(entry)[:4], bytes.fromhex("cffaedfe"))
                self.assertIn("Payload/ASign.app/PlugIns/KsignDeviceTunnel.appex/KsignDeviceTunnel", archive.namelist())
                resource = archive.getinfo("Payload/ASign.app/resource.txt")
                self.assertEqual(stat.S_IMODE(resource.external_attr >> 16), 0o644)
            self.assertEqual((app / "Frameworks/OpenSSL.framework/OpenSSL").stat().st_mode & 0o777, 0o555)
            self.assertIn("OpenSSL.framework", signed)
            self.assertEqual(signed[-1], "ASign.app")

    def test_invalid_framework_stops_packaging_before_codesign(self):
        with tempfile.TemporaryDirectory() as temporary:
            framework = Path(temporary) / "OpenSSL.framework"
            self.bundle(framework, "OpenSSL")
            (framework / "OpenSSL").write_bytes(b"not a binary")
            with self.assertRaisesRegex(RuntimeError, "not Mach-O"):
                packaging.validate_executables([framework])

    def test_read_only_executable_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            framework = Path(temporary) / "OpenSSL.framework"
            self.bundle(framework, "OpenSSL", mode=0o555)
            with self.assertRaisesRegex(RuntimeError, "read-only"):
                packaging.validate_executables([framework])


if __name__ == "__main__":
    unittest.main()
