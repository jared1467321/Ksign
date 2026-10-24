#!/usr/bin/env python3
"""Package the updated Asign app with its built-in device connection.

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


def bundle_identifier(bundle):
    with (bundle / "Info.plist").open("rb") as file:
        identifier = plistlib.load(file).get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier:
        raise RuntimeError(f"Missing bundle identifier: {bundle}")
    return identifier


def remove_obsolete_branding(app):
    # Restored DerivedData can keep extensions whose product names changed.
    # Remove only known obsolete copies, after checking the replacement exists
    # and has the same identity. Work on the staging copy, before re-signing.
    for old_name, new_name in (
        ("KsignDeviceTunnel.appex", "AsignDeviceTunnel.appex"),
        ("KsignLiveActivity.appex", "AsignLiveActivity.appex"),
    ):
        obsolete = app / "PlugIns" / old_name
        if not obsolete.exists():
            continue
        replacement = obsolete.with_name(new_name)
        if not replacement.is_dir():
            raise RuntimeError(f"Cannot remove obsolete extension without its replacement: {replacement}")
        if bundle_identifier(obsolete) != bundle_identifier(replacement):
            raise RuntimeError(f"Obsolete extension has a different identity from its replacement: {obsolete}")
        shutil.rmtree(obsolete)
    obsolete_icon = app / "ksign_extension.png"
    if (app / "asign_extension.png").is_file():
        obsolete_icon.unlink(missing_ok=True)


def validate_extension_identifiers(app):
    identifiers = {}
    for extension in sorted((app / "PlugIns").glob("*.appex")):
        identifier = bundle_identifier(extension)
        if identifier in identifiers:
            raise RuntimeError(f"Duplicate extension bundle identifier {identifier}: "
                               f"{identifiers[identifier].name} and {extension.name}")
        identifiers[identifier] = extension


def validate_patch_library(app):
    bundled = app / "asignpatch.dylib.bin"
    if not bundled.is_file():
        raise RuntimeError("The app is missing asignpatch.dylib.bin")
    data = bundled.read_bytes()
    if not all(marker in data for marker in (b"AsignPatch/v1\0", b"AsignCompatibilityPatch/v1\0",
                                             b"@rpath/asignpatch.dylib\0")):
        raise RuntimeError("The app is missing the built unified Asign compatibility patch")
    # Cached Xcode products may still contain the old resources. Only remove
    # these generated patch resources after validating their replacement.
    for name in ("blatantsPatch.dylib.bin", "asignIdentity.dylib.bin"):
        (app / name).unlink(missing_ok=True)


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
    with tempfile.TemporaryDirectory(prefix="asign-package-") as temporary:
        stage = Path(temporary)
        payload = stage / "Payload"
        payload.mkdir()
        copy = payload / app.name
        shutil.copytree(app, copy, symlinks=True)
        tunnel = copy / "PlugIns/AsignDeviceTunnel.appex"
        if not tunnel.is_dir():
            raise RuntimeError("The Xcode build did not embed AsignDeviceTunnel.appex")
        remove_obsolete_branding(copy)
        validate_extension_identifiers(copy)
        validate_patch_library(copy)
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
                command += ["--entitlements", str(ROOT / "AsignDeviceTunnel/AsignDeviceTunnel.entitlements")]
            elif bundle == copy:
                command += ["--entitlements", str(ROOT / "Asign/Supporting Files/BuiltInDevice.entitlements")]
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
