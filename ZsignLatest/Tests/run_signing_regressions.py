#!/usr/bin/env python3
"""Native signing checks on Linux; requires a built minizip-ng and OpenSSL.

python3 ZsignLatest/Tests/run_signing_regressions.py \
    --minizip-source /path/to/minizip-ng --minizip-build /path/to/minizip-ng/build

Pass --sanitize to enable AddressSanitizer and UndefinedBehaviorSanitizer.
Pass --swiftc /path/to/swiftc to check the Swift archive and final metadata code.
"""

import argparse
import hashlib
import json
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


def fixture(path, aliases=False, canonical=False):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        def add(name, data, symlink=False):
            entry = zipfile.ZipInfo(APP + "/" + name)
            entry.create_system = 3
            entry.external_attr = ((stat.S_IFLNK | 0o777) if symlink else
                                   (stat.S_IFREG | 0o755)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)

        def bundle(folder, executable, identifier, versioned=False, large=False):
            prefix = folder + "/" if folder else ""
            physical = prefix + "Versions/A/" if versioned else prefix
            add(physical + "Info.plist", plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundleVersion": "1", "CFBundleName": executable,
            }))
            # Force signature growth through a framework executable symlink.
            add(physical + executable, macho(6 if folder.endswith(".framework") else 2,
                                            4 * 1024 * 1024 if large else (1024 * 1024 if not folder else 4096),
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
        bundle("Frameworks/V.framework", "V", "test.versioned", not canonical)
        if canonical:
            bundle("Frameworks/Large.framework", "Large", "test.large", large=True)
        add("Standalone.dylib", macho(6))
        if aliases:
            add("AliasFiles/Code", macho(6))
            add("AliasLink", b"AliasFiles", True)
            add("AliasLink/Code", macho(6))
        add("root.dat", b"root resource")
        add("OriginalIcon@3x.png", b"original icon")
        if not canonical:
            add("alias", b"root.dat", True)
        add("Deleted/old.dat", b"must not reappear")
        if canonical:
            add("Deleted/Old.dylib", macho(6))
        add("embedded.mobileprovision", b"old profile")
        add("_CodeSignature/obsolete", b"old signature")
        # Exercise rehashing of the archive membership set across many entries.
        for index in range(2048):
            add(f"Resources/{index}.dat", str(index).encode())
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            add("root.dat", b"last duplicate wins")


def verify_signature(data, info, resources, expected_directories=2):
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
    assert directories == expected_directories


def verify_archive(path, profiles=False, edited_resource=False, canonical=False):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert len(names) == len(set(names))
        assert archive.read(APP + "/root.dat") == (b"last duplicate wins edited" if edited_resource else b"last duplicate wins")
        assert not any("/Deleted/" in name or name.endswith("/obsolete") or
                       (not profiles and name.endswith("/embedded.mobileprovision")) for name in names)
        if profiles:
            provisions = [archive.read(name) for name in names if name.endswith("/embedded.mobileprovision")]
            assert sorted(provisions) == sorted(b"profile:" + name.encode() for name in
                ("test.main", "test.framework", "test.extension", "test.nested", "test.versioned"))
        if not canonical:
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


def extraction_checks(executable, work):
    binary = struct.pack("<I", 0xFEEDFACF) + bytes(100)

    # A digest exclusion is not a removal. Actual removals skip even Mach-O
    # materialization, but ambiguous aliases retain their prior extraction.
    for label in ("canonical", "case-parent", "unicode", "symlink"):
        source = work / f"plan-{label}.ipa"
        with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(APP + "/Info.plist", b"metadata")
            archive.writestr(APP + "/Removed/Code", binary)
            archive.writestr(APP + "/Removed/Info.plist", b"unused metadata")
            archive.writestr(APP + "/RemovedBackup/Code", binary)
            archive.writestr(APP + "/kept.dat", b"kept")
            if label == "case-parent": archive.writestr(APP + "/removed/Other", binary)
            if label == "unicode": archive.writestr(APP + "/日本語.txt", b"resource")
            if label == "symlink":
                entry = zipfile.ZipInfo(APP + "/Alias")
                entry.create_system = 3; entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, b"Removed")
        outputs = []
        for workers in ("1", "4"):
            overlay = work / f"plan-{label}-{workers}"
            overlay.mkdir()
            subprocess.run([str(executable), "--plan", str(source), str(overlay), workers, "Removed"], check=True)
            assert (overlay / "Removed/Code").exists() == (label != "canonical")
            assert (overlay / "Removed/Info.plist").exists() == (label != "canonical")
            assert (overlay / "RemovedBackup/Code").exists()
            assert (overlay / "Info.plist").exists()
            outputs.append((overlay / "digests.bin").read_bytes())
        assert outputs[0] == outputs[1]

    def snapshot(directory):
        result = {}
        for path in directory.rglob("*"):
            name = str(path.relative_to(directory))
            if path.is_symlink():
                result[name] = ("link", os.readlink(path))
            elif path.is_file():
                result[name] = ("file", path.read_bytes())
        return result

    cases = {
        "duplicates": [("Code", binary, False), ("Code", b"ordinary resource", False),
                       ("Other", b"ordinary", False), ("Other", binary, False)],
        "dot-alias": [("Frameworks/./Code", binary + b"old", False),
                      ("Frameworks/Code", binary + b"final", False)],
        "case-alias": [("Code", binary + b"upper", False), ("code", binary + b"lower", False)],
        "unicode": [("日本語/Info.plist", b"metadata", False)],
        "link-ancestor": [("Real/Code", binary + b"old", False), ("Alias", b"Real", True),
                          ("Alias/Code", binary + b"final", False)],
        "localizations": [("en.lproj/InfoPlist.strings", b"localized", False),
                          ("large.dat", bytes(50000), False)],
    }
    for label, entries in cases.items():
        source = work / f"extract-{label}.ipa"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr(APP + "/Info.plist", b"metadata")
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                for name, data, link in entries:
                    entry = zipfile.ZipInfo(APP + "/" + name)
                    entry.create_system = 3
                    entry.external_attr = ((stat.S_IFLNK | 0o777) if link else (stat.S_IFREG | 0o755)) << 16
                    archive.writestr(entry, data)
        outputs = []
        for workers in ("1", "4"):
            overlay = work / f"extraction-{label}-{workers}"
            overlay.mkdir()
            subprocess.run([str(executable), "--extract", str(source), str(overlay), workers, "strings"], check=True)
            outputs.append(snapshot(overlay))
        assert outputs[0] == outputs[1], label
        if label == "duplicates":
            assert "Code" not in outputs[0] and outputs[0]["Other"][1] == binary
        if label == "localizations":
            assert "large.dat" not in outputs[0]
            assert outputs[0]["en.lproj/InfoPlist.strings"][1] == b"localized"

    for label in ("bad-crc", "bad-resource-crc", "escape-link"):
        source = work / f"extract-{label}.ipa"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr(APP + "/Info.plist", b"metadata")
            if label in ("bad-crc", "bad-resource-crc"):
                archive.writestr(APP + "/Code", binary if label == "bad-crc" else b"ordinary resource payload")
            else:
                entry = zipfile.ZipInfo(APP + "/Link")
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, b"../../outside")
        if label in ("bad-crc", "bad-resource-crc"):
            with zipfile.ZipFile(source) as archive:
                entry = archive.getinfo(APP + "/Code")
                offset = entry.header_offset + 30 + len(entry.filename.encode()) + len(entry.extra) + 12
            data = bytearray(source.read_bytes())
            data[offset] ^= 1
            source.write_bytes(data)
        for workers in ("1", "4"):
            overlay = work / f"rejected-{label}-{workers}"
            overlay.mkdir()
            run = subprocess.run([str(executable), "--extract", str(source), str(overlay), workers])
            assert run.returncode != 0, label


def growth_and_cms_checks(executable, work):
    # Small existing signatures force growth before the first page-hash pass.
    for mode in ("dual", "sha256", "large", "fat"):
        path = work / f"growth-{mode}"
        data = macho(code_size=1024 * 1024, signature_size=16)
        if mode == "fat":
            # One slice requires growth, the other has ample signature capacity.
            second = macho(code_size=1024 * 1024, signature_size=32768)
            offset = 16384
            offset2 = (offset + len(data) + 16383) // 16384 * 16384
            header = struct.pack(">II", 0xcafebabe, 2)
            header += struct.pack(">IIIII", 0x100000c, 0, offset, len(data), 14)
            header += struct.pack(">IIIII", 0x100000c, 2, offset2, len(second), 14)
            data = header.ljust(offset, b"\0") + data
            data = data.ljust(offset2, b"\0") + second
        path.write_bytes(data)
        path.chmod(0o751)
        link = work / f"growth-{mode}-link"
        os.link(path, link)
        subprocess.run([str(executable), "--binary", str(path), mode], check=True, stdout=subprocess.PIPE)
        if mode != "fat": assert link.read_bytes() == path.read_bytes()
        data = path.read_bytes()
        if mode == "fat":
            for index in range(2):
                _, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + 20 * index)
                verify_signature(data[offset:offset + size], None, None)
        else:
            verify_signature(data, None, None, 1 if mode == "sha256" else 2)

    # A local fixture chain exercises real CMS signing and allocation lifetimes.
    def openssl(*args):
        subprocess.run(["openssl", *map(str, args)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    root_key, root_cert = work / "root.key", work / "root.pem"
    key, request, cert = work / "leaf.key", work / "leaf.csr", work / "leaf.pem"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root_key,
            "-out", root_cert, "-subj", "/CN=Signing Test Root", "-days", "1")
    openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", request,
            "-subj", "/CN=Signing Test Leaf")
    openssl("x509", "-req", "-in", request, "-CA", root_cert, "-CAkey", root_key,
            "-CAcreateserial", "-out", cert, "-days", "1")
    p12 = work / "test.p12"
    openssl("pkcs12", "-export", "-inkey", key, "-in", cert, "-certfile", root_cert,
            "-out", p12, "-passout", "pass:test")
    profile = work / "profile.plist"
    profile.write_bytes(plistlib.dumps({"TeamIdentifier": ["TEAM"], "Entitlements": {
        "application-identifier": "TEAM.test.binary"}}))
    provision = work / "profile.mobileprovision"
    openssl("cms", "-sign", "-binary", "-nodetach", "-in", profile, "-signer", cert,
            "-inkey", key, "-outform", "DER", "-out", provision)
    binary = work / "growth-cms"
    binary.write_bytes(macho(code_size=1024 * 1024, signature_size=16))
    binary.chmod(0o751)
    subprocess.run([str(executable), "--cms", str(p12), str(provision), str(binary)],
                   check=True, stdout=subprocess.PIPE)
    # The CMS signature is checked in C++; independently verify the final page hashes.
    verify_signature(binary.read_bytes(), None, None)

    concurrent_source = work / "concurrent-source.ipa"
    fixture(concurrent_source, canonical=True)
    concurrent = work / "concurrent"
    concurrent.mkdir()
    before = hashlib.sha256(concurrent_source.read_bytes()).digest()
    subprocess.run([str(executable), "--concurrent", str(concurrent_source), str(concurrent), str(p12), str(provision)],
                   check=True, stdout=subprocess.PIPE, timeout=60)
    for lane in range(5):
        contents = verify_archive(concurrent / str(lane) / "signed.ipa", canonical=True)
        info = plistlib.loads(contents[APP + "/Info.plist"])
        assert info["CFBundleIdentifier"] == f"test.concurrent.{lane}"
        assert contents[APP + "/lane.txt"] == str(lane).encode()
        data = contents[APP + "/Main"]
        command = 32
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            kind, size = struct.unpack_from("<II", data, command)
            if kind == 0x1D:
                signature = struct.unpack_from("<I", data, command + 8)[0]
                break
            command += size
        blobs = {}
        for index in range(struct.unpack_from(">I", data, signature + 8)[0]):
            kind, offset = struct.unpack_from(">II", data, signature + 12 + index * 8)
            base = signature + offset
            length = struct.unpack_from(">I", data, base + 4)[0]
            blobs[kind] = data[base:base + length]
        signed_content, cms = concurrent / "directory.bin", concurrent / "signature.der"
        signed_content.write_bytes(blobs[0])
        cms.write_bytes(blobs[0x10000][8:])
        openssl("cms", "-verify", "-binary", "-inform", "DER", "-noverify", "-in", cms,
                "-content", signed_content, "-out", os.devnull)
    assert hashlib.sha256(concurrent_source.read_bytes()).digest() == before
    print("Passed five simultaneous native app signers with shared credentials, identical filenames, distinct IDs/resources, verified CMS and unchanged source IPA.")


def swift_metadata_checks(compiler, work, archive, includes, minizip, source):
    module = work / "c-module"
    module.mkdir()
    (module / "module.modulemap").write_text(
        'module CASignArchive { header "' + str(archive / "include/CASignArchive.h") + '" export * }')
    shim = work / "autorelease.swift"
    shim.write_text("#if os(Linux)\nfunc autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }\n#endif\n")
    memory_types = (ROOT.parent / "Ksign/Utilities/Handlers/ArchiveMemoryCoordinator.swift").read_text().split("// Archive work can be synchronous.", 1)[0]
    workspace_type = (ROOT.parent / "Ksign/Utilities/Handlers/SigningWorkspace.swift").read_text().split("/// Core Data records", 1)[0]
    shim.write_text(shim.read_text() + memory_types.replace("import Darwin\n", "").replace("import OSLog\n", "") + workspace_type)
    app_source = (ROOT.parent / "Ksign/Backend/Storage/Storage+Shared.swift").read_text()
    signing_source = (ROOT.parent / "Ksign/Utilities/Handlers/SigningHandler.swift").read_text()
    gate = work / "signing-stage-gate.swift"
    gate.write_text("import Foundation\nactor SigningStageGate {" + signing_source.split("actor SigningStageGate {", 1)[1]
                    .split("\nfinal class SigningBatchContext", 1)[0])
    pipeline = work / "pipeline-regressions"
    subprocess.run([str(compiler), "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(work / "swift-cache"), str(gate),
                    str(ROOT / "Tests/signing_pipeline_regressions.swift"), "-o", str(pipeline)], check=True)
    subprocess.run([str(pipeline)], check=True, timeout=30)
    ar_test = work / "ar-regressions"
    subprocess.run([str(compiler), "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(work / "swift-cache"),
                    str(ROOT.parent / "Ksign/Utilities/ARDecompression/AR.swift"),
                    str(ROOT.parent / "Ksign/Utilities/ARDecompression/Models/ARFileModel.swift"),
                    str(ROOT / "Tests/ar_regressions.swift"), "-o", str(ar_test)], check=True)
    subprocess.run([str(ar_test)], check=True, timeout=30)
    start = app_source.index("struct ArchiveBackedAppMetadata")
    end = app_source.index("// MARK: - Helpers", start)
    app = work / "archive-app.swift"
    app.write_text("import Foundation\n" + app_source[start:end])
    obj = work / "swift-archive.o"
    subprocess.run(["cc", "-std=gnu11", "-pthread", *includes, "-c", str(archive / "CASignArchive.c"),
                    "-o", str(obj)], check=True)
    executable = work / "metadata-regressions"
    subprocess.run([str(compiler), "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(work / "swift-cache"), "-I", str(module),
                    str(ROOT.parent / "ASignArchiveKit/Sources/ASignArchiveKit/ASignArchiveKit.swift"),
                    str(shim), str(app), str(ROOT / "Tests/archive_metadata_regressions.swift"),
                    str(obj), str(minizip), "-Xlinker", "-lz", "-Xlinker", "-lpthread", "-Xlinker", "-lcrypto",
                    "-o", str(executable)], check=True)
    tweak_source = work / "tweak-source.ipa"
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(tweak_source, "w", zipfile.ZIP_DEFLATED) as output:
        for entry in original.infolist():
            if not stat.S_ISLNK(entry.external_attr >> 16):
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    output.writestr(entry, original.read(entry))
        output.writestr(APP + "/Replace.bundle/old.txt", b"old")
        output.writestr(APP + "/Replace.bundle/Old.dylib", macho(6))
        output.writestr(APP + "/Replace.bundle/shared.txt", b"original shared")
        output.writestr(APP + "/Replace.bundle.extra/untouched.txt", b"untouched")
    for label in ("unrelated", "case", "dot", "unicode-target", "link-ancestor", "link-target", "unrelated-case", "unrelated-dot", "unicode-normalization"):
        with zipfile.ZipFile(work / f"mutation-{label}.ipa", "w", zipfile.ZIP_DEFLATED) as output:
            output.writestr(APP + "/Info.plist", plistlib.dumps({"CFBundleExecutable": "Main", "CFBundleIdentifier": "test.mutation"}))
            output.writestr(APP + "/Main", macho())
            output.writestr(APP + "/Target.bundle/first.txt", b"first")
            if label == "unrelated":
                output.writestr(APP + "/Other/日本語.txt", b"unrelated")
            if label == "case": output.writestr(APP + "/target.bundle/second.txt", b"alias")
            if label == "dot": output.writestr(APP + "/Target.bundle/./second.txt", b"alias")
            if label == "unicode-target": output.writestr(APP + "/Tárget.bundle/second.txt", b"alias")
            if label == "unrelated-case":
                output.writestr(APP + "/Other/first.txt", b"first")
                output.writestr(APP + "/other/second.txt", b"second")
            if label == "unrelated-dot": output.writestr(APP + "/Other/./first.txt", b"dot")
            if label == "unicode-normalization":
                output.writestr(APP + "/Other/caf\u00e9.txt", b"NFC")
                output.writestr(APP + "/Other/cafe\u0301.txt", b"NFD")
            if label in ("unrelated", "link-ancestor", "link-target"):
                entry = zipfile.ZipInfo(APP + ("/Target.bundle" if label == "link-target" else "/Alias"))
                entry.create_system = 3; entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(entry, b"Target.bundle" if label != "link-target" else b"Other")
                if label == "link-ancestor": output.writestr(APP + "/Alias/second.txt", b"redirected")
            outside = zipfile.ZipInfo("Outside/Link")
            outside.create_system = 3; outside.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(outside, b"../Payload/Test.app")
    subprocess.run([str(executable), str(source), str(work), str(tweak_source)], check=True)
    handler = work / "TweakHandler.swift"
    handler.write_text((ROOT.parent / "Ksign/Utilities/Handlers/TweakHandler.swift").read_text()
        .replace("import Zsign", "").replace("import OSLog", "").replace("Bundle(url:", "TweakBundle(url:").replace("Bundle.main", "TweakBundle.main"))
    subprocess.run([str(compiler), "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(work / "swift-cache"), "-I", str(module),
                    str(ROOT.parent / "ASignArchiveKit/Sources/ASignArchiveKit/ASignArchiveKit.swift"),
                    str(shim), str(app), str(gate), str(handler), str(ROOT / "Tests/tweak_workspace_regressions.swift"),
                    str(obj), str(minizip), "-Xlinker", "-lz", "-Xlinker", "-lpthread", "-Xlinker", "-lcrypto",
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(tweak_source), str(work)], check=True)
    with zipfile.ZipFile(work / "tweak-handler-full.ipa") as full, zipfile.ZipFile(work / "tweak-handler-sparse.ipa") as sparse:
        contents = lambda archive: {entry.filename: archive.read(entry) for entry in archive.infolist() if not entry.is_dir()}
        expected, actual = contents(full), contents(sparse)
        different = sorted(name for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name))
        assert not different, f"Sparse/full tweak archive contents differ: {different}"



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minizip-source", type=Path, required=True)
    parser.add_argument("--minizip-build", type=Path, required=True)
    parser.add_argument("--sanitize", action="store_true")
    parser.add_argument("--reference-digests", type=Path, help="Compare signed fixture contents with a previous revision")
    parser.add_argument("--swiftc", type=Path, help="Also compile the Swift archive and metadata checks")
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
                        "-Wl,--wrap=mz_zip_reader_goto_next_entry", "-Wl,--wrap=lstat",
                        "-Wl,--wrap=EVP_DigestUpdate", "-Wl,--wrap=EVP_MD_CTX_new",
                        "-Wl,--wrap=PEM_read_bio_X509", "-Wl,--wrap=mmap",
                        "-Wl,--wrap=PKCS12_parse",
                        "-o", str(executable)], check=True)
        source = work / "source.ipa"
        fixture(source)
        if args.reference_digests:
            reference = json.loads(args.reference_digests.read_text())
            def verify_reference(*arguments, **keywords):
                result = verify_archive(*arguments, **keywords)
                expected = reference.pop(0)
                actual = {name: hashlib.sha256(data).hexdigest() for name, data in result.items()}
                assert actual == expected, "Signed contents differ from the reference revision"
                return result
            verify = verify_reference
        else:
            verify = verify_archive
        extraction_checks(executable, work)
        growth_and_cms_checks(executable, work)
        patch_source, patch_output = work / "patch-source", work / "patch-output"
        patch_source.write_bytes(macho())
        subprocess.run([str(executable), "--patches", str(patch_source), str(patch_output)], check=True, stdout=subprocess.PIPE)
        if args.swiftc:
            swift_metadata_checks(args.swiftc, work, archive, includes,
                                  args.minizip_build / "libminizip.a", source)
        results = []
        for workers, filesystem, relative, fused in (("1", False, False, False), ("4", False, False, False),
                ("4", True, False, False), ("4", True, True, False),
                ("1", False, False, True), ("4", False, False, True)):
            label = f"{workers}-{'filesystem' if filesystem else 'sparse'}"
            if relative:
                label += "-relative"
            if fused:
                label += "-fused"
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
            elif fused:
                command.append("--fused")
            run = subprocess.run(command,
                                 env={**os.environ, "ZSIGN_WORKERS": workers}, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=work)
            assert run.returncode == 0, run.stdout + run.stderr
            standalone_logs = [line for line in run.stdout.splitlines() if ">>> SignFile:" in line]
            assert len(standalone_logs) == 4, standalone_logs
            assert all(line.endswith(("Standalone.dylib", "Injected.dylib")) for line in standalone_logs)
            results.append(verify(destination))
        assert results[0] == results[1], "Serial and parallel signing must emit identical contents"
        assert results[1] == results[2], "Sparse and filesystem signing must emit identical contents"
        assert results[2] == results[3], "Relative and absolute paths must emit identical contents"
        assert results[0] == results[4] == results[5], "Fused classification/hashing must emit identical signatures/seals"
        canonical_source = work / "canonical-source.ipa"
        fixture(canonical_source, canonical=True)
        canonical_results = []
        for workers in ("1", "4"):
            overlay = work / f"canonical-{workers}.app"; overlay.mkdir()
            destination = work / f"canonical-{workers}.ipa"
            subprocess.run([str(executable), str(canonical_source), str(destination), str(overlay), APP, "--canonical"],
                env={**os.environ, "ZSIGN_WORKERS": workers}, check=True, stdout=subprocess.PIPE)
            canonical_results.append(verify_archive(destination, canonical=True))
        assert canonical_results[0] == canonical_results[1], "Concurrent small binaries and dependency-ordered bundles must match serial signing"
        edited = []
        for mode in ("--overlay", "--fused-overlay"):
            overlay = work / (mode[2:] + ".app")
            overlay.mkdir()
            destination = work / (mode[2:] + ".ipa")
            subprocess.run([str(executable), str(source), str(destination), str(overlay), APP, mode],
                           check=True, stdout=subprocess.PIPE)
            edited.append(verify(destination, edited_resource=True))
        assert edited[0] == edited[1], "An overlay must invalidate the original resource digest"
        overlay = work / "profiles.app"
        overlay.mkdir()
        destination = work / "profiles.ipa"
        subprocess.run([str(executable), str(source), str(destination), str(overlay), APP, "--profiles"],
                       env={**os.environ, "ZSIGN_WORKERS": "4"}, check=True, stdout=subprocess.PIPE)
        verify(destination, profiles=True)
        source = work / "aliased-source.ipa"
        fixture(source, aliases=True)
        overlay = work / "aliased.app"
        overlay.mkdir()
        destination = work / "aliased.ipa"
        subprocess.run([str(executable), str(source), str(destination), str(overlay), APP],
                       env={**os.environ, "ZSIGN_WORKERS": "4"}, check=True, stdout=subprocess.PIPE)
        verify(destination)
        with zipfile.ZipFile(destination) as archive:
            real = archive.read(APP + "/AliasFiles/Code")
            assert real == archive.read(APP + "/AliasLink/Code")
            verify_signature(real, None, None)
        if args.reference_digests: assert not reference, "Reference fixtures were not all exercised"
    print("Passed worker reuse/concurrency, single executable signing, hash reuse, signature/page hashes,")
    print("nested seals, selective parallel extraction/aliases/CRC, shared indexes, sparse additions and deletions.")


if __name__ == "__main__":
    main()
