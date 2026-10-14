#!/usr/bin/env python3
"""Build one pinned idevice XCFramework with Ksign's pairing bridge.

Run before opening Xcode or resolving packages. --prepare-only is useful for
Linux cargo tests; --archive accepts an already downloaded, hash-checked archive.
--cache-key prints the native build fingerprint without preparing or building.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Native/Device"
WORK = ROOT / ".build/device-native"
OUTPUT = ROOT / "IDeviceKit/.build/IDevice.xcframework"


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def build_fingerprint():
    """Use the same native inputs for the CI cache and the local build stamp."""
    toolchain = json.loads((CONFIG / "source.json").read_text())["rust_toolchain"]
    return hashlib.sha256((CONFIG / "source.json").read_bytes() +
                          (CONFIG / "ksign_pairing.rs").read_bytes() +
                          Path(__file__).read_bytes() +
                          subprocess.check_output(["xcodebuild", "-version"]) +
                          subprocess.check_output(["rustc", f"+{toolchain}", "--version"])).hexdigest()


def prepare(archive=None):
    spec = json.loads((CONFIG / "source.json").read_text())
    WORK.mkdir(parents=True, exist_ok=True)
    archive = Path(archive) if archive else WORK / "source.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(
            f"https://codeload.github.com/jkcoxson/idevice/tar.gz/{spec['revision']}", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != spec["sha256"]:
        raise RuntimeError("iDevice source checksum mismatch")
    source = WORK / "source"
    marker = source / ".ksign-revision"
    if not marker.exists() or marker.read_text() != spec["revision"]:
        if source.exists():
            shutil.rmtree(source)
        source.mkdir()
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts:
                    continue
                member.name = str(Path(*parts))
                tar.extract(member, source, filter="data")
        marker.write_text(spec["revision"])
    shutil.copy2(CONFIG / "ksign_pairing.rs", source / "ffi/src/ksign_pairing.rs")
    lib = source / "ffi/src/lib.rs"
    text = lib.read_text()
    declaration = '\n#[cfg(feature = "remote_pairing")]\npub mod ksign_pairing;\n'
    if declaration not in text:
        lib.write_text(text + declaration)
    # Bound reconnects so an unavailable device cannot block every queued IPA.
    tunnel = source / "ffi/src/tunnel_provider.rs"
    text = tunnel.read_text()
    start = text.index('pub unsafe extern "C" fn tunnel_create_rppairing(')
    prefix, function = text[:start], text[start:]
    original = '    let res = run_sync_local(async {\n        // Connect directly'
    wrapped = '    let res = run_sync_local(async {\n        tokio::time::timeout(std::time::Duration::from_secs(30), async {\n        // Connect directly'
    if original in function:
        function = function.replace(original, wrapped, 1)
        end = '        finish_tunnel(&mut rpc, socket_addr).await\n    });'
        if function.count(end) != 1:
            raise RuntimeError("Unrecognized upstream tunnel function")
        function = function.replace(end, '        finish_tunnel(&mut rpc, socket_addr).await\n        }).await.map_err(|_| IdeviceError::InternalError("Device connection timed out. Retry setup.".into()))?\n    });', 1)
        tunnel.write_text(prefix + function)
    elif wrapped not in function:
        raise RuntimeError("Unrecognized upstream tunnel function")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--cache-key", action="store_true")
    args = parser.parse_args()
    if args.cache_key:
        print(build_fingerprint())
        return
    source = prepare(args.archive)
    if args.prepare_only:
        print(source)
        return
    toolchain = json.loads((CONFIG / "source.json").read_text())["rust_toolchain"]
    stamp = build_fingerprint()
    stamp_path = WORK / "built-stamp"
    if OUTPUT.exists() and stamp_path.exists() and stamp_path.read_text() == stamp:
        print("Using cached Ksign iDevice framework")
        return
    targets = [("aarch64-apple-ios", "iphoneos"), ("aarch64-apple-ios-sim", "iphonesimulator")]
    run("rustup", "target", "add", "--toolchain", toolchain, *(target for target, _ in targets))
    for target, sdk in targets:
        env = os.environ.copy()
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        env["BINDGEN_EXTRA_CLANG_ARGS"] = f"--sysroot={sdk_path}"
        env["IPHONEOS_DEPLOYMENT_TARGET"] = "16.0"
        run("cargo", f"+{toolchain}", "build", "--locked", "--release", "--target", target,
            "-p", "idevice-ffi", cwd=source, env=env)
    headers = WORK / "include"
    headers.mkdir(exist_ok=True)
    shutil.copy2(source / "ffi/idevice.h", headers / "idevice.h")
    (headers / "module.modulemap").write_text('module IDevice {\n  header "idevice.h"\n  export *\n}\n')
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    command = ["xcodebuild", "-create-xcframework"]
    for target, _ in targets:
        command += ["-library", str(source / f"target/{target}/release/libidevice_ffi.a"), "-headers", str(headers)]
    run(*command, "-output", str(OUTPUT))
    stamp_path.write_text(stamp)


if __name__ == "__main__":
    main()
