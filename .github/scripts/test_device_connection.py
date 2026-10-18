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


def swift_block(source, declaration):
    """Extract a whole production declaration/closure, including its body."""
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def session_controls_source():
    session = (ROOT / "Ksign/Views/Library/Install/InstallSession.swift").read_text()
    jobs = (ROOT / "Ksign/Views/Library/Install/InstallJob.swift").read_text()
    library = (ROOT / "Ksign/Views/Library/LibraryView.swift").read_text()
    tests = (ROOT / "Native/Device/Tests/InstallSessionControls.swift").read_text()
    job_methods = "\n".join(swift_block(jobs, declaration) for declaration in (
        "var hasWorkInProgress: Bool",
        "var isInFlightGroupMember: Bool",
        "private func _handleStatus(",
        "private func _didFinishDeviceUpload(",
    ))
    library_methods = "\n".join(swift_block(library, declaration) for declaration in (
        "private func _receiveInstalledSelection(",
        "private func _applyInstalledSelection(",
    ))
    tab_change = swift_block(library, ".onChange(of: _selectedTab)")
    tab_body = tab_change[tab_change.index("{ _ in") + len("{ _ in"):-1]
    # EditMode's UI-only convenience accessor is replaced with its equivalent.
    tab_body = tab_body.replace("_isEditMode.isEditing", "_isEditMode == .active")
    tests = tests.replace("// PRODUCTION_JOB_METHODS", job_methods)
    tests = tests.replace("// PRODUCTION_LIBRARY_METHODS", library_methods)
    tests = tests.replace("// PRODUCTION_TAB_CHANGE", tab_body)
    return tests + "\n" + swift_block(session, "@MainActor\nfinal class InstallSession:")


def queue_lifetime_source():
    jobs = (ROOT / "Ksign/Views/Library/Install/InstallJob.swift").read_text()
    marker = "@MainActor\nfinal class InstallQueueCoordinator"
    coordinator = marker + jobs.split(marker, 1)[1]
    # The coordinator also depends on this file-level value type. Keep the
    # production declaration; only the platform memory samplers are doubled.
    snapshot_start = jobs.index("private struct _ProcessMemorySnapshot {")
    snapshot_end = jobs.index("\nprivate func _processPhysicalFootprintBytes()", snapshot_start)
    snapshot = jobs[snapshot_start:snapshot_end]
    if sys.platform != "darwin":
        # Linux logging uses String; the admission and memory-pressure handlers
        # stay verbatim against the platform event/source doubles in the fixture.
        coordinator = coordinator.replace(", privacy: .public", "")
    tuning = (ROOT / "Ksign/Backend/Device/NativeInstallConcurrency.swift").read_text()
    tuning = tuning.replace("import IDeviceSwift", "")
    return "\n".join((
        (ROOT / "Native/Device/Tests/InstallQueueLifetime.swift").read_text(),
        (ROOT / "Native/Device/IDeviceInstallationWorker.swift").read_text(),
        swift_block((ROOT / "Native/Device/InstallationProxy.swift").read_text(),
                    "public enum IDeviceUploadEvent:"),
        tuning,
        snapshot,
        coordinator,
    ))


def shared_rsd_source():
    sources = [(ROOT / "Native/Device/Tests/SharedRSDConnection.swift").read_text()]
    for name in ("RSDConnection.swift", "InstallationProxy.swift", "IDeviceInstallationWorker.swift"):
        source = (ROOT / "Native/Device" / name).read_text()
        source = "\n".join(line for line in source.splitlines()
                           if line not in {"import IDevice", "import Combine", "import UIKit"})
        # Only platform declarations differ; tunnel, client and worker logic
        # stays verbatim. The UIApplication double accepts a selector name.
        source = source.replace('#selector(NSXPCConnection.suspend)', '"suspend"')
        if sys.platform != "darwin":
            source = "\n".join(line for line in source.splitlines() if ".sin_len =" not in line)
        sources.append(source)
    return "\n".join(sources)


def main():
    compiler = shutil.which("swiftc")
    if compiler is None:
        raise SystemExit("swiftc is required; run on macOS or a Swift-equipped Linux host")
    sources = [swift_block(
        (ROOT / "Native/Device/InstallationProxy.swift").read_text(),
        "public struct IDeviceInstallationRejection:")]
    for relative in (
        "Ksign/Backend/Device/LocalDeviceVPN.swift",
        "Ksign/Backend/Device/VPNReconnectCoordinator.swift",
        "Ksign/Backend/Device/DeviceInstallationManager.swift",
        "Native/Device/Tests/ConnectionRecovery.swift",
        "Native/Device/Tests/InstallationConcurrency.swift",
        "Native/Device/Tests/VPNReconnect.swift",
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

        source.write_text(shared_rsd_source())
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

        source.write_text(session_controls_source())
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

        proxy = (ROOT / "Native/Device/InstallationProxy.swift").read_text()
        tuning = (ROOT / "Ksign/Backend/Device/NativeInstallConcurrency.swift").read_text()
        source.write_text("\n".join((
            (ROOT / "Native/Device/Tests/NativeUploadTuning.swift").read_text(),
            swift_block(proxy, "public enum IDeviceUploadEvent:"),
            swift_block(proxy, "final class IDeviceInstallProgress"),
            tuning.replace("import IDeviceSwift", ""),
        )))
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

        source.write_text(queue_lifetime_source())
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
