#!/usr/bin/env python3
"""Exercise literal POSIX archive filenames through import and resource sealing.

Requires Linux, cc/c++, OpenSSL/zlib development headers, and Swift 6. Pass a
SideStore/minizip-ng checkout with --minizip-source; no dependencies are fetched.
--ipa additionally checks a real IPA without modifying it. No certificate or
iOS device is required: this checks CodeResources generation, not installation.
"""

import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]

SWIFT_MAIN = r'''
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let mode = CommandLine.arguments[3]
if mode == "reject" {
    do { _ = try ArchiveBackedApp(archiveURL: source) }
    catch ASignArchiveError.entryAccessFailed(let code) {
        precondition(code == -103)
        exit(0)
    }
    catch ArchiveBackedAppError.unsafePath(_) { exit(0) }
    fatalError("Unsafe archive accepted")
}
let archive = try ArchiveBackedApp(archiveURL: source)
let metadata = try archive.metadata()
precondition(metadata.identifier != nil && metadata.executable != nil)
let sparse = output.appendingPathComponent("sparse", isDirectory: true)
if mode == "rebuild" {
    try ASignArchive.rebuildWithOverlay(from: source,
        at: output.appendingPathComponent("rebuilt.ipa"), rootAppPath: archive.rootAppPath,
        overlayAppURL: sparse, index: archive.archiveIndex)
} else {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for path in archive.paths() where path.contains("\\") && !path.hasSuffix("/") {
        guard let data = try archive.data(relativePath: path) else { fatalError(path) }
        let extracted = output.appendingPathComponent("selected/" + path)
        let didExtract = try archive.extract(relativePath: path, to: extracted)
        let extractedData = try Data(contentsOf: extracted)
        let resourceData = try archive.resourceData(named: path)
        precondition(didExtract && extractedData == data && resourceData == data)
        let tree = output.appendingPathComponent("tree/" + path)
        let didExtractTree = try archive.extractTree(relativePath: path, to: tree)
        let treeData = try Data(contentsOf: tree)
        precondition(didExtractTree && treeData == data)
    }
    let digests = try ASignArchive.materializeSigningInputs(from: source,
        rootAppPath: archive.rootAppPath, to: sparse, index: archive.archiveIndex,
        workers: 3, hashResources: true)
    try digests!.write(to: output.appendingPathComponent("digests.bin"))
    if mode == "full" {
        try archive.extractRootApp(to: output.appendingPathComponent("full"))
    }
}
'''

CPP_MAIN = r'''
#include "common.h"
#include "json.h"
#include "openssl.h"
// Exercise the shipping index and seal writer without needing signing credentials.
#define private public
#include "bundle.h"
#undef private
#include "CASignArchive.h"
#include <fstream>
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    asign_archive_index *index = nullptr;
    if (asign_archive_index_open(argv[1], &index) != 0) return 3;
    size_t size = 0;
    const uint8_t *bytes = asign_archive_index_manifest(index, &size);
    string manifest((const char *)bytes, size);
    asign_archive_index_close(index);
    string digests;
    if (!ZFile::ReadFile((string(argv[5]) + "/digests.bin").c_str(), digests)) return 6;
    ZBundle deletion;
    deletion.SetArchiveBacking(argv[1], argv[2], {"literal\\resource"});
    if (!deletion.IsArchiveDeleted("literal\\resource") ||
        deletion.IsArchiveDeleted("literal/resource")) return 7;
    for (int mode = 0; mode < 3; mode++) {
        ZBundle bundle;
        bundle.m_strAppFolder = argv[3];
        bundle.SetArchiveBacking(argv[1], argv[2], {}, mode ? manifest : "",
            mode == 2 ? digests : "");
        if (!bundle.BuildFileIndex()) return 4;
        string resources;
        if (!bundle.GenerateCodeResources(argv[3], argv[4], resources)) return 5;
        std::ofstream output(string(argv[5]) + "/seal-" + std::to_string(mode) + ".plist");
        output << resources;
    }
}
'''


def run(command, **kwargs):
    subprocess.run([str(value) for value in command], check=True, **kwargs)


def build(work, minizip, swiftc):
    native = ROOT / "ASignArchiveKit/Sources/CASignArchive"
    core = ROOT / "ZsignLatest/Sources/ZsignC/Core"
    sources = ["mz_crypt", "mz_os", "mz_strm", "mz_strm_buf", "mz_strm_mem",
               "mz_strm_split", "mz_strm_zlib", "mz_zip", "mz_zip_rw",
               "mz_os_posix", "mz_strm_os_posix"]
    includes = ["-I", minizip, "-I", minizip / "include", "-I", native / "include"]
    library = work / "libASignArchiveNative.so"
    run(["cc", "-shared", "-fPIC", "-std=gnu11", "-DHAVE_ZLIB=1", "-DZLIB_COMPAT=1",
         "-DMZ_ZIP_NO_ENCRYPTION", "-DMZ_ZIP_NO_CRYPTO", *includes,
         native / "CASignArchive.c", *[minizip / (s + ".c") for s in sources],
         "-lz", "-lcrypto", "-lpthread", "-o", library])
    (work / "module.modulemap").write_text(
        f'module CASignArchive {{ header "{native}/include/CASignArchive.h" export * }}\n')
    swift_flags = ["-module-cache-path", work / "module-cache",
                   "-I", work, "-L", work, "-lASignArchiveNative",
                   "-Xlinker", "-rpath", "-Xlinker", work]
    # Linux Foundation has no Objective-C autorelease pool. This helper only
    # surrounds the package's unrelated disk-size enumerator.
    (work / "AutoreleasePool.swift").write_text(
        'func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }\n')
    run([swiftc, "-emit-library", "-emit-module", "-module-name", "ASignArchiveKit",
         ROOT / "ASignArchiveKit/Sources/ASignArchiveKit/ASignArchiveKit.swift",
         work / "AutoreleasePool.swift",
         *swift_flags, "-o", work / "libASignArchiveKit.so"], cwd=work)
    storage = (ROOT / "Asign/Backend/Storage/Storage+Shared.swift").read_text()
    # Only the UI-independent archive abstraction is compiled here. The memory
    # workload descriptor is unused by the test and has no archive behavior.
    abstraction = storage.split("// MARK: - Archive-backed app abstraction\n", 1)[1]
    abstraction = abstraction.split("/// An operation-local journal", 1)[0]
    stub = '''
import Foundation
import ASignArchiveKit
struct ArchiveWorkload {
    enum Operation { case signing }
    let operation: Operation
    var entries = 0
    var pathBytes = 0.0
    var uncompressedBytes = 0.0
    var residentBytes = 0.0
}
'''
    (work / "main.swift").write_text(stub + abstraction + SWIFT_MAIN)
    run([swiftc, work / "main.swift", *swift_flags, "-lASignArchiveKit",
         "-o", work / "import-check"])
    (work / "resources.cpp").write_text(CPP_MAIN)
    run(["c++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
         "-Wl,--gc-sections", *includes, "-I", core, "-I", core / "common",
         work / "resources.cpp", core / "bundle.cpp",
         *[core / "common" / (s + ".cpp") for s in ["fs", "json", "sha", "util", "log"]],
         library, "-lcrypto", "-lz", "-lpthread", "-o", work / "resource-check"])


def check_ipa(work, ipa, label, full=False):
    output = work / label
    with zipfile.ZipFile(ipa) as archive:
        roots = sorted(i.filename.rsplit("/", 1)[0] for i in archive.infolist()
                       if i.filename.startswith("Payload/") and i.filename.count("/") == 2
                       and i.filename.endswith(".app/Info.plist"))
        root = roots[0]
        info = plistlib.loads(archive.read(root + "/Info.plist"))
        special = [i for i in archive.infolist()
                   if i.filename.startswith(root + "/") and "\\" in i.filename and not i.is_dir()]
        assert special, "The regression IPA must contain a literal backslash filename"
        run([work / "import-check", ipa, output, "full" if full else "prepare"])
        for entry in special:
            relative = entry.filename[len(root) + 1:]
            assert (output / "selected" / relative).read_bytes() == archive.read(entry)
        # Check native precomputed hashes against an independent ZIP decoder.
        data = (output / "digests.bin").read_bytes()
        assert data[:8] == b"ASHSH001" and (len(data) - 8) % 60 == 0
        hashes = {position: (sha1, sha256) for position, sha1, sha256
                  in struct.iter_unpack("<Q20s32s", data[8:])}
        # Native positions refer to central-directory records, not local headers.
        position = archive.start_dir
        positions = {}
        for entry in archive.infolist():
            positions[entry.filename] = position
            with ipa.open("rb") as source:
                source.seek(position + 28)
                name, extra, comment = struct.unpack("<HHH", source.read(6))
            position += 46 + name + extra + comment
        for entry in special:
            contents = archive.read(entry)
            assert hashes[positions[entry.filename]] == (
                hashlib.sha1(contents).digest(), hashlib.sha256(contents).digest())
        run([work / "resource-check", ipa, root, output / "sparse",
             info["CFBundleExecutable"], output])
        seals = [plistlib.loads((output / f"seal-{mode}.plist").read_bytes()) for mode in range(3)]
        assert seals[0] == seals[1] == seals[2], "Legacy/indexed/cached seals differ"
        for entry in special:
            relative = entry.filename[len(root) + 1:]
            sealed = seals[0]["files2"][relative]
            assert sealed["hash"] == hashlib.sha1(archive.read(entry)).digest()
            assert sealed["hash2"] == hashlib.sha256(archive.read(entry)).digest()
        signature = output / "sparse/_CodeSignature/CodeResources"
        signature.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(output / "seal-2.plist", signature)
        run([work / "import-check", ipa, output, "rebuild"])
        with zipfile.ZipFile(output / "rebuilt.ipa") as rebuilt:
            assert rebuilt.testzip() is None
            for entry in archive.infolist():
                relative = entry.filename[len(root) + 1:]
                if "_CodeSignature" in relative.split("/"):
                    continue
                assert rebuilt.read(entry.filename) == archive.read(entry)
                if full and entry.filename.startswith(root + "/") and not entry.is_dir():
                    assert (output / "full" / relative).read_bytes() == archive.read(entry)
        print(f"PASS {label}: import, exact extraction, sparse hashes, three resource seals, rebuild", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minizip-source", type=Path, required=True)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or str(ROOT / ".build/swift-toolchain/usr/bin/swiftc"))
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ksign-archive-paths-") as temporary:
        work = Path(temporary)
        build(work, args.minizip_source.resolve(), args.swiftc)
        fixture = work / "literal.ipa"
        root = "Payload/Literal.app"
        with zipfile.ZipFile(fixture, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(root + "/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "test.literal", "CFBundleExecutable": "Literal"}))
            archive.writestr(root + r"/MagazineNumber_01_\!.png", b"literal backslash")
            archive.writestr(root + "/MagazineNumber_01_/!.png", b"different resource")
            archive.writestr(root + "/folder\\/tail\\", b"trailing literal backslashes")
        check_ipa(work, fixture, "fixture", full=True)
        # Traversal and absolute paths must still fail the actual import path.
        for number, unsafe in enumerate(["../escape", "/absolute", r"\absolute", root + "/../escape"]):
            invalid = work / f"invalid-{number}.ipa"
            with zipfile.ZipFile(invalid, "w") as archive:
                archive.writestr(root + "/Info.plist", plistlib.dumps({
                    "CFBundleIdentifier": "test.invalid", "CFBundleExecutable": "Invalid"}))
                archive.writestr(unsafe, b"invalid")
            run([work / "import-check", invalid, work / "invalid", "reject"])
        print("PASS unsafe traversal/absolute paths remain rejected", flush=True)
        if args.ipa:
            check_ipa(work, args.ipa.resolve(), "real-ipa")


if __name__ == "__main__":
    main()
