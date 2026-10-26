#!/usr/bin/env python3
"""Manual checks; macOS additionally runs native policy/storage and Swift seal fixtures.

Run from any directory: python3 Native/IdentityPatch/Tests/check.py
No tests are added to the app's build workflow.
"""
import importlib.util
import itertools
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
spec = importlib.util.spec_from_file_location("patch_builder", ROOT / ".github/scripts/build_identity_patch.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
APPLE_HOST = platform.system() == "Darwin" and shutil.which("xcrun") is not None


def thin(entitlements=None, der=False):
    if entitlements is None and not der:
        return struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0)
    payload = b"DER fixture" if der else plistlib.dumps(entitlements)
    blob = struct.pack(">2I", 0xfade7172 if der else 0xfade7171, 8 + len(payload)) + payload
    signature = struct.pack(">5I", 0xfade0cc0, 20 + len(blob), 1, 7 if der else 5, 20) + blob
    header = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 1, 16, 0, 0)
    return header + struct.pack("<4I", 0x1d, 16, 48, len(signature)) + signature


def fat(first, second):
    return (struct.pack(">2I", 0xcafebabe, 2)
            + struct.pack(">5I", 0x100000c, 0, 48, len(first), 0)
            + struct.pack(">5I", 0x1000007, 0, 48 + len(first), len(second), 0)
            + first + second)


class BuildControls(unittest.TestCase):
    def test_keychain_retry_lifecycle(self):
        compiler = shutil.which("clang")
        if not compiler:
            self.skipTest("Clang unavailable for the portable Objective-C harness")
        implementation = (HERE.parent / "CompatibilityPatch.m").read_text()
        wrappers = implementation[implementation.index("static OSStatus KeychainResult("):
                                  implementation.index("static NSURL *SharedRoot(")]
        fixture = (HERE / "KeychainRetry.m").read_text()
        with tempfile.TemporaryDirectory(prefix="asign-keychain-") as scratch:
            source = Path(scratch) / "KeychainRetry.m"
            executable = Path(scratch) / "KeychainRetry"
            source.write_text(fixture.replace("// PRODUCTION_KEYCHAIN_WRAPPERS", wrappers))
            subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                            "-fobjc-runtime=macosx-10.12", str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_abi_and_import_preservation(self):
        compiler = shutil.which("cc") or shutil.which("clang")
        if not compiler:
            self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="asign-portable-") as scratch:
            executable = Path(scratch) / "Portable"
            subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                            str(HERE / "Portable.c"), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_compiled_hook_selection(self):
        """Compile the real header to verify Python/C flag agreement for every subset."""
        compiler = shutil.which("cc") or shutil.which("clang")
        if not compiler:
            self.skipTest("C compiler unavailable")
        names = ("Identity", "Keychain", "AppGroups", "CloudKit", "BackgroundAssets", "ModuleTrace", "ImageCallbacks")
        expressions = ",".join(f"AsignPatchEnabled(AsignPatch{name})" for name in names)
        source = ('#include <stdio.h>\n#include "PatchOptions.h"\n'
                  f'int main(void) {{ printf("%d%d%d%d%d%d%d\\n", {expressions}); }}\n')
        with tempfile.TemporaryDirectory(prefix="asign-options-") as scratch:
            scratch = Path(scratch)
            path, executable = scratch / "options.c", scratch / "options"
            path.write_text(source)
            for size in range(len(builder.HOOKS) + 1):
                for disabled in itertools.combinations(builder.HOOKS, size):
                    with self.subTest(disabled=disabled):
                        subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                                        "-I", str(HERE.parent), *builder.diagnostic_flags(disabled),
                                        str(path), "-o", str(executable)], check=True, capture_output=True)
                        result = subprocess.check_output([str(executable)], text=True).strip()
                        self.assertEqual(result, "".join("0" if hook in disabled else "1" for hook in builder.HOOKS))

    def test_reject_invalid_diagnostics(self):
        with self.assertRaises(ValueError):
            builder.diagnostic_flags(["typo"])
        with self.assertRaises(ValueError):
            builder.diagnostic_flags(["image-callbacks"], True)
        self.assertIn("-DASIGN_PATCH_DEFER_IMAGE_CALLBACKS=1", builder.diagnostic_flags([], True))


@unittest.skipUnless(APPLE_HOST, "Requires macOS and Xcode; these checks were not run on this host")
class AppleRuntime(unittest.TestCase):
    def test_cloud_scoping_and_pass_through(self):
        with tempfile.TemporaryDirectory(prefix="asign-cloud-") as scratch:
            executable = Path(scratch) / "CloudRuntime"
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-std=gnu11", "-O0", "-Wall", "-Wextra", "-Werror",
                            "-fobjc-arc", "-fblocks", str(HERE / "CloudRuntime.m"), "-framework", "Foundation",
                            "-framework", "Security", "-framework", "CoreData", "-o", str(executable)], check=True)
            for scenario in ("mixed", "authorized", "missing-snapshot", "empty-snapshot", "invalid-snapshot", "unreadable"):
                subprocess.run([str(executable), scenario], check=True)

    def test_native_policies_and_storage(self):
        with tempfile.TemporaryDirectory(prefix="asign-runtime-") as scratch:
            executable = Path(scratch) / "Runtime"
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-std=gnu11", "-O0", "-Wall", "-Wextra", "-Werror",
                            "-fobjc-arc", "-fblocks", str(HERE / "Runtime.m"), "-framework", "Foundation",
                            "-framework", "Security", "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_original_capability_snapshots(self):
        original = {"com.apple.security.application-groups": ["group.original"],
                    "keychain-access-groups": ["OLD.shared"], "application-identifier": "OLD.app",
                    "com.apple.developer.icloud-services": ["CloudKit"],
                    "com.apple.developer.icloud-container-identifiers": ["iCloud.original"]}
        with tempfile.TemporaryDirectory(prefix="asign-snapshots-") as scratch:
            scratch = Path(scratch)
            original_bytes = thin(original)
            fixtures = {"original": original_bytes, "empty": thin({}), "unsigned": thin(),
                        "malformed": thin({**original, "keychain-access-groups": ["*"]}),
                        "malformed-id": thin({**original, "application-identifier": 42}),
                        "mixed-groups": fat(original_bytes, thin({**original, "com.apple.security.application-groups": ["group.other"]})),
                        "mixed-cloud": fat(original_bytes, thin({**original, "com.apple.developer.icloud-services": []})),
                        "mixed-cloud-keys": fat(original_bytes, thin({k: v for k, v in original.items() if "icloud-" not in k})),
                        "malformed-cloud": thin({**original, "com.apple.developer.icloud-container-identifiers": 42}),
                        "malformed-services": thin({**original, "com.apple.developer.icloud-services": "*"}),
                        "der-only": thin(der=True)}
            for name, data in fixtures.items():
                (scratch / name).write_bytes(data)
            implementation = (ROOT / "Asign/Utilities/Handlers/IPAPatcher.swift").read_text()
            implementation = implementation[implementation.index("enum OriginalCloudEntitlements {"):implementation.index("/// Workers only collect failures.")]
            source = scratch / "Snapshot.swift"
            source.write_text("import Foundation\n" + implementation + (HERE / "Snapshot.swift").read_text())
            executable = scratch / "Snapshot"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable), str(scratch)], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
