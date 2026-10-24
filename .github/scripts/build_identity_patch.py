#!/usr/bin/env python3
"""Build the unified Asign compatibility library from source using Apple's SDK."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Native/IdentityPatch"
VERSION = b"AsignPatch/v1\0"


def build(output, sdk="iphoneos", target_platform="iphoneos", architectures=None):
    default_arch = "arm64" if target_platform == "iphoneos" else platform.machine()
    architectures = architectures or os.environ.get("ARCHS", default_arch).split()
    if not architectures or any(arch not in ("arm64", "x86_64") for arch in architectures):
        raise ValueError("Asign patch supports arm64 and x86_64 builds")
    if target_platform == "iphoneos" and architectures != ["arm64"]:
        raise ValueError("Device Asign patch requires arm64")
    sdk_path = sdk if Path(sdk).is_dir() else subprocess.check_output(
        ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="asign-patch-", dir=os.environ.get("TEMP_DIR")) as scratch:
        scratch = Path(scratch)
        slices = []
        for arch in architectures:
            target = {"iphoneos": f"{arch}-apple-ios14.0",
                      "iphonesimulator": f"{arch}-apple-ios14.0-simulator",
                      "macosx": f"{arch}-apple-macosx12.0"}[target_platform]
            flags = ["-target", target, "-isysroot", sdk_path, "-std=gnu11", "-Oz",
                     "-Wall", "-Wextra", "-Werror", "-fvisibility=hidden"]
            objects = []
            for source in (SOURCE / "Rebind.c", SOURCE / "IdentityPatch.m", SOURCE / "CompatibilityPatch.m"):
                obj = scratch / f"{arch}-{source.stem}.o"
                arc = ["-fobjc-arc", "-fblocks"] if source.suffix == ".m" else []
                subprocess.run([clang, *flags, *arc, "-c", str(source), "-o", str(obj)], check=True)
                objects.append(str(obj))
            library = scratch / f"{arch}.dylib"
            subprocess.run([clang, "-target", target, "-isysroot", sdk_path, "-dynamiclib", *objects,
                            "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "Security",
                            "-Wl,-install_name,@rpath/asignpatch.dylib", "-Wl,-headerpad_max_install_names",
                            "-o", str(library)], check=True)
            slices.append(library)
        library = scratch / "asignpatch.dylib"
        if len(slices) == 1:
            shutil.copyfile(slices[0], library)
        else:
            subprocess.run(["xcrun", "lipo", "-create", *map(str, slices), "-output", str(library)], check=True)
        data = library.read_bytes()
        if VERSION not in data or b"AsignCompatibilityPatch/v1\0" not in data:
            raise RuntimeError("Asign patch version marker was stripped")
        if not output.exists() or output.read_bytes() != data:
            # Publish beside the destination so rename remains atomic even if
            # the compiler's temporary directory is on a different volume.
            with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as staged:
                staged.write(data)
                staged_path = Path(staged.name)
            try:
                staged_path.chmod(0o644)
                staged_path.replace(output)
            finally:
                staged_path.unlink(missing_ok=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", default=os.environ.get("SDKROOT", "iphoneos"))
    parser.add_argument("--platform", choices=("iphoneos", "iphonesimulator", "macosx"),
                        default=os.environ.get("PLATFORM_NAME", "iphoneos"))
    parser.add_argument("--arch", action="append")
    args = parser.parse_args()
    print(build(args.output, args.sdk, args.platform, args.arch))


if __name__ == "__main__":
    main()
