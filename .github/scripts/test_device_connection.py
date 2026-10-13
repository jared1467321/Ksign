#!/usr/bin/env python3
"""Compile and run production connection recovery against service doubles.

Requires swiftc (available on the macOS build runner). Apple framework imports
are replaced by doubles; connection and recovery logic is used verbatim.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    compiler = shutil.which("swiftc")
    if compiler is None:
        raise SystemExit("swiftc is required; run on macOS or a Swift-equipped Linux host")
    sources = []
    for relative in (
        "Ksign/Backend/Device/LocalDeviceVPN.swift",
        "Ksign/Backend/Device/DeviceInstallationManager.swift",
        "Native/Device/Tests/ConnectionRecovery.swift",
        "Native/Device/Tests/InstallationConcurrency.swift",
    ):
        source = (ROOT / relative).read_text()
        source = "\n".join(
            line for line in source.splitlines()
            if line not in {"import NetworkExtension", "import Combine", "import IDeviceSwift"}
        )
        sources.append(source)
    with tempfile.TemporaryDirectory(prefix="ksign-recovery-tests-") as temporary:
        directory = Path(temporary)
        source = directory / "ConnectionRecovery.swift"
        source.write_text("\n".join(sources))
        executable = directory / "ConnectionRecoveryTests"
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

        # Compile the actual admission/cleanup coordinator separately from the
        # app's UIKit-dependent job and session. OSLog and pressure sources are
        # available on the macOS CI runner; connection tests also work on Linux.
        if sys.platform == "darwin":
            jobs = (ROOT / "Ksign/Views/Library/Install/InstallJob.swift").read_text()
            marker = "@MainActor\nfinal class InstallQueueCoordinator"
            coordinator = marker + jobs.split(marker, 1)[1]
            source.write_text((ROOT / "Native/Device/Tests/InstallQueueLifetime.swift").read_text()
                              + "\n" + (ROOT / "Native/Device/IDeviceInstallationWorker.swift").read_text()
                              + "\n" + coordinator)
            subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                            str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
