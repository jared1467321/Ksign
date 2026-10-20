#!/usr/bin/env python3
"""Compile production memory admission and workspace isolation against controlled telemetry."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from test_device_connection import swift_block

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    memory = (ROOT / "Ksign/Utilities/Handlers/ArchiveMemoryCoordinator.swift").read_text()
    # Keep admission, reservations, sampling, pressure handling and checkpoint
    # logic verbatim. Only the kernel probe and platform logger are doubled.
    probe = swift_block(memory, "private static func processSnapshot()")
    memory = memory.replace(probe, "private static func processSnapshot() -> Snapshot? { nil }")
    memory = memory.replace("import Darwin\n", "").replace("import OSLog\n", "")
    memory = memory.replace("\\(message, privacy: .public)", "\\(message)")
    workspace = (ROOT / "Ksign/Utilities/Handlers/SigningWorkspace.swift").read_text()
    protocol = swift_block((ROOT / "Ksign/Backend/Storage/Storage+Shared.swift").read_text(), "protocol AppInfoPresentable")
    with tempfile.TemporaryDirectory(prefix="ksign-signing-memory-") as temporary:
        work = Path(temporary)
        for label, production in [("memory", memory), ("workspace", protocol + "\n" + workspace)]:
            generated = work / f"{label}.swift"
            generated.write_text(production)
            executable = work / label
            subprocess.run([args.swiftc, "-swift-version", "5", "-D", "ARCHIVE_MEMORY_TESTING", "-parse-as-library",
                            "-module-cache-path", str(work / "cache"), str(generated),
                            str(ROOT / f"ZsignLatest/Tests/signing_{label}_regressions.swift"),
                            "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
