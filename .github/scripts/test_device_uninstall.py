#!/usr/bin/env python3
"""Check the real device overlays and run removal-policy tests with Swift."""
import argparse
import importlib.util
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-swift", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("device_overlays", Path(__file__).with_name("integrate_devicekit.py"))
    overlays = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(overlays)
    with tempfile.TemporaryDirectory(prefix="ksign-uninstall-tests-") as scratch:
        kit = Path(scratch) / "IDeviceKit"
        kit.mkdir()
        # Fresh upstream checkout in scratch: do not mutate the user's submodule.
        subprocess.run(["git", "-C", str(ROOT / "IDeviceKit"), "archive", "HEAD", "--output=" + str(Path(scratch) / "kit.tar")], check=True)
        with tarfile.open(Path(scratch) / "kit.tar") as archive:
            archive.extractall(kit, filter="data")
        overlays.apply(kit)
        target = kit / "Sources/IDeviceSwift/InstallationProxy/UninstallRequest.swift"
        assert target.read_text() == overlays.MARKER + (ROOT / "Native/Device/UninstallRequest.swift").read_text()
        assert (kit / "Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift").read_text() == overlays.MARKER + (ROOT / "Native/Device/InstallationProxy.swift").read_text()
        print("Device overlays validated against pinned upstream sources", flush=True)
        compiler = shutil.which("swiftc")
        if not compiler:
            print("Swift removal-policy tests unavailable: swiftc is not installed.", flush=True)
            return 1 if args.require_swift else 0
        executable = Path(scratch) / "uninstall-tests"
        flags = ["-swift-version", "5"]
        if sys.platform == "darwin":
            flags += ["-target", platform.machine() + "-apple-macosx14.0"]
        subprocess.run([compiler, *flags,
                        str(ROOT / "Native/Device/InstallPreflight.swift"),
                        str(ROOT / "Native/Device/UninstallRequest.swift"),
                        str(ROOT / "Tests/DeviceUninstall/main.swift"),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
