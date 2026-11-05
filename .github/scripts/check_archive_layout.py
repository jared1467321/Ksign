#!/usr/bin/env python3
"""Check IPA directory rebuilding and metadata-only output validation.

Requires cc, OpenSSL/zlib headers, a local minizip-ng checkout, and Swift.
No dependencies are downloaded. --benchmark reads an existing IPA without
changing it; timings cover only the metadata validation added to export.
"""

import argparse
import ctypes
import hashlib
from pathlib import Path
import plistlib
import shutil
import stat
import statistics
import struct
import subprocess
import tempfile
import time
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
APP = "Payload/Layout.app/"


def build(work, minizip, swiftc):
    native = ROOT / "ASignArchiveKit/Sources/CASignArchive"
    sources = ["mz_crypt", "mz_os", "mz_strm", "mz_strm_buf", "mz_strm_mem",
               "mz_strm_split", "mz_strm_zlib", "mz_zip", "mz_zip_rw",
               "mz_os_posix", "mz_strm_os_posix"]
    library = work / "libArchiveLayout.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-std=gnu11", "-DHAVE_ZLIB=1",
                    "-DZLIB_COMPAT=1", "-DMZ_ZIP_NO_ENCRYPTION", "-DMZ_ZIP_NO_CRYPTO",
                    "-I", str(minizip), "-I", str(minizip / "include"),
                    "-I", str(native / "include"), str(native / "CASignArchive.c"),
                    *[str(minizip / (s + ".c")) for s in sources],
                    "-lz", "-lcrypto", "-lpthread", "-o", str(library)], check=True)
    (work / "module.modulemap").write_text(
        f'module CASignArchive {{ header "{native}/include/CASignArchive.h" export * }}\n')
    (work / "main.swift").write_text(r'''
import Foundation
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
let input = URL(fileURLWithPath: CommandLine.arguments[2])
switch CommandLine.arguments[1] {
case "validate":
    try ASignArchive.validateLayout(of: input)
case "reject":
    do {
        try ASignArchive.validateLayout(of: input)
        fatalError("Invalid layout accepted")
    } catch ASignArchiveError.layoutValidationFailed(let code, let entry) {
        precondition(code == -1001 && entry == CommandLine.arguments[3])
        precondition(errorDescription(code: code, entry: entry).contains(entry))
    }
case "rebuild":
    try ASignArchive.rebuildWithOverlay(from: input,
        at: URL(fileURLWithPath: CommandLine.arguments[3]), rootAppPath: "Payload/Layout.app",
        overlayAppURL: URL(fileURLWithPath: CommandLine.arguments[4]), compression: .none)
case "reject-output":
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    do {
        try ASignArchive.rebuildWithOverlay(from: input, at: output, rootAppPath: "Payload/Layout.app",
            overlayAppURL: URL(fileURLWithPath: CommandLine.arguments[4]), compression: .none)
        fatalError("Malformed output accepted")
    } catch ASignArchiveError.layoutValidationFailed(let code, let entry) {
        precondition(code == -1001 && entry == "descriptor.bin")
        precondition(!FileManager.default.fileExists(atPath: output.path))
    }
case "create":
    try ASignArchive.create(from: input, at: URL(fileURLWithPath: CommandLine.arguments[3]),
        compression: .none)
default: fatalError("Unknown mode")
}
func errorDescription(code: Int32, entry: String) -> String {
    ASignArchiveError.layoutValidationFailed(code: code, entry: entry).localizedDescription
}
''')
    subprocess.run([str(swiftc), "-module-cache-path", str(work / "module-cache"),
                    "-I", str(work), "-L", str(work), "-lArchiveLayout",
                    "-Xlinker", "-rpath", "-Xlinker", str(work),
                    str(ROOT / "ASignArchiveKit/Sources/ASignArchiveKit/ASignArchiveKit.swift"),
                    str(work / "main.swift"), "-o", str(work / "swift-check")], check=True)
    lib = ctypes.CDLL(str(library))
    lib.asign_archive_validate_layout.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.asign_archive_validate_layout.restype = ctypes.c_int32
    lib.asign_archive_rebuild_with_overlay.argtypes = [ctypes.c_char_p] * 5 + [
        ctypes.c_uint8, ctypes.c_int16, ctypes.c_void_p, ctypes.c_void_p]
    lib.asign_archive_rebuild_with_overlay.restype = ctypes.c_int32
    return lib


def validate(lib, path, expected=0, entry=None):
    name = ctypes.create_string_buffer(4096)
    result = lib.asign_archive_validate_layout(str(path).encode(), name, len(name))
    assert result == expected, (path, result, name.value)
    if entry is not None:
        assert name.value.decode() == entry, (name.value, entry)


def fixture(path, method):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(APP + "Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "test.layout", "CFBundleExecutable": "Layout"}))
        for relative in ("", "Frameworks/", "Frameworks/Empty/"):
            info = zipfile.ZipInfo(APP + relative, (2020, 5, 6, 7, 8, 10))
            info.create_system = 3
            info.external_attr = (stat.S_IFDIR | 0o750) << 16 | 0x10
            info.compress_type = method
            archive.writestr(info, b"")
        archive.writestr(APP + "Layout", b"executable-content" * 1000)
        archive.writestr(APP + "Frameworks/library.dylib", b"library-content" * 1000)
        archive.writestr(APP + "replace.txt", b"old")
        for relative, target in (("Frameworks/link.dylib", b"library.dylib"),
                                 ("Frameworks/folder-link", b"Empty")):
            info = zipfile.ZipInfo(APP + relative)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, target)


def compressed_payload(path, entry):
    with path.open("rb") as stream:
        stream.seek(entry.header_offset)
        header = stream.read(30)
        name, extra = struct.unpack_from("<HH", header, 26)
        stream.seek(name + extra, 1)
        return stream.read(entry.compress_size)


def check_rebuild(lib, work):
    overlay = work / "overlay"
    overlay.mkdir()
    (overlay / "replace.txt").write_bytes(b"new")
    (overlay / "added.txt").write_bytes(b"added")
    (overlay / "added-link").symlink_to("added.txt")
    for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        source = work / f"source-{method}.ipa"
        fixture(source, method)
        validate(lib, source)
        for level in (0, 1, -1, 9):
            output = work / f"output-{method}-{level}.ipa"
            result = lib.asign_archive_rebuild_with_overlay(
                str(source).encode(), str(output).encode(), APP.rstrip("/").encode(),
                str(overlay).encode(), b"", 0, level, None, None)
            assert result == 0, result
            validate(lib, output)
            with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as rebuilt:
                assert rebuilt.testzip() is None
                for entry in original.infolist():
                    result = rebuilt.getinfo(entry.filename)
                    if entry.is_dir():
                        assert result.compress_type == zipfile.ZIP_STORED
                        assert result.compress_size == result.file_size == result.CRC == 0
                        assert result.external_attr == entry.external_attr
                        assert result.date_time == entry.date_time
                    elif entry.filename != APP + "replace.txt":
                        assert rebuilt.read(result) == original.read(entry)
                        assert result.external_attr == entry.external_attr
                        assert result.compress_type == entry.compress_type
                        assert compressed_payload(source, entry) == compressed_payload(output, result)
                assert rebuilt.read(APP + "replace.txt") == b"new"
                assert rebuilt.read(APP + "added.txt") == b"added"
                assert rebuilt.read(APP + "added-link") == b"added.txt"
            subprocess.run(["unzip", "-t", str(output)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(work / "swift-check"), "rebuild", str(source),
                        str(work / f"swift-{method}.ipa"), str(overlay)], check=True)
    payload = work / "Payload"
    (payload / "Empty").mkdir(parents=True)
    (payload / "data").write_bytes(b"data")
    (payload / "link").symlink_to("data")
    created = work / "created.ipa"
    subprocess.run([str(work / "swift-check"), "create", str(payload), str(created)], check=True)
    validate(lib, created)
    with zipfile.ZipFile(created) as archive:
        assert archive.testzip() is None
    print("PASS folder compression, all export levels, metadata, raw file bytes, symlinks, Swift create/rebuild")


def descriptor_fixture(path, wide, signed):
    # Streaming writers can use unsigned descriptors and local ZIP64 sizes
    # even when the final compressed payload fits in a 32-bit central record.
    name, data = b"descriptor.bin", b"descriptor-content" * 40
    compressor = zlib.compressobj(wbits=-15)
    payload = compressor.compress(data) + compressor.flush()
    crc = zlib.crc32(data)
    extra = struct.pack("<HHQQ", 1, 16, 0, 0) if wide else b""
    local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 45 if wide else 20, 8, 8, 0, 0,
                        0, 0xFFFFFFFF if wide else 0, 0xFFFFFFFF if wide else 0, len(name), len(extra))
    descriptor = (struct.pack("<I", 0x08074B50) if signed else b"") + struct.pack(
        "<IQQ" if wide else "<III", crc, len(payload), len(data))
    central = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 8, 8, 0, 0,
                          crc, len(payload), len(data), len(name), 0, 0, 0, 0, 0, 0) + name
    prefix = local + name + extra + payload + descriptor
    path.write_bytes(prefix + central + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1,
                                                   len(central), len(prefix), 0))
    return len(prefix) - len(descriptor)


def check_validation(lib, work):
    source = work / "source-8.ipa"
    with zipfile.ZipFile(source) as archive:
        first = archive.getinfo(APP + "Info.plist")
        last = archive.infolist()[-1]
        central = {}
        position = archive.start_dir
        for entry in archive.infolist():
            central[entry.filename] = position
            position += 46 + len(entry.filename.encode()) + len(entry.extra) + len(entry.comment)
        folder = archive.getinfo(APP + "Frameworks/")
        variants = {
            "flow-folder": (APP + "Frameworks/", [(folder.header_offset + 8, "<H", 0),
                (central[folder.filename] + 10, "<H", 0)]),
            "overlap": (first.filename, [(first.header_offset + 18, "<I", first.compress_size + 1),
                (central[first.filename] + 20, "<I", first.compress_size + 1)]),
            "out-of-bounds": (last.filename, [(central[last.filename] + 20, "<I", 100000)]),
            "local-magic": (first.filename, [(first.header_offset, "<I", 0)]),
            "local-method": (first.filename, [(first.header_offset + 8, "<H", 0)]),
            "header-range": (last.filename, [(last.header_offset + 28, "<H", 65535)]),
            "local-offset": (last.filename, [(central[last.filename] + 42, "<I", archive.start_dir - 10)]),
        }
    for label, (entry, patches) in variants.items():
        damaged = bytearray(source.read_bytes())
        for offset, form, value in patches:
            struct.pack_into(form, damaged, offset, value)
        path = work / f"invalid-{label}.ipa"
        path.write_bytes(damaged)
        validate(lib, path, -1001, entry)
        subprocess.run([str(work / "swift-check"), "reject", str(path), entry], check=True)
    for wide in (False, True):
        for signed in (False, True):
            path = work / f"descriptor-{wide}-{signed}.zip"
            offset = descriptor_fixture(path, wide, signed)
            validate(lib, path)
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
            broken = bytearray(path.read_bytes())
            broken[offset + (4 if signed else 0)] ^= 1
            path.write_bytes(broken)
            validate(lib, path, -1001, "descriptor.bin")
    # A raw source descriptor can disagree with the central directory. Ensure
    # a successful native copy cannot publish the resulting overlapping output.
    path = work / "bad-output-source.zip"
    offset = descriptor_fixture(path, False, True)
    broken = bytearray(path.read_bytes())
    size = struct.unpack_from("<I", broken, offset + 8)[0]
    struct.pack_into("<I", broken, offset + 8, size + 1)
    path.write_bytes(broken)
    subprocess.run([str(work / "swift-check"), "reject-output", str(path),
                    str(work / "bad-output.ipa"), str(work / "overlay")], check=True)
    print("PASS corrupt folder, overlaps, bounds, local headers, 32/64-bit descriptors, error paths and output cleanup")


def check_real_ipa(lib, work, source):
    overlay = work / "real-overlay"
    overlay.mkdir()
    output = work / "real-rebuilt.ipa"
    with zipfile.ZipFile(source) as original:
        roots = [e.filename[:-len("/Info.plist")] for e in original.infolist()
                 if e.filename.startswith("Payload/") and e.filename.count("/") == 2
                 and e.filename.endswith(".app/Info.plist")]
        assert len(roots) == 1, roots
        # Retain the signed contents: this exercises only archive rebuilding.
        status = lib.asign_archive_rebuild_with_overlay(str(source).encode(), str(output).encode(),
            roots[0].encode(), str(overlay).encode(), b"", 0, 0, None, None)
        assert status == 0, status
        validate(lib, output)
        with zipfile.ZipFile(output) as rebuilt:
            assert rebuilt.testzip() is None
            assert set(original.namelist()) == set(rebuilt.namelist())
            count = 0
            for entry in original.infolist():
                if entry.is_dir():
                    continue
                with original.open(entry) as before, rebuilt.open(entry.filename) as after:
                    assert hashlib.file_digest(before, "sha256").digest() == hashlib.file_digest(after, "sha256").digest()
                count += 1
        subprocess.run(["unzip", "-t", str(output)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(work / "swift-check"), "validate", str(output)], check=True)
    print(f"PASS {source.name}: rebuilt IPA passes integrity checks; all {count} file contents unchanged")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minizip-source", type=Path, required=True)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or str(ROOT / ".build/swift-toolchain/usr/bin/swiftc"))
    parser.add_argument("--benchmark", type=Path, action="append", default=[])
    parser.add_argument("--ipa", type=Path, help="Rebuild a real IPA and verify every file without modifying the source")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ksign-archive-layout-") as temporary:
        work = Path(temporary)
        lib = build(work, args.minizip_source.resolve(), args.swiftc)
        check_rebuild(lib, work)
        check_validation(lib, work)
        if args.ipa:
            check_real_ipa(lib, work, args.ipa.resolve())
        for path in args.benchmark:
            times = []
            for _ in range(5):
                start = time.perf_counter()
                validate(lib, path)
                times.append((time.perf_counter() - start) * 1000)
            with zipfile.ZipFile(path) as archive:
                count = len(archive.infolist())
            print(f"BENCHMARK {path.name}: {path.stat().st_size:,} bytes, {count:,} entries; "
                  f"first {times[0]:.2f} ms, median {statistics.median(times):.2f} ms")


if __name__ == "__main__":
    main()
