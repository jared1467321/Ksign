"""Exercise the production Swift indirect-result calling convention bridge."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CloudKitABITests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_resilient_swift_result_survives_original_and_local_paths(self):
        with tempfile.TemporaryDirectory(prefix="asign-cloud-abi-") as temporary:
            directory = Path(temporary)
            fixture = directory / "Fixture.swift"
            fixture.write_text('''
public struct ModelConfiguration {
    public struct CloudKitDatabase {
        public let identifier: String
        private let storage: [String]
        private init(_ identifier: String) {
            self.identifier = identifier
            self.storage = [identifier, identifier]
        }
        public static func `private`(_ identifier: String) -> Self { Self(identifier) }
    }
}
@_silgen_name("FixtureAutomatic")
public func original() -> ModelConfiguration.CloudKitDatabase {
    .private("authorized-container-remains-unchanged")
}
''')
            extension = ".dylib" if sys.platform == "darwin" else ".so"
            library = directory / ("libSwiftData" + extension)
            subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-enable-library-evolution",
                            "-emit-module", "-emit-library", "-module-name", "SwiftData", str(fixture),
                            "-emit-module-path", str(directory / "SwiftData.swiftmodule"), "-o", str(library)], check=True)
            wrapper = directory / "wrapper.c"
            wrapper.write_text('''
#include "CloudKitABI.h"
#include <stdbool.h>
extern void __attribute__((swiftcall)) FixtureAutomatic(void *result __attribute__((swift_indirect_result)));
extern bool AsignInitializeLocalCloudConfiguration(void *, const char *);
static bool local;
void SetLocal(int enabled) { local = enabled != 0; }
void __attribute__((swiftcall)) FixtureWrapper(void *result __attribute__((swift_indirect_result))) {
    if (local && AsignInitializeLocalCloudConfiguration(result, "local-container-with-owned-Swift-string-storage")) return;
    AsignCloudAutomaticGetter original = FixtureAutomatic;
    original(result);
}
''')
            obj = directory / "wrapper.o"
            subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", "-fPIC", "-I", str(ROOT / "Native/IdentityPatch"),
                            "-c", str(wrapper), "-o", str(obj)], check=True)
            configuration_object = directory / "configuration.o"
            subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-emit-object",
                            "-module-name", "AsignPatchCloudKit", "-I", str(directory),
                            str(ROOT / "Native/IdentityPatch/CloudKitConfiguration.swift"),
                            "-o", str(configuration_object)], check=True)
            header = directory / "wrapper.h"
            header.write_text("void SetLocal(int enabled);\n")
            main = directory / "main.swift"
            main.write_text('''
import SwiftData
@_silgen_name("FixtureWrapper") func automatic() -> ModelConfiguration.CloudKitDatabase
for index in 0..<2000 {
    SetLocal(Int32(index % 2))
    let value = automatic()
    precondition(value.identifier == (index % 2 == 0
        ? "authorized-container-remains-unchanged" : "local-container-with-owned-Swift-string-storage"))
}
print("Swift resilient indirect result and owned string lifetime passed")
''')
            executable = directory / "abi-probe"
            subprocess.run(["swiftc", "-swift-version", "5", "-I", str(directory), "-L", str(directory),
                            "-lSwiftData", "-import-objc-header", str(header), str(main), str(obj), str(configuration_object),
                            "-Xlinker", "-rpath", "-Xlinker", str(directory), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=20)
