#!/usr/bin/env python3
"""Native signing checks on Linux; requires a built minizip-ng and OpenSSL.

python3 ZsignLatest/Tests/run_signing_regressions.py \
    --minizip-source /path/to/minizip-ng --minizip-build /path/to/minizip-ng/build

Pass --sanitize to enable AddressSanitizer and UndefinedBehaviorSanitizer.
"""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
APP = "Payload/Test.app"


def macho(filetype=2, code_size=4096, signature_size=32768):
    text = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__TEXT", 0, code_size,
                       0, code_size, 7, 5, 0, 0)
    link = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__LINKEDIT", code_size,
                       signature_size, code_size, signature_size, 7, 1, 0, 0)
    signature = struct.pack("<IIII", 0x1D, 16, code_size, signature_size)
    commands = text + link + signature
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, filetype,
                         3, len(commands), 0, 0)
    return (header + commands).ljust(code_size, b"\0") + bytes(signature_size)


def fixture(path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        def add(name, data, symlink=False):
            entry = zipfile.ZipInfo(APP + "/" + name)
            entry.create_system = 3
            entry.external_attr = ((stat.S_IFLNK | 0o777) if symlink else
                                   (stat.S_IFREG | 0o755)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)

        def bundle(folder, executable, identifier, versioned=False):
            prefix = folder + "/" if folder else ""
            physical = prefix + "Versions/A/" if versioned else prefix
            add(physical + "Info.plist", plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundleVersion": "1", "CFBundleName": executable,
            }))
            # Force signature growth through a framework executable symlink.
            add(physical + executable, macho(6 if folder.endswith(".framework") else 2,
                                            1024 * 1024 if not folder else 4096,
                                            16 if versioned else 32768))
            for index in range(12):
                add(physical + f"resource-{index}.dat", bytes([index]) * 10000)
            if versioned:
                add(prefix + "Versions/Current", b"A", True)
                add(prefix + executable, f"Versions/Current/{executable}".encode(), True)
                add(prefix + "Info.plist", b"Versions/Current/Info.plist", True)

        bundle("", "Main", "test.main")
        bundle("Frameworks/F.framework", "F", "test.framework")
        bundle("PlugIns/E.appex", "Ext", "test.extension")
        bundle("PlugIns/E.appex/Frameworks/N.framework", "N", "test.nested")
        bundle("Frameworks/V.framework", "V", "test.versioned", True)
        add("Standalone.dylib", macho(6))
        add("root.dat", b"root resource")
        add("alias", b"root.dat", True)
        add("Deleted/old.dat", b"must not reappear")
        add("embedded.mobileprovision", b"old profile")
        add("_CodeSignature/obsolete", b"old signature")
        # Exercise rehashing of the archive membership set across many entries.
        for index in range(2048):
            add(f"Resources/{index}.dat", str(index).encode())
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            add("root.dat", b"last duplicate wins")


def verify_signature(data, info, resources):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    command = 32
    for _ in range(ncmds):
        kind, size = struct.unpack_from("<II", data, command)
        if kind == 0x1D:
            signature_offset = struct.unpack_from("<I", data, command + 8)[0]
            break
        command += size
    else:
        raise AssertionError("missing signature load command")
    magic, _, count = struct.unpack_from(">III", data, signature_offset)
    assert magic == 0xFADE0CC0
    directories = 0
    for index in range(count):
        kind, offset = struct.unpack_from(">II", data, signature_offset + 12 + index * 8)
        if kind not in (0, 0x1000):
            continue
        base = signature_offset + offset
        assert struct.unpack_from(">I", data, base)[0] == 0xFADE0C02
        hash_offset, _, special, pages, code_limit = struct.unpack_from(">IIIII", data, base + 16)
        hash_size, hash_type, _, page_power = struct.unpack_from("4B", data, base + 36)
        digest = hashlib.sha1 if hash_type == 1 else hashlib.sha256
        page_size = 1 << page_power
        for page in range(pages):
            expected = digest(data[page * page_size:min((page + 1) * page_size, code_limit)]).digest()
            begin = base + hash_offset + page * hash_size
            assert data[begin:begin + hash_size] == expected
        for slot, contents in ((1, info), (3, resources)):
            if special >= slot:
                expected = digest(contents).digest() if contents is not None else bytes(hash_size)
                begin = base + hash_offset - slot * hash_size
                assert data[begin:begin + hash_size] == expected
        directories += 1
    assert directories == 2


def verify_archive(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert len(names) == len(set(names))
        assert archive.read(APP + "/root.dat") == b"last duplicate wins"
        assert not any("/Deleted/" in name or name.endswith("/obsolete") or
                       name.endswith("/embedded.mobileprovision") for name in names)
        assert archive.read(APP + "/Frameworks/V.framework/V") == b"Versions/Current/V"
        assert stat.S_ISLNK(archive.getinfo(APP + "/Frameworks/V.framework/V").external_attr >> 16)
        for name in names:
            if not name.endswith("/_CodeSignature/CodeResources"):
                continue
            folder = name.removesuffix("/_CodeSignature/CodeResources")
            seal = plistlib.loads(archive.read(name))
            for key, value in seal["files"].items():
                value = value["hash"] if isinstance(value, dict) else value
                assert hashlib.sha1(archive.read(folder + "/" + key)).digest() == value, key
            for key, value in seal["files2"].items():
                data = archive.read(folder + "/" + key)
                if "symlink" in value:
                    assert data.decode() == value["symlink"]
                else:
                    assert hashlib.sha1(data).digest() == value["hash"], key
                    assert hashlib.sha256(data).digest() == value["hash2"], key
            info_name = folder + "/Info.plist"
            info_data = archive.read(info_name)
            if info_data.startswith(b"Versions/"):
                info_data = archive.read(folder + "/Versions/A/Info.plist")
            executable = plistlib.loads(info_data)["CFBundleExecutable"]
            executable_data = archive.read(folder + "/" + executable)
            if executable_data.startswith(b"Versions/"):
                executable_data = archive.read(folder + "/Versions/A/" + executable)
            verify_signature(executable_data, info_data, archive.read(name))
        for name in ("Standalone.dylib", "Injected.dylib"):
            verify_signature(archive.read(APP + "/" + name), None, None)
        return {name: archive.read(name) for name in names if not name.endswith("/")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minizip-source", type=Path, required=True)
    parser.add_argument("--minizip-build", type=Path, required=True)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    repository = ROOT.parent
    core = ROOT / "Sources/ZsignC/Core"
    archive = repository / "ASignArchiveKit/Sources/CASignArchive"
    includes = [f"-I{path}" for path in (core, core / "common", archive / "include",
                                        args.minizip_source, args.minizip_build)]
    flags = ["-g", "-O1"]
    if args.sanitize:
        flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    with tempfile.TemporaryDirectory(prefix="ksign-signing-regressions-") as directory:
        work = Path(directory)
        subprocess.run(["cc", "-std=gnu11", *flags, *includes, "-c", str(archive / "CASignArchive.c"),
                        "-o", str(work / "archive.o")], check=True)
        sources = [core / name for name in ("archo.cpp", "bundle.cpp", "macho.cpp",
                                            "openssl.cpp", "signing.cpp", "common/fs.cpp",
                                            "common/json.cpp", "common/log.cpp",
                                            "common/sha.cpp", "common/util.cpp")]
        executable = work / "signing-regressions"
        subprocess.run(["g++", "-std=c++17", "-pthread", *flags, *includes,
                        str(ROOT / "Tests/signing_regressions.cpp"), *map(str, sources),
                        str(work / "archive.o"), str(args.minizip_build / "libminizip.a"),
                        "-Wl,--wrap=mz_zip_entry_read_open", "-lssl", "-lcrypto", "-lz",
                        "-Wl,--wrap=mz_zip_reader_open_file",
                        "-o", str(executable)], check=True)
        source = work / "source.ipa"
        fixture(source)
        results = []
        for workers, filesystem, relative in (("1", False, False), ("4", False, False),
                                               ("4", True, False), ("4", True, True)):
            label = f"{workers}-{'filesystem' if filesystem else 'sparse'}"
            if relative:
                label += "-relative"
            overlay = work / f"overlay-{label}.app"
            overlay.mkdir()
            if filesystem:
                with zipfile.ZipFile(source) as archive:
                    for entry in archive.infolist():
                        target = overlay / entry.filename.removeprefix(APP + "/")
                        target.parent.mkdir(parents=True, exist_ok=True)
                        if target.exists() or target.is_symlink():
                            target.unlink()
                        if stat.S_ISLNK(entry.external_attr >> 16):
                            target.symlink_to(archive.read(entry).decode())
                        else:
                            target.write_bytes(archive.read(entry))
            destination = work / f"signed-{label}.ipa"
            command = [str(executable), str(source), str(destination),
                       overlay.name if relative else str(overlay), APP]
            if filesystem:
                command.append("--filesystem")
            run = subprocess.run(command,
                                 env={**os.environ, "ZSIGN_WORKERS": workers}, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=work)
            assert run.returncode == 0, run.stdout + run.stderr
            standalone_logs = [line for line in run.stdout.splitlines() if ">>> SignFile:" in line]
            assert len(standalone_logs) == 4, standalone_logs
            assert all(line.endswith(("Standalone.dylib", "Injected.dylib")) for line in standalone_logs)
            results.append(verify_archive(destination))
        assert results[0] == results[1], "Serial and parallel signing must emit identical contents"
        assert results[1] == results[2], "Sparse and filesystem signing must emit identical contents"
        assert results[2] == results[3], "Relative and absolute paths must emit identical contents"
    print("Passed worker reuse/concurrency, single executable signing, hash reuse, signature/page hashes,")
    print("nested seals, versioned framework links/growth, sparse additions, duplicate ZIP entries and deletions.")


if __name__ == "__main__":
    main()
