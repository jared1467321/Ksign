#!/usr/bin/env python3
"""Verify native cache invalidation and reuse without Rust, Xcode, or downloads."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("build_device_native.py")
spec = importlib.util.spec_from_file_location("build_device_native", SCRIPT)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ksign-native-cache-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        config = self.root / "Native/Device"
        config.mkdir(parents=True)
        (config / "source.json").write_text(json.dumps({
            "revision": "pinned-revision", "sha256": "pinned-checksum", "rust_toolchain": "1.99.0",
        }))
        (config / "ksign_pairing.rs").write_text("pub fn pair() {}\n")
        builder = self.root / "build_device_native.py"
        builder.write_bytes(SCRIPT.read_bytes())
        for name, value in {
            "CONFIG": config, "WORK": self.root / "work",
            "OUTPUT": self.root / "IDevice.xcframework", "__file__": str(builder),
        }.items():
            patcher = patch.object(native, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.xcode_version = b"Xcode 26.6\nBuild version 17F42\n"
        self.rust_version = b"rustc 1.99.0 (pinned-build)\n"

        def version(command):
            if command == ["xcodebuild", "-version"]:
                return self.xcode_version
            toolchain = json.loads((native.CONFIG / "source.json").read_text())["rust_toolchain"]
            if command == ["rustc", f"+{toolchain}", "--version"]:
                return self.rust_version
            raise AssertionError(f"Unexpected command: {command}")

        patcher = patch.object(native.subprocess, "check_output", side_effect=version)
        self.version_probe = patcher.start()
        self.addCleanup(patcher.stop)

    def test_unrelated_edits_keep_the_cache_key(self):
        before = native.build_fingerprint()
        for relative in ("README.md", "Tests/VPNReconnect.swift", "InstallationProxy.swift"):
            path = native.CONFIG / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Unrelated documentation or Swift changes\n")
        self.assertEqual(native.build_fingerprint(), before)

    def test_native_inputs_invalidate_the_key(self):
        for path in (native.CONFIG / "source.json", native.CONFIG / "ksign_pairing.rs", Path(native.__file__)):
            with self.subTest(input=path.name):
                before = native.build_fingerprint()
                original = path.read_bytes()
                if path.name == "source.json":
                    data = json.loads(original)
                    data["revision"] = "new-pinned-revision"
                    path.write_text(json.dumps(data))
                else:
                    path.write_bytes(original + b"\n// Native build change\n")
                self.assertNotEqual(native.build_fingerprint(), before)
                path.write_bytes(original)

    def test_toolchain_changes_invalidate_the_key(self):
        before = native.build_fingerprint()
        self.xcode_version += b"Updated Xcode build\n"
        after_xcode = native.build_fingerprint()
        self.assertNotEqual(after_xcode, before)
        self.rust_version += b"Updated Rust build\n"
        self.assertNotEqual(native.build_fingerprint(), after_xcode)
        data = json.loads((native.CONFIG / "source.json").read_text())
        data["rust_toolchain"] = "1.100.0"
        (native.CONFIG / "source.json").write_text(json.dumps(data))
        native.build_fingerprint()
        self.assertEqual(self.version_probe.call_args.args[0], ["rustc", "+1.100.0", "--version"])

    def test_cache_key_cli_does_not_prepare_or_build(self):
        expected = native.build_fingerprint()
        output = io.StringIO()
        with patch("sys.argv", [str(SCRIPT), "--cache-key"]), \
                patch.object(native, "prepare") as prepare, \
                patch.object(native, "run") as run, contextlib.redirect_stdout(output):
            native.main()
        self.assertEqual(output.getvalue(), expected + "\n")
        self.assertRegex(expected, r"^[0-9a-f]{64}$")
        prepare.assert_not_called()
        run.assert_not_called()
        self.assertFalse(native.WORK.exists())

    def test_restored_matching_stamp_skips_native_compilation(self):
        # Use the CLI's actual output as a restored stamp, then take the same
        # path make takes. This catches drift between the CI key and builder.
        output = io.StringIO()
        with patch("sys.argv", [str(SCRIPT), "--cache-key"]), contextlib.redirect_stdout(output):
            native.main()
        native.WORK.mkdir()
        native.OUTPUT.mkdir()
        (native.WORK / "built-stamp").write_text(output.getvalue().strip())
        with patch("sys.argv", [str(SCRIPT)]), \
                patch.object(native, "prepare", return_value=self.root / "source"), \
                patch.object(native, "run") as run, contextlib.redirect_stdout(io.StringIO()) as log:
            native.main()
        run.assert_not_called()
        self.assertIn("Using cached Ksign iDevice framework", log.getvalue())


if __name__ == "__main__":
    unittest.main()
