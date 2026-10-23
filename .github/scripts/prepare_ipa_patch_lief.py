#!/usr/bin/env python3
"""Fetch a pinned, SHA256-checked LIEF SDK for header growth or host tests."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Native/IPAPatch/lief.json"
PREPARATION_VERSION = b"ios-null-logger-v1"


def patch_ios_logging(library):
    """Keep the pinned iOS SDK's lazy logger inside the sandbox.

    Even logging.disable()/set_path()/set_logger() first construct LIEF's
    default logger. Its /tmp/lief.log cannot be opened by an iOS app, and the
    SDK's exception-free spdlog calls abort() on that failure. Redirect its
    single default filename to /dev/null before linking. Equal-length bytes
    preserve the archive index, Mach-O sections, symbols and relocations.
    """
    original = b"/tmp/lief.log\0"
    replacement = b"/dev/null\0".ljust(len(original), b"\0")
    data = library.read_bytes()
    if data.count(original) != 1:
        raise RuntimeError("Unexpected iOS LIEF default log path; review the pinned SDK before linking")
    library.write_bytes(data.replace(original, replacement))


def prepare(target="host"):
    config = json.loads(CONFIG.read_text())
    host = platform.system() + "-" + platform.machine().replace("AMD64", "x86_64")
    key = "ios-arm64" if target == "ios" else host
    archive = config["archives"][key]
    destination = ROOT / ".build/ipa-patch-lief" / target
    fingerprint = hashlib.sha256(CONFIG.read_bytes() + key.encode() + PREPARATION_VERSION).hexdigest()
    stamp = destination / ".version"
    if stamp.is_file() and stamp.read_text() == fingerprint and (destination / "lib/libLIEF.a").is_file():
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lief-", dir=destination.parent) as temporary:
        temporary = Path(temporary)
        downloaded = temporary / archive["name"]
        request = urllib.request.Request(config["release"] + "/" + archive["name"],
                                         headers={"User-Agent": "Asign-IPAPatch"})
        with urllib.request.urlopen(request, timeout=90) as source, downloaded.open("wb") as output:
            shutil.copyfileobj(source, output)
        if hashlib.sha256(downloaded.read_bytes()).hexdigest() != archive["sha256"]:
            raise RuntimeError("The LIEF SDK checksum does not match the pinned release")
        staged = temporary / "sdk"
        staged.mkdir()
        with tarfile.open(downloaded) as package:
            for member in package:
                parts = PurePosixPath(member.name).parts
                if not parts or any(part == ".." for part in parts) or PurePosixPath(member.name).is_absolute():
                    raise RuntimeError("Unsafe LIEF SDK member")
                # SDK releases place include/lib below one versioned directory.
                relative = PurePosixPath(*parts[1:])
                if not member.isfile() or not (str(relative).startswith("include/") or str(relative) == "lib/libLIEF.a"):
                    continue
                output = staged.joinpath(*relative.parts)
                output.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as source, output.open("wb") as stream:
                    shutil.copyfileobj(source, stream)
        if not (staged / "lib/libLIEF.a").is_file() or not (staged / "include/LIEF/MachO.hpp").is_file():
            raise RuntimeError("The LIEF SDK does not contain the required headers and static library")
        if target == "ios":
            patch_ios_logging(staged / "lib/libLIEF.a")
        (staged / ".version").write_text(fingerprint)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(staged, destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("ios", "host"), default="host")
    print(prepare(parser.parse_args().target))
