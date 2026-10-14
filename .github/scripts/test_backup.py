#!/usr/bin/env python3
"""Exercise production backup records and restore; macOS also checks real encryption."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("swiftc is required")
    sources = []
    for name in ("SettingsBackup.swift", "SettingsBackupCrypto.swift", "SettingsBackupService.swift"):
        source = (ROOT / "Ksign/Backend/Backup" / name).read_text()
        source = source.replace("import NimbleExtensions\n", "")
        if sys.platform != "darwin":
            source = source.replace("import CoreData\n", "").replace("NSSortDescriptor(", "BackupSortDescriptor(")
            source = source.replace(".completeFileProtectionUntilFirstUserAuthentication", ".atomic")
        sources.append(source)
    sources.append((ROOT / "Native/Backup/Tests.swift").read_text())
    with tempfile.TemporaryDirectory(prefix="asign-backup-tests-") as folder:
        directory = Path(folder)
        source = directory / "Backup.swift"
        source.write_text("\n".join(sources))
        executable = directory / "BackupTests"
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(directory / "modules"),
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == "__main__":
    main()
