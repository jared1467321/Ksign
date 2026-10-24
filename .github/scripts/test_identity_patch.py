#!/usr/bin/env python3
"""Build and exercise the production identity companion and signing transaction."""
import argparse
import importlib.util
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

from test_ipa_patching import ROOT, identity_fixtures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-apple", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin" or not shutil.which("swiftc"):
        print("Identity runtime/transaction tests require macOS, Xcode and swiftc.", flush=True)
        return 1 if args.require_apple else 0
    spec = importlib.util.spec_from_file_location("identity_builder", ROOT / ".github/scripts/build_identity_patch.py")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    with tempfile.TemporaryDirectory(prefix="asign-identity-tests-") as temporary:
        directory = Path(temporary)
        # Production Swift/native transaction; no LIEF download is needed for
        # fixtures that already have space for both library commands.
        native = ROOT / "Asign/Utilities/MachO/IPAPatch.c"
        native_object = directory / "patch.o"
        subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", "-c", str(native), "-o", str(native_object)], check=True)
        adapter = directory / "growth.c"
        adapter.write_text('''#include "IPAPatch.h"
int KsignPatchIPAFileWithGrowth(const char *file, const char *path,
    KsignIPARunpathResolver resolver, void *context, char *error, size_t size) {
    return KsignPatchIPAFile(file, path, resolver, context, error, size);
}
''')
        adapter_object = directory / "growth.o"
        subprocess.run(["clang", "-I", str(native.parent), "-c", str(adapter), "-o", str(adapter_object)], check=True)
        identity_fixtures(directory)
        swift_main = directory / "main.swift"
        shutil.copyfile(ROOT / "Tests/IPAPatching/identity.swift", swift_main)
        transaction = directory / "transaction"
        subprocess.run(["swiftc", "-swift-version", "5", "-import-objc-header", str(native.with_suffix(".h")),
                        str(ROOT / "Asign/Utilities/Handlers/IPAPatcher.swift"), str(swift_main),
                        str(native_object), str(adapter_object), "-o", str(transaction)], check=True)
        subprocess.run([str(transaction), str(directory)], check=True)

        app = directory / "IdentityProbe.app"
        contents = app / "Contents"
        executable = contents / "MacOS/Probe"
        executable.parent.mkdir(parents=True)
        frameworks = contents / "Frameworks"
        frameworks.mkdir()
        identity = builder.build(frameworks / "asignpatch.dylib", "macosx", "macosx", [platform.machine()])
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        flags = ["-target", platform.machine() + "-apple-macosx12.0", "-isysroot", sdk]
        subprocess.run(["xcrun", "clang", *flags, "-fobjc-arc", str(ROOT / "Tests/IdentityPatch/main.m"),
                        "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "Security", "-o", str(executable)], check=True)
        nested = contents / "PlugIns/Share.bundle"
        for bundle, identifier, original in [(app, "org.example.renamed", "org.example.original"),
                                              (nested, "org.example.renamed.share", "org.example.original.share")]:
            resources = bundle / "Contents/Resources/en.lproj"
            resources.mkdir(parents=True)
            info = {"CFBundleIdentifier": identifier, "AsignOriginalBundleIdentifier": original,
                    "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL" if bundle == app else "BNDL",
                    "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en"]}
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (resources / "InfoPlist.strings").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        late_libraries = []
        for mode in ("fixup_chains", "no_fixup_chains"):
            late = frameworks / (mode + ".dylib")
            subprocess.run(["xcrun", "clang", *flags, "-dynamiclib", "-Wl,-" + mode,
                            str(ROOT / "Tests/IdentityPatch/late.c"), "-framework", "CoreFoundation",
                            "-o", str(late)], check=True)
            late_libraries.append(str(late))
        environment = dict(os.environ, DYLD_INSERT_LIBRARIES=str(identity))
        subprocess.run([str(executable), str(nested), *late_libraries], env=environment, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
