#!/usr/bin/env python3
"""Package the updated ASign app with its built-in device connection.

Ad-hoc signatures preserve entitlement requests for re-signers;
they do not authorize installation. Distribution still needs valid profiles.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def make_resignable(app):
    # Xcode embeds OpenSSL with mode 0555. Zsign opens code with O_RDWR, so
    # retaining that mode in the IPA makes a valid Mach-O fail to map on iOS.
    # Restore owner write access in the staging copy before signing/sealing.
    for path in [app, *app.rglob("*")]:
        if path.is_symlink():
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        mode |= stat.S_IRUSR | stat.S_IWUSR
        if path.is_dir():
            mode |= stat.S_IXUSR
        path.chmod(mode)


def validate_executables(bundles):
    magic = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    for bundle in bundles:
        with (bundle / "Info.plist").open("rb") as file:
            executable = plistlib.load(file).get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or Path(executable).name != executable:
            raise RuntimeError(f"Missing or invalid bundle executable: {bundle}")
        path = bundle / executable
        with path.open("rb") as file:
            header = file.read(4)
        if header not in magic:
            raise RuntimeError(f"Bundle executable is not Mach-O: {path}")
        if not path.stat().st_mode & stat.S_IWUSR:
            raise RuntimeError(f"Bundle executable is read-only and cannot be re-signed: {path}")


def package(app, output):
    with tempfile.TemporaryDirectory(prefix="ksign-package-") as temporary:
        stage = Path(temporary)
        payload = stage / "Payload"
        payload.mkdir()
        copy = payload / app.name
        shutil.copytree(app, copy, symlinks=True)
        tunnel = copy / "PlugIns/KsignDeviceTunnel.appex"
        if not tunnel.is_dir():
            raise RuntimeError("The Xcode build did not embed KsignDeviceTunnel.appex")
        for certificate in (ROOT / "deps").glob("*"):
            if certificate.is_file():
                shutil.copy2(certificate, copy / certificate.name)
        make_resignable(copy)
        bundles = sorted((p for p in copy.rglob("*") if p.suffix in (".framework", ".appex", ".app") and p.is_dir()),
                         key=lambda p: len(p.parts), reverse=True)
        validate_executables(bundles + [copy])
        for bundle in bundles + [copy]:
            command = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
            if bundle == tunnel:
                command += ["--entitlements", str(ROOT / "KsignDeviceTunnel/KsignDeviceTunnel.entitlements")]
            elif bundle == copy:
                command += ["--entitlements", str(ROOT / "Ksign/Supporting Files/BuiltInDevice.entitlements")]
            subprocess.run(command + [str(bundle)], check=True)
        validate_executables(bundles + [copy])
        destination = output / (app.stem + ".ipa")
        # zip updates existing archives; unlink only this generated output first
        # so removed resources cannot survive in a rebuilt IPA.
        destination.unlink(missing_ok=True)
        subprocess.run(["zip", "-qry", str(destination), "Payload"], cwd=stage, check=True)
        print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "packages")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    package(args.app.resolve(), output)


if __name__ == "__main__":
    main()
