#!/usr/bin/env python3
"""Check cloud capability preservation without loading a runtime patch.

The native filter checks are portable. The policy checks compile the production
Swift patcher when swiftc is available, with injection APIs stubbed to fail if
called. No signing credentials, network access or Apple services are used.
"""
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SERVICES = "com.apple.developer.icloud-services"
CONTAINERS = "com.apple.developer.icloud-container-identifiers"
SNAPSHOT = "AsignOriginalCloudEntitlementKeys"
CLOUD = {SERVICES: ["CloudKit"], CONTAINERS: ["iCloud.example.original"]}


def executable(entitlements):
    xml = plistlib.dumps(entitlements)
    blob = struct.pack(">II", 0xFADE7171, len(xml) + 8) + xml
    seal = struct.pack(">IIIII", 0xFADE0CC0, len(blob) + 20, 1, 5, 20) + blob
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 1, 16, 0, 0)
    return header + struct.pack("<IIII", 0x1D, 16, 48, len(seal)) + seal


class NativeCloudFilterChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="asign-cloud-filter-")
        cls.addClassCleanup(cls.scratch.cleanup)
        directory = Path(cls.scratch.name)
        source = directory / "filter.cpp"
        source.write_text(r'''
#include "cloud_entitlements.h"
#include <iostream>
#include <iterator>
int main(int argc, char **argv) {
    string source((std::istreambuf_iterator<char>(std::cin)), {}), output;
    vector<string> keys;
    for (int i = 1; i < argc; ++i) keys.emplace_back(argv[i]);
    if (!FilterCloudEntitlements(source, keys, output)) return 2;
    std::cout << output;
}
''')
        core = ROOT / "ZsignLatest/Sources/ZsignC/Core"
        cls.binary = directory / "filter"
        subprocess.run(["clang++", "-std=c++17", "-I", str(core), str(source),
                        str(core / "common/json.cpp"), "-o", str(cls.binary)], check=True)

    def test_local_cloud_and_kvs_bundles_share_profile_without_mutating_it(self):
        identity = {"application-identifier": "NEW.example.app",
                    "com.apple.developer.team-identifier": "NEW",
                    "keychain-access-groups": ["NEW.*"],
                    "com.apple.security.application-groups": ["group.example.app"],
                    "aps-environment": "production"}
        cloud = {SERVICES: ["CloudKit"], CONTAINERS: ["iCloud.example.signer"],
                 "com.apple.developer.icloud-container-environment": "Production",
                 "com.apple.developer.ubiquity-kvstore-identifier": "NEW.example.app"}
        source = plistlib.dumps(identity | cloud)
        for keys in ([], list(CLOUD), ["com.apple.developer.ubiquity-kvstore-identifier"], list(cloud)):
            with self.subTest(keys=keys):
                result = subprocess.run([str(self.binary), *keys], input=source, capture_output=True, check=True)
                self.assertEqual(plistlib.loads(result.stdout), identity | {key: cloud[key] for key in keys})
        self.assertEqual(plistlib.loads(source), identity | cloud)

    def test_malformed_entitlements_are_rejected(self):
        result = subprocess.run([str(self.binary)], input=b"not a plist", capture_output=True)
        self.assertEqual(result.returncode, 2)


@unittest.skipUnless(shutil.which("swiftc"), "Requires the Swift compiler and Foundation")
class CloudSigningPolicyChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="asign-cloud-policy-")
        cls.addClassCleanup(cls.scratch.cleanup)
        directory = Path(cls.scratch.name)
        source = directory / "checks.swift"
        source.write_text(r'''
import Foundation

// Policy discovery must work when patch injection is disabled or unavailable.
func KsignIPAFileHasPatchLibrary(_ path: String, _ name: String,
    _ error: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int32 { fatalError("Unexpected injection") }
func KsignIPAFileHasLegacyPatchLibrary(_ path: String,
    _ error: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int32 { fatalError("Unexpected injection") }
func KsignPatchIPAFileWithGrowth(_ path: String, _ load: String,
    _ resolver: (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32,
    _ context: UnsafeMutableRawPointer?, _ error: UnsafeMutablePointer<CChar>?,
    _ size: Int) -> Int32 { fatalError("Unexpected injection") }

@main struct Checks {
    static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let policy = IPAPatcher.cloudEntitlementPolicy(in: app)
        let data = try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
''')
        cls.binary = directory / "checks"
        subprocess.run(["swiftc", "-swift-version", "5", str(source),
                        str(ROOT / "Asign/Utilities/Handlers/IPAPatcher.swift"),
                        "-o", str(cls.binary)], check=True)

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="asign-cloud-input-")
        self.addCleanup(self.workspace.cleanup)
        self.app = Path(self.workspace.name) / "Input.app"

    def bundle(self, path, entitlements, **metadata):
        path.mkdir(parents=True)
        info = {"CFBundleIdentifier": "example.app", "CFBundleExecutable": "Main", **metadata}
        (path / "Info.plist").write_bytes(plistlib.dumps(info))
        (path / "Main").write_bytes(executable(entitlements))

    def policy(self):
        result = subprocess.run([str(self.binary), str(self.app)], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_local_app_and_cloud_extension_without_injection(self):
        self.bundle(self.app, {"application-identifier": "OLD.example.app"})
        self.bundle(self.app / "PlugIns/Cloud.appex", CLOUD)
        before = {str(path): path.read_bytes() for path in self.app.rglob("*") if path.is_file()}
        self.assertEqual(self.policy(), {"Main": [], "PlugIns/Cloud.appex/Main": sorted(CLOUD)})
        self.assertEqual({str(path): path.read_bytes() for path in self.app.rglob("*") if path.is_file()}, before)

    def test_first_snapshot_wins_over_resigned_capabilities(self):
        self.bundle(self.app, CLOUD, **{SNAPSHOT: []})
        self.bundle(self.app / "PlugIns/Cloud.appex", {}, **{SNAPSHOT: sorted(CLOUD)})
        self.assertEqual(self.policy(), {"Main": [], "PlugIns/Cloud.appex/Main": sorted(CLOUD)})

    def test_malformed_snapshot_is_inconclusive(self):
        for captured in ("invalid", [123], ["application-identifier"]):
            with self.subTest(captured=captured):
                info = {"CFBundleExecutable": "Main", SNAPSHOT: captured}
                self.app.mkdir(exist_ok=True)
                (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
                (self.app / "Main").write_bytes(executable({}))
                self.assertEqual(self.policy(), {})

    def test_unknown_signature_does_not_mean_local_app(self):
        self.bundle(self.app, {})
        (self.app / "Main").write_bytes(b"invalid executable")
        self.assertEqual(self.policy(), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
