#!/usr/bin/env python3
"""Test the production IPA patcher, transaction rollback, and failure reporting."""
import argparse
import ctypes
import hashlib
import importlib.util
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOAD_PATH = b"@executable_path/../../Frameworks/asignpatch.dylib"
COMPACT_PATH = b"@rpath/asignpatch.dylib"
RUNPATH_RESOLVER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p)


def dylib(path, weak=True, endian="<", wide=True):
    size = (24 + len(path) + 1 + (7 if wide else 3)) & ~(7 if wide else 3)
    return struct.pack(endian + "6I", 0x80000018 if weak else 0xC, size, 24, 2, 0, 0) + path + bytes(size - 24 - len(path))


def runpath(path, endian="<", wide=True):
    alignment = 8 if wide else 4
    size = (12 + len(path) + 1 + alignment - 1) & ~(alignment - 1)
    return struct.pack(endian + "3I", 0x8000001C, size, 12) + path + bytes(size - 12 - len(path))


def thin(extra=(), endian="<", wide=True, padding=256, encrypted=False, signature=None):
    header_size, section_base, section_size = (32, 72, 80) if wide else (28, 56, 68)
    segment = bytearray(section_base + section_size)
    struct.pack_into(endian + "2I", segment, 0, 0x19 if wide else 1, len(segment))
    segment[8:14] = b"__TEXT"
    segment[section_base:section_base + 6] = b"__text"
    commands = [segment, *extra]
    if encrypted:
        commands.append(struct.pack(endian + "6I", 0x2C, 24, 0, 0, 1, 0))
    # Include an existing signature carrying recognizable entitlement data.
    code_offset = header_size + sum(map(len, commands)) + 16 + padding
    payload = b"UNCHANGED_EXECUTABLE_CODE" * 4
    signature = b"ORIGINAL_SIGNATURE_XML_AND_DER_ENTITLEMENTS" if signature is None else signature
    signature_offset = code_offset + len(payload)
    file_size = signature_offset + len(signature)
    if wide:
        struct.pack_into(endian + "4Q4I", segment, 24, 0, file_size, 0, file_size, 7, 5, 1, 0)
        struct.pack_into(endian + "2Q2I", segment, section_base + 32, 0, len(payload), code_offset, 0)
    else:
        struct.pack_into(endian + "8I", segment, 24, 0, file_size, 0, file_size, 7, 5, 1, 0)
        struct.pack_into(endian + "4I", segment, section_base + 32, 0, len(payload), code_offset, 0)
    commands.append(struct.pack(endian + "4I", 0x1D, 16, signature_offset, len(signature)))
    header = struct.pack(endian + "7I", 0xFEEDFACF if wide else 0xFEEDFACE,
                         0x100000C if wide else 12, 0 if wide else 9, 2, len(commands), sum(map(len, commands)), 0)
    return header + (bytes(4) if wide else b"") + b"".join(commands) + bytes(padding) + payload + signature


def fat(slices, endian=">", wide=False):
    entry_size = 32 if wide else 20
    data = bytearray(8 + entry_size * len(slices))
    struct.pack_into(endian + "2I", data, 0, 0xCAFEBABF if wide else 0xCAFEBABE, len(slices))
    for index, blob in enumerate(slices):
        data.extend(bytes((-len(data)) % 64))
        offset = len(data)
        slice_endian = ">" if blob[:4] in (bytes.fromhex("feedface"), bytes.fromhex("feedfacf")) else "<"
        cpu, subtype = struct.unpack_from(slice_endian + "2I", blob, 4)
        entry = struct.pack(endian + ("2I2Q2I" if wide else "5I"), cpu, subtype,
                            offset, len(blob), 6, *([0] if wide else []))
        data[8 + index * entry_size:8 + (index + 1) * entry_size] = entry
        data.extend(blob)
    return bytes(data)


def identity_fixtures(directory):
    (directory / "plain").write_bytes(thin())
    (directory / "blatant-only").write_bytes(thin([dylib(b"@rpath/blatantsPatch.dylib")]))
    (directory / "patch").write_bytes(b"Unified patch fixture")
    (directory / "legacy-pair").write_bytes(thin([dylib(b"@rpath/blatantsPatch.dylib"), dylib(b"@rpath/asignIdentity.dylib")]))
    def signed(entitlements, **kwargs):
        xml = plistlib.dumps(entitlements)
        blob = struct.pack(">2I", 0xFADE7171, 8 + len(xml)) + xml
        seal = struct.pack(">5I", 0xFADE0CC0, 20 + len(blob), 1, 5, 20) + blob
        return thin(signature=seal, **kwargs)
    local = signed({"application-identifier": "OLD.org.example.app",
                    "com.apple.security.application-groups": ["group.org.example.app"]})
    cloud = signed({"com.apple.developer.icloud-container-identifiers": ["iCloud.org.example.app"],
                    "com.apple.developer.icloud-services": ["CloudKit"]})
    (directory / "cloud-local").write_bytes(local)
    (directory / "cloud-enabled").write_bytes(cloud)
    (directory / "cloud-kvs").write_bytes(signed({"com.apple.developer.ubiquity-kvstore-identifier": "OLD.org.example.app"}))
    (directory / "cloud-fat").write_bytes(fat([local, signed({}, wide=False)]))
    (directory / "cloud-fat-disagreement").write_bytes(fat([local, cloud], wide=True))
    (directory / "cloud-big-endian").write_bytes(signed({}, endian=">"))
    (directory / "cloud-truncated").write_bytes(local[:-1])
    der = struct.pack(">7I", 0xFADE0CC0, 28, 1, 7, 20, 0xFADE7172, 8)
    (directory / "cloud-der-only").write_bytes(thin(signature=der))


def commands(blob):
    cursor = 32
    for _ in range(struct.unpack_from("<I", blob, 16)[0]):
        kind, size = struct.unpack_from("<2I", blob, cursor)
        yield kind, cursor
        cursor += size


def command(blob, kind):
    return next(offset for found, offset in commands(blob) if found == kind)


def sections(blob):
    result = {}
    for kind, cursor in commands(blob):
        if kind != 0x19:
            continue
        for index in range(struct.unpack_from("<I", blob, cursor + 64)[0]):
            offset = cursor + 72 + index * 80
            name = blob[offset:offset + 16].split(b"\0")[0].decode()
            address, size, file_offset = struct.unpack_from("<2QI", blob, offset + 32)
            result[name] = (address, size, file_offset, offset)
    return result


def tight_linked_image():
    data = bytearray((ROOT / "Tests/IPAPatching/linked-arm64.dylib.fixture").read_bytes())
    struct.pack_into("<I", data, 12, 2)
    count, size = struct.unpack_from("<2I", data, 16)
    cursor = 32 + size
    # Exhaust the real linker's padding with valid runpath commands.
    while cursor + 16 <= 0x4000:
        data[cursor:cursor + 16] = struct.pack("<3I4s", 0x8000001C, 16, 12, b".\0\0\0")
        cursor += 16
        count += 1
    struct.pack_into("<2I", data, 16, count, cursor - 32)
    return bytes(data)


def chained_image():
    """Minimal executable with no header padding and a real 64_OFFSET chain."""
    base = 0x100000000

    def segment(name, offset, size, sections=()):
        body = struct.pack("<2I16s4Q4I", 0x19, 72 + 80 * len(sections), name,
                           base + offset, 0x4000, offset, size, 7, 5, len(sections), 0)
        for section_name, address, section_size, file_offset, flags in sections:
            body += struct.pack("<16s16s2Q8I", section_name, name, address, section_size,
                                file_offset, 2, 0, 0, flags, 0, 0, 0)
        return body

    fixups = struct.pack("<7I", 0, 28, 68, 68, 0, 1, 0)
    fixups += struct.pack("<4I", 3, 0, 16, 0)
    fixups += struct.pack("<IHHQIHH", 24, 0x4000, 6, 0x4000, 0, 1, 0)
    signature = struct.pack(">3I", 0xFADE0CC0, 12, 0)
    signature_offset = 0x8050
    text_offset = 32 + 152 + 152 + 72 + 24 + 16 + 16
    loads = [segment(b"__TEXT", 0, 0x4000, [(b"__text", base + text_offset, 4, text_offset, 0x80000400)]),
             segment(b"__DATA", 0x4000, 0x4000, [(b"__data", base + 0x4000, 8, 0x4000, 0)]),
             segment(b"__LINKEDIT", 0x8000, signature_offset + len(signature) - 0x8000),
             struct.pack("<2I2Q", 0x80000028, 24, text_offset, 0),
             struct.pack("<4I", 0x80000034, 16, 0x8000, len(fixups)),
             struct.pack("<4I", 0x1D, 16, signature_offset, len(signature))]
    header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, len(loads), sum(map(len, loads)), 0x200004, 0)
    data = bytearray(signature_offset + len(signature))
    data[:len(header)] = header
    data[32:32 + sum(map(len, loads))] = b"".join(loads)
    struct.pack_into("<I", data, text_offset, 0xD65F03C0)  # ret
    struct.pack_into("<Q", data, 0x4000, text_offset)  # image-relative rebase
    data[0x8000:0x8000 + len(fixups)] = fixups
    data[signature_offset:] = signature
    return bytes(data)


class PatchingTests(unittest.TestCase):
    patcher = None
    file_patcher = None
    growth_patcher = None

    def patch(self, blob, path=LOAD_PATH, resolver=None):
        buffer = ctypes.create_string_buffer(blob, max(1, len(blob)))
        error = ctypes.create_string_buffer(512)
        callback = RUNPATH_RESOLVER((lambda value, _: resolver(value))) if resolver else RUNPATH_RESOLVER()
        result = self.patcher(buffer, len(blob), path, callback, None, error, len(error))
        return result, buffer.raw[:len(blob)], error.value.decode()

    def grow(self, blob):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "Staged"
            target.write_bytes(blob)
            target.chmod(0o755)
            error = ctypes.create_string_buffer(512)
            result = self.growth_patcher(os.fsencode(target), LOAD_PATH, RUNPATH_RESOLVER(), None, error, len(error))
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            return result, target.read_bytes(), error.value.decode()

    def assert_rejected(self, blob):
        result, output, error = self.patch(blob)
        self.assertLess(result, 0)
        self.assertTrue(error)
        self.assertEqual(output, blob, "A rejected patch modified the input")

    def test_weak_load_and_existing_code_signature_survive(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                with self.subTest(endian=endian, wide=wide):
                    original = thin(endian=endian, wide=wide)
                    result, output, error = self.patch(original)
                    self.assertEqual((result, error), (0, ""))
                    self.assertEqual(len(output), len(original))
                    header = 32 if wide else 28
                    old_length = struct.unpack_from(endian + "I", original, 20)[0]
                    command = header + old_length
                    self.assertEqual(struct.unpack_from(endian + "I", output, command)[0], 0x80000018)
                    self.assertEqual(output[command + 24:command + 24 + len(LOAD_PATH)], LOAD_PATH)
                    payload = original.index(b"UNCHANGED_EXECUTABLE_CODE")
                    self.assertEqual(output[payload:], original[payload:])
                    self.assertEqual(output[:16], original[:16])
                    self.assertEqual(self.patch(output), (0, output, ""))

    def test_repatch_normalizes_duplicate_and_old_paths(self):
        other = dylib(b"/System/Library/Frameworks/Foundation.framework/Foundation")
        original = thin([dylib(b"@rpath/otherPatch.dylib"), other,
                         dylib(b"@executable_path/otherPatch.dylib", weak=False)])
        result, output, error = self.patch(original, path=b"@executable_path/otherPatch.dylib")
        self.assertEqual((result, error), (0, ""))
        self.assertEqual(output.count(b"otherPatch.dylib"), 1)
        self.assertIn(other, output)

    def test_unified_upgrade_preserves_dependency_ordinals(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                loads = [b"@rpath/blatantsPatch.dylib", b"/usr/lib/libSystem.B.dylib",
                         b"@rpath/asignIdentity.dylib", b"/usr/lib/libobjc.A.dylib"]
                original = thin([dylib(path, False, endian, wide) for path in loads], endian, wide)
                result, output, error = self.patch(original)
                self.assertEqual((result, error), (0, ""))
                cursor = 32 if wide else 28
                paths = []
                for _ in range(struct.unpack_from(endian + "I", output, 16)[0]):
                    kind, size = struct.unpack_from(endian + "2I", output, cursor)
                    if kind in (0xC, 0x80000018):
                        offset = struct.unpack_from(endian + "I", output, cursor + 8)[0]
                        paths.append(output[cursor + offset:cursor + size].split(b"\0")[0])
                    cursor += size
                self.assertEqual(paths, [LOAD_PATH, loads[1], LOAD_PATH, loads[3]])
                payload = original.index(b"UNCHANGED_EXECUTABLE_CODE")
                self.assertEqual(output[payload:], original[payload:])
                self.assertEqual(self.patch(output), (0, output, ""))

    def test_unified_upgrade_uses_resolved_compact_path(self):
        original = thin([dylib(b"@rpath/blatantsPatch.dylib"), dylib(b"@rpath/asignIdentity.dylib"),
                         runpath(b"@executable_path/../../Frameworks")])
        result, output, error = self.patch(original, resolver=lambda _: 1)
        self.assertEqual((result, error), (0, ""))
        self.assertEqual(output.count(COMPACT_PATH + b"\0"), 2)
        self.assertNotIn(b"blatantsPatch.dylib", output)
        self.assertNotIn(b"asignIdentity.dylib", output)

    def test_compact_path_fits_where_the_original_extension_path_does_not(self):
        original = thin([runpath(b"@executable_path/../../Frameworks")], padding=64)
        self.assert_rejected(original)
        result, output, error = self.patch(original, resolver=lambda _: 1)
        self.assertEqual((result, error), (0, ""))
        self.assertIn(COMPACT_PATH + b"\0", output)
        self.assertNotIn(LOAD_PATH + b"\0", output)
        payload = original.index(b"UNCHANGED_EXECUTABLE_CODE")
        self.assertEqual(output[payload:], original[payload:])
        self.assertEqual(self.patch(output, resolver=lambda _: 1), (0, output, ""))

    def test_runpaths_are_checked_in_order_once_during_preflight(self):
        paths = [b"@executable_path/Frameworks", b"@executable_path/../../Frameworks"]
        original = thin([runpath(path) for path in paths], padding=64)
        visited = []

        def resolve(path):
            visited.append(path)
            return 1 if path == paths[1] else 0

        result, output, error = self.patch(original, resolver=resolve)
        self.assertEqual((result, error), (0, ""))
        self.assertEqual(visited, paths)
        self.assertIn(COMPACT_PATH, output)

    def test_shadowing_or_unverifiable_runpath_keeps_the_explicit_reference(self):
        paths = [b"@loader_path/Frameworks", b"@executable_path/../../Frameworks"]
        for unavailable in (-1, 0):
            original = thin([runpath(path) for path in paths])
            resolve = lambda path: unavailable if path == paths[0] else (1 if unavailable == -1 else 0)
            result, output, error = self.patch(original, resolver=resolve)
            self.assertEqual((result, error), (0, ""))
            self.assertIn(LOAD_PATH, output)
            self.assertNotIn(COMPACT_PATH, output)

    def test_runpath_choice_is_independent_for_each_preserved_slice(self):
        first = thin([runpath(b"@executable_path/../../Frameworks")], padding=64)
        second = thin()
        original = fat([first, second])
        result, output, error = self.patch(original, resolver=lambda _: 1)
        self.assertEqual((result, error), (0, ""))
        self.assertEqual(output[:48], original[:48])
        self.assertEqual(output.count(COMPACT_PATH), 1)
        self.assertEqual(output.count(LOAD_PATH), 1)
        # An unresolved tight slice still rejects the entire attempt, before writes.
        original = fat([first, thin(padding=64)])
        result, output, error = self.patch(original, resolver=lambda _: 1)
        self.assertEqual(result, -2)
        self.assertTrue(error)
        self.assertEqual(output, original)

    def test_compact_path_keeps_header_limits_and_endian_support(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                original = thin([runpath(b"@loader_path/../../Frameworks", endian, wide)],
                                endian=endian, wide=wide, padding=56)
                result, output, error = self.patch(original, resolver=lambda _: 1)
                self.assertEqual((result, error), (0, ""))
                self.assertIn(COMPACT_PATH, output)
        original = thin([runpath(b"@loader_path/../../Frameworks")], padding=40)
        result, output, error = self.patch(original, resolver=lambda _: 1)
        self.assertEqual(result, -2)
        self.assertEqual(output, original)
        self.assertIn("Insufficient", error)

    def test_malformed_runpath_is_rejected_before_resolving_or_writing(self):
        command = bytearray(runpath(b"@loader_path/../../Frameworks"))
        struct.pack_into("<I", command, 8, len(command))
        original = thin([command])
        self.assert_rejected(original)
        result, output, error = self.patch(original, resolver=lambda _: 1)
        self.assertEqual(result, -1)
        self.assertEqual(output, original)
        self.assertIn("runpath", error)

    def test_universal_tables_and_all_architecture_slices_are_preserved(self):
        slices = [thin(wide=False), thin(), thin(endian=">")]
        for endian in ("<", ">"):
            for wide in (False, True):
                with self.subTest(endian=endian, wide=wide):
                    original = fat(slices, endian, wide)
                    result, output, error = self.patch(original)
                    self.assertEqual((result, error), (0, ""))
                    table_end = 8 + len(slices) * (32 if wide else 20)
                    self.assertEqual(output[:table_end], original[:table_end])
                    self.assertEqual(output.count(LOAD_PATH), len(slices))
                    self.assertEqual(self.patch(output), (0, output, ""))

    def test_failed_later_slice_never_modifies_earlier_slices(self):
        self.assert_rejected(fat([thin(), thin(encrypted=True)]))
        self.assert_rejected(fat([thin(), thin(padding=0)]))

    def test_encrypted_truncated_and_unpadded_executables_are_rejected(self):
        for blob in (b"", b"abcd", thin(encrypted=True), thin(padding=0), thin()[:90]):
            self.assert_rejected(blob)

    def test_payload_in_header_padding_is_not_overwritten(self):
        blob = bytearray(thin())
        end = 32 + struct.unpack_from("<I", blob, 20)[0]
        blob[end] = 123
        self.assert_rejected(bytes(blob))

    def test_bad_segments_and_load_paths_are_rejected(self):
        for offset, value in ((36, 7), (96, 0xFFFFFFFF), (80, 0xFFFFFFFF)):
            blob = bytearray(thin())
            struct.pack_into("<I", blob, offset, value)
            self.assert_rejected(bytes(blob))
        bad = bytearray(dylib(b"@rpath/example.dylib"))
        struct.pack_into("<I", bad, 8, len(bad))
        self.assert_rejected(thin([bad]))

    def test_overlapping_or_mismatched_fat_slices_are_rejected(self):
        for offset, value in ((8, 1234), (36, 64), (16, 0xFFFFFFFF)):
            blob = bytearray(fat([thin(), thin()]))
            struct.pack_into(">I", blob, offset, value)
            self.assert_rejected(bytes(blob))

    def test_linked_regression_fixture_is_unchanged(self):
        data = (ROOT / "Tests/IPAPatching/linked-arm64.dylib.fixture").read_bytes()
        self.assertEqual(struct.unpack_from("<4I", data), (0xFEEDFACF, 0x100000C, 0, 6))
        self.assertIn(b"blatantsPatch", data)
        self.assertEqual(hashlib.sha256(data).hexdigest(), "4fb1f1d688a795bd3fb63aec01cf238ed48834fb95733cdaa280ee0618401f5a")

    def test_real_linked_macho_keeps_its_code_and_signature(self):
        original = bytearray((ROOT / "Tests/IPAPatching/linked-arm64.dylib.fixture").read_bytes())
        # Exercise a real linker-produced section/command layout as an executable.
        struct.pack_into("<I", original, 12, 2)
        result, output, error = self.patch(bytes(original))
        self.assertEqual((result, error), (0, ""))
        self.assertEqual(output[0x4000:], original[0x4000:])
        inspector = shutil.which("llvm-objdump") or shutil.which("llvm-objdump-20")
        if inspector:
            with tempfile.TemporaryDirectory() as temporary:
                executable = Path(temporary) / "Patched"
                inspected = bytearray(output)
                # Restore the fixture's library filetype for LLVM's stricter
                # cross-check (its original LC_ID_DYLIB is still present).
                struct.pack_into("<I", inspected, 12, 6)
                executable.write_bytes(inspected)
                inspection = subprocess.run([inspector, "--macho", "--dylibs-used", str(executable)],
                                            check=True, capture_output=True, text=True)
                self.assertIn(LOAD_PATH.decode(), inspection.stdout)

    def test_staged_file_mapping_saves_success_and_preserves_rejected_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "Executable"
            error = ctypes.create_string_buffer(512)
            good = thin()
            target.write_bytes(good)
            self.assertEqual(self.file_patcher(os.fsencode(target), LOAD_PATH, RUNPATH_RESOLVER(), None, error, len(error)), 0)
            self.assertEqual(target.read_bytes(), self.patch(good)[1])
            bad = thin(encrypted=True)
            target.write_bytes(bad)
            self.assertEqual(self.file_patcher(os.fsencode(target), LOAD_PATH, RUNPATH_RESOLVER(), None, error, len(error)), -1)
            self.assertEqual(target.read_bytes(), bad)
            self.assertTrue(error.value)
            link = Path(temporary) / "Symlink"
            link.symlink_to(target)
            self.assertEqual(self.file_patcher(os.fsencode(link), LOAD_PATH, RUNPATH_RESOLVER(), None, error, len(error)), -1)
            self.assertEqual(target.read_bytes(), bad)

    def test_staged_file_uses_verified_compact_reference(self):
        original = thin([runpath(b"@executable_path/../../Frameworks")], padding=64)
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "Staged"
            target.write_bytes(original)
            callback = RUNPATH_RESOLVER(lambda path, _: 1 if path == b"@executable_path/../../Frameworks" else -1)
            error = ctypes.create_string_buffer(512)
            result = self.file_patcher(os.fsencode(target), LOAD_PATH, callback, None, error, len(error))
            self.assertEqual((result, error.value), (0, b""))
            self.assertEqual(target.read_bytes(), self.patch(original, resolver=lambda _: 1)[1])

    def test_growth_preserves_the_original_entitlement_signature_and_is_repeatable(self):
        original = tight_linked_image()
        result, output, error = self.grow(original)
        self.assertEqual((result, error), (0, ""))
        self.assertGreaterEqual(len(output) - len(original), 0x4000)
        before = struct.unpack_from("<2I", original, command(original, 0x1D) + 8)
        after = struct.unpack_from("<2I", output, command(output, 0x1D) + 8)
        self.assertEqual(output[after[0]:sum(after)], original[before[0]:sum(before)])
        self.assertIn(LOAD_PATH, output)
        self.assertEqual(self.grow(output), (0, output, ""))

    def test_growth_updates_chained_fixups_entrypoint_and_segment_offsets(self):
        original = chained_image()
        result, output, error = self.grow(original)
        self.assertEqual((result, error), (0, ""))
        old_entry = struct.unpack_from("<Q", original, command(original, 0x80000028) + 8)[0]
        new_entry = struct.unpack_from("<Q", output, command(output, 0x80000028) + 8)[0]
        self.assertEqual(new_entry, old_entry + 0x4000)
        new_sections = sections(output)
        self.assertEqual(new_sections["__text"][2], new_entry)
        self.assertEqual(new_sections["__data"][2], 0x8000)
        self.assertEqual(struct.unpack_from("<Q", output, new_sections["__data"][2])[0], new_entry)
        fixups_offset = struct.unpack_from("<I", output, command(output, 0x80000034) + 8)[0]
        starts = fixups_offset + struct.unpack_from("<I", output, fixups_offset + 4)[0]
        data_segment = starts + struct.unpack_from("<I", output, starts + 8)[0]
        self.assertEqual(struct.unpack_from("<Q", output, data_segment + 8)[0], 0x8000)
        self.assertEqual(output[new_entry:new_entry + 4], original[old_entry:old_entry + 4])

    def test_growth_preserves_all_slices_and_fat_container_variants(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                original = fat([chained_image(), thin(wide=False)], endian, wide)
                result, output, error = self.grow(original)
                self.assertEqual((result, error), (0, ""))
                self.assertEqual(output[:8], original[:8])
                self.assertEqual(output.count(LOAD_PATH), 2)
                entry = 32 if wide else 20
                for index in range(2):
                    at = 8 + index * entry
                    self.assertEqual(output[at:at + 8], original[at:at + 8])

    def test_growth_failure_leaves_the_entire_staged_file_unchanged(self):
        for original in [fat([chained_image(), thin(encrypted=True)]),
                         fat([chained_image(), thin(wide=False, padding=0)])]:
            result, output, error = self.grow(original)
            self.assertLess(result, 0)
            self.assertTrue(error)
            self.assertEqual(output, original)

    def test_growth_repairs_arm64_references_to_the_mach_header(self):
        original = bytearray(chained_image())
        entry = sections(original)["__text"][2]
        encoded = (-entry) & 0x1FFFFF
        adr = 0x10000000 | (encoded & 3) << 29 | (encoded >> 2) << 5
        struct.pack_into("<I", original, entry, adr)
        result, output, error = self.grow(bytes(original))
        self.assertEqual((result, error), (0, ""))
        new_entry = sections(output)["__text"][2]
        instruction = struct.unpack_from("<I", output, new_entry)[0]
        immediate = ((instruction >> 5) & 0x7FFFF) << 2 | (instruction >> 29) & 3
        if immediate & (1 << 20):
            immediate -= 1 << 21
        self.assertEqual(new_entry + immediate, 0)

    def test_growth_repairs_shared_adrp_header_address_calculations(self):
        original = bytearray(chained_image())
        _, _, entry, section_command = sections(original)["__text"]
        struct.pack_into("<Q", original, section_command + 40, 8)
        struct.pack_into("<2I", original, entry, 0x90000001, 0x91000020)  # adrp x1, base; add x0, x1, #0
        result, output, error = self.grow(bytes(original))
        self.assertEqual((result, error), (0, ""))
        new_entry = sections(output)["__text"][2]
        adrp, subtract = struct.unpack_from("<2I", output, new_entry)
        self.assertEqual(adrp, 0x90000001)
        self.assertEqual(subtract & 0xFFC003FF, 0xD1400020)  # sub x0, x1, #4, lsl #12
        self.assertEqual(((subtract >> 10) & 0xFFF) * 4096, 0x4000)

    def test_unsigned_growth_retains_uuid_and_leaves_signing_to_the_signer(self):
        original = bytearray(tight_linked_image())
        signature_at = command(original, 0x1D)
        old_uuid_at = command(original, 0x1B)
        old_uuid = bytes(original[old_uuid_at + 8:old_uuid_at + 24])
        end = 32 + struct.unpack_from("<I", original, 20)[0]
        original[signature_at:end - 16] = original[signature_at + 16:end]
        original[end - 16:end] = bytes(16)
        count, size = struct.unpack_from("<2I", original, 16)
        struct.pack_into("<2I", original, 16, count - 1, size - 16)
        result, output, error = self.grow(bytes(original))
        self.assertEqual((result, error), (0, ""))
        new_uuid_at = command(output, 0x1B)
        self.assertEqual(output[new_uuid_at + 8:new_uuid_at + 24], old_uuid)
        self.assertNotIn(0x1D, [kind for kind, _ in commands(output)])

    def test_growth_relocates_compact_unwind_function_offsets(self):
        original = tight_linked_image()
        result, output, error = self.grow(original)
        self.assertEqual((result, error), (0, ""))
        before = sections(original)["__unwind_info"][2]
        after = sections(output)["__unwind_info"][2]
        index, count = struct.unpack_from("<2I", original, before + 20)
        self.assertGreater(count, 0)
        for row in range(count):
            old = struct.unpack_from("<I", original, before + index + row * 12)[0]
            new = struct.unpack_from("<I", output, after + index + row * 12)[0]
            self.assertEqual(new, old + 0x4000)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-swift", action="store_true")
    args = parser.parse_args()
    preparation = unittest.defaultTestLoader.discover(str(ROOT / "Tests/IPAPatching"), pattern="test_*.py")
    if not unittest.TextTestRunner(verbosity=2).run(preparation).wasSuccessful():
        return 1
    with tempfile.TemporaryDirectory(prefix="asign-ipapatch-tests-") as scratch:
        directory = Path(scratch)
        source = ROOT / "Asign/Utilities/MachO/IPAPatch.c"
        spec = importlib.util.spec_from_file_location("prepare_ipa_patch_lief", ROOT / ".github/scripts/prepare_ipa_patch_lief.py")
        sdk_helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sdk_helper)
        sdk = sdk_helper.prepare("host")
        native_object = directory / "IPAPatch.o"
        growth_object = directory / "IPAPatchGrowth.o"
        cpp_runtime = ["-lc++"] if sys.platform == "darwin" else ["-lstdc++", "-ldl", "-lpthread"]
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-c",
                        str(source), "-o", str(native_object)], check=True)
        subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-fPIC", "-c",
                        "-I", str(sdk / "include"), str(source.with_name("IPAPatchGrowth.cpp")),
                        "-o", str(growth_object)], check=True)
        archive = str(sdk / "lib/libLIEF.a")
        library = directory / ("libIPAPatch.dylib" if sys.platform == "darwin" else "libIPAPatch.so")
        subprocess.run(["clang++", "-shared", str(native_object), str(growth_object), archive,
                        *cpp_runtime, "-o", str(library)], check=True)
        native = ctypes.CDLL(str(library))
        function = native.KsignPatchIPALoadCommands
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p,
                             RUNPATH_RESOLVER, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        function.restype = ctypes.c_int
        PatchingTests.patcher = staticmethod(function)
        file_function = native.KsignPatchIPAFile
        file_function.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                 RUNPATH_RESOLVER, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        file_function.restype = ctypes.c_int
        PatchingTests.file_patcher = staticmethod(file_function)
        growth_function = native.KsignPatchIPAFileWithGrowth
        growth_function.argtypes = file_function.argtypes
        growth_function.restype = ctypes.c_int
        PatchingTests.growth_patcher = staticmethod(growth_function)
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PatchingTests))
        if not result.wasSuccessful():
            return 1
        fuzz = directory / "ipapatch-fuzz"
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-I", str(source.parent), str(source),
                        str(ROOT / "Tests/IPAPatching/fuzz.c"), "-o", str(fuzz)], check=True)
        fixtures = []
        for index, data in enumerate([thin(), thin(wide=False), thin(endian=">"),
                                      fat([thin(), thin(wide=False)]), fat([thin()], wide=True),
                                      thin([runpath(b"@executable_path/../../Frameworks")], padding=64)]):
            fixture = directory / f"fuzz-{index}"
            fixture.write_bytes(data)
            fixtures.append(str(fixture))
        environment = dict(os.environ)
        environment["ASAN_OPTIONS"] = environment.get("ASAN_OPTIONS", "") + ":detect_leaks=0"
        subprocess.run([str(fuzz), *fixtures], check=True, env=environment)
        swift = shutil.which("swiftc")
        if not swift:
            print("Swift identity transaction tests unavailable: swiftc is not installed.", flush=True)
            return 1 if args.require_swift else 0
        executable = directory / "ipapatch-tests"
        flags = ["-swift-version", "5"]
        if sys.platform == "darwin":
            flags += ["-target", platform.machine() + "-apple-macosx14.0"]
        swift_main = directory / "main.swift"
        shutil.copyfile(ROOT / "Tests/IPAPatching/identity.swift", swift_main)
        subprocess.run([swift, *flags, "-import-objc-header", str(source.with_suffix(".h")),
                        str(ROOT / "Asign/Utilities/Handlers/IPAPatcher.swift"),
                        str(swift_main), str(native_object), str(growth_object), archive, *cpp_runtime,
                        "-o", str(executable)], check=True)
        identity_fixtures(directory)
        subprocess.run([str(executable), str(directory)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
