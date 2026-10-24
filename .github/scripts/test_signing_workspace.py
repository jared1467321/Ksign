#!/usr/bin/env python3
"""Run the production Swift workspace validator, optionally against a local IPA."""
import argparse
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def signing_inputs(ipa, destination):
    """Materialize plists and Mach-O files as the sparse signing path does."""
    macho = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )}
    with zipfile.ZipFile(ipa) as archive:
        roots = sorted({str(PurePosixPath(entry.filename).parent)
                        for entry in archive.infolist()
                        if len(PurePosixPath(entry.filename).parts) == 3
                        and entry.filename.startswith("Payload/")
                        and entry.filename.endswith(".app/Info.plist")})
        if len(roots) != 1:
            raise ValueError("Expected one root Payload/*.app")
        prefix = roots[0] + "/"
        for entry in archive.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe archive path: " + entry.filename)
            if not entry.filename.startswith(prefix) or entry.is_dir():
                continue
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError("The optional IPA fixture must not contain links; links are tested separately")
            with archive.open(entry) as source:
                header = source.read(4)
                if path.name != "Info.plist" and header not in macho:
                    continue
                target = destination / entry.filename[len(prefix):]
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("wb") as output:
                    output.write(header)
                    shutil.copyfileobj(source, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-swift", action="store_true")
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--ipa", type=Path, help="Optional local regression IPA; never modified")
    args = parser.parse_args()
    if not args.swiftc:
        print("Swift workspace tests unavailable: swiftc is not installed.", flush=True)
        return 1 if args.require_swift else 0
    with tempfile.TemporaryDirectory(prefix="asign-workspace-tests-") as scratch:
        directory = Path(scratch)
        executable = directory / "workspace-tests"
        flags = ["-swift-version", "5"]
        if sys.platform == "darwin":
            flags += ["-target", platform.machine() + "-apple-macosx14.0"]
        subprocess.run([args.swiftc, *flags,
                        str(ROOT / "Asign/Utilities/Handlers/SigningWorkspace.swift"),
                        str(ROOT / "Tests/SigningWorkspace/main.swift"),
                        "-o", str(executable)], check=True)
        command = [str(executable)]
        if args.ipa:
            fixture = directory / "Uploaded.app"
            fixture.mkdir()
            signing_inputs(args.ipa, fixture)
            command.append(str(fixture))
        subprocess.run(command, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
