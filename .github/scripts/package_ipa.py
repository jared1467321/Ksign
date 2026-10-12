#!/usr/bin/env python3
"""Package the updated ASign app with its built-in device connection.

Ad-hoc signatures preserve entitlement requests for re-signers;
they do not authorize installation. Distribution still needs valid profiles.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


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
        bundles = sorted((p for p in copy.rglob("*") if p.suffix in (".framework", ".appex", ".app") and p.is_dir()),
                         key=lambda p: len(p.parts), reverse=True)
        for bundle in bundles + [copy]:
            command = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
            if bundle == tunnel:
                command += ["--entitlements", str(ROOT / "KsignDeviceTunnel/KsignDeviceTunnel.entitlements")]
            elif bundle == copy:
                command += ["--entitlements", str(ROOT / "Ksign/Supporting Files/BuiltInDevice.entitlements")]
            subprocess.run(command + [str(bundle)], check=True)
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
