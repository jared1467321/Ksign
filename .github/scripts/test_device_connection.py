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
    phase = swift_block(jobs, "@Published private(set) var phase:")
    phase = phase.replace("@Published private(set)", "@CountedPhaseRead")
    tests = tests.replace("// PRODUCTION_JOB_PHASE", phase)
    for declaration, placeholder in (
        ("private var _packagingTask:", "// PRODUCTION_PACKAGING_TASK"),
        ("private var _holdsSlot =", "// PRODUCTION_SLOT_STATE"),
    ):
        tests = tests.replace(placeholder, swift_block(jobs, declaration).removeprefix("private "))
    tests = tests.replace("// PRODUCTION_LIBRARY_METHODS", library_methods)
    tests = tests.replace("// PRODUCTION_TAB_CHANGE", tab_body)
    return "\n".join(((ROOT / "Native/Device/InstallPreflight.swift").read_text(), tests, swift_block(jobs, "enum NativeInstallLimit {"),
                      swift_block(session, "@MainActor\nfinal class InstallSession:")))


def queue_lifetime_source(load=False):
    jobs = (ROOT / "Ksign/Views/Library/Install/InstallJob.swift").read_text()
    marker = "@MainActor\nfinal class InstallQueueCoordinator"
    coordinator = marker + jobs.split(marker, 1)[1]
    # The coordinator also depends on this file-level value type. Keep the
    # production declaration; only the platform memory samplers are doubled.
    snapshot_start = jobs.index("private struct _ProcessMemorySnapshot {")
    snapshot_end = jobs.index("\nprivate func _processPhysicalFootprintBytes()", snapshot_start)
    snapshot = jobs[snapshot_start:snapshot_end]
    fixture = (ROOT / "Native/Device/Tests/InstallQueueLifetime.swift").read_text()
    if load:
        fixture = fixture[:fixture.index("@main struct InstallQueueLifetimeTests")]
        fixture += (ROOT / "Native/Device/Tests/InstallAdmissionLoad.swift").read_text()
        coordinator = coordinator.replace(
            "private func _reclaimOrphans() {",
            "private func _reclaimOrphans() {\n AdmissionMetrics.passes += 1")
    if sys.platform != "darwin":
        # Linux logging uses String; the admission and memory-pressure handlers
        # stay verbatim against the platform event/source doubles in the fixture.
        coordinator = coordinator.replace(", privacy: .public", "")
    return "\n".join((
        fixture,
        (ROOT / "Native/Device/IDeviceInstallationWorker.swift").read_text(),
        swift_block((ROOT / "Native/Device/InstallationProxy.swift").read_text(),
                    "public enum IDeviceUploadEvent:"),
        snapshot,
        swift_block(jobs, "private final class InstallAdmissionCancellation:"),
        swift_block(jobs, "enum NativeInstallLimit {"),
        coordinator,
    ))


def shared_rsd_source():
    sources = [(ROOT / "Native/Device/Tests/SharedRSDConnection.swift").read_text()]
    for name in ("InstallPreflight.swift", "RSDConnection.swift", "InstallationProxy.swift", "IDeviceInstallationWorker.swift"):
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
    sources = [(ROOT / "Native/Device/InstallPreflight.swift").read_text(), swift_block(
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

        preflight = (ROOT / "Native/Device/InstallPreflight.swift").read_text()
        wrapper = (ROOT / "Ksign/Backend/Device/DeviceInstallPreflight.swift").read_text().replace("import IDeviceSwift", "")
        source.write_text("\n".join((preflight, wrapper,
            (ROOT / "Ksign/Views/Signing/SigningPreflight.swift").read_text().replace("import IDeviceSwift", ""),
            (ROOT / "Native/Device/Tests/InstallPreflight.swift").read_text())))
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

        coordinator = (ROOT / "Ksign/Views/Signing/SigningPreflightCoordinator.swift").read_text()
        coordinator = "\n".join(line for line in coordinator.splitlines()
                               if line not in {"import CoreData", "import IDeviceSwift", "import NimbleExtensions", "import UIKit"})
        fixtures = (ROOT / "Native/Device/Tests/InstallPreflight.swift").read_text().replace(
            "@main struct InstallPreflightTests", "struct InstallPreflightTests")
        source.write_text("\n".join((preflight, wrapper,
            (ROOT / "Ksign/Views/Signing/SigningPreflight.swift").read_text().replace("import IDeviceSwift", ""),
            coordinator, fixtures, (ROOT / "Native/Device/Tests/SigningReview.swift").read_text())))
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library",
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

        source.write_text(queue_lifetime_source(load=True))
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
        source.write_text("\n".join((
            (ROOT / "Native/Device/Tests/NativeUploadProgress.swift").read_text(),
            swift_block(proxy, "public enum IDeviceUploadEvent:"),
            swift_block(proxy, "final class IDeviceInstallProgress"),
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
