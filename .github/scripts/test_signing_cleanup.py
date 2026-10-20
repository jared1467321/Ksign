#!/usr/bin/env python3
"""Exercise production signing completion and bulk scheduling with file-backed doubles."""
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
    handler = (ROOT / "Ksign/Utilities/Handlers/SigningHandler.swift").read_text()
    bulk = (ROOT / "Ksign/Views/Signing/BulkSigningView.swift").read_text()
    source = (ROOT / "ZsignLatest/Tests/signing_cleanup_regressions.swift").read_text()
    source = source.replace("// PRODUCTION_GATES", "\n".join(swift_block(handler, name) for name in (
        "actor SigningStageGate", "final class SigningBatchContext")))
    source = source.replace("// PRODUCTION_SIGN", swift_block(
        (ROOT / "Ksign/Utilities/FR.swift").read_text(), "static func signPackageFile("))
    source = source.replace("// PRODUCTION_BULK", "\n".join(swift_block(bulk, name) for name in (
        "private func _runSigning(", "private static func _signOne(")))
    with tempfile.TemporaryDirectory(prefix="ksign-signing-cleanup-") as temporary:
        work = Path(temporary)
        generated = work / "SigningCleanup.swift"
        generated.write_text(source)
        executable = work / "signing-cleanup"
        subprocess.run([args.swiftc, "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", str(work / "cache"), str(generated),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
