#!/usr/bin/env python3
"""Exercise the production Mach-O shim and, with Swift available, its trigger/plists."""
import argparse
import ctypes
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MINIMUM = 0x120300
SDK = 0x1A0000


def build_version(platform, minimum=0x010000, sdk=0x020000, endian="<", tools=0):
    return struct.pack(endian + "6I", 0x32, 24 + tools * 8, platform, minimum, sdk, tools) + bytes(tools * 8)


def thin(commands, endian="<", wide=True, cpu=0x0100000C, subtype=0):
    header = struct.pack(endian + "7I", 0xFEEDFACF if wide else 0xFEEDFACE,
                         cpu, subtype, 2, len(commands), sum(map(len, commands)), 0)
    return header + (bytes(4) if wide else b"") + b"".join(commands) + b"unchanged-code-payload"


def fat(slices, endian=">", wide=False):
    entry_size = 32 if wide else 20
    data = bytearray(8 + entry_size * len(slices))
    struct.pack_into(endian + "2I", data, 0, 0xCAFEBABF if wide else 0xCAFEBABE, len(slices))
    for index, blob in enumerate(slices):
        data.extend(bytes((-len(data)) % 64))
        offset = len(data)
        cpu, subtype = struct.unpack_from("<2I", blob, 4)
        entry = struct.pack(endian + ("2I2Q2I" if wide else "5I"),
                            cpu, subtype, offset, len(blob), 6, *([0] if wide else []))
        data[8 + index * entry_size:8 + (index + 1) * entry_size] = entry
        data.extend(blob)
    return bytes(data)


class PlatformTests(unittest.TestCase):
    patcher = None

    def patch(self, blob):
        buffer = ctypes.create_string_buffer(blob, max(1, len(blob)))
        error = ctypes.create_string_buffer(256)
        result = self.patcher(buffer, len(blob), MINIMUM, SDK, error, len(error))
        return result, buffer.raw[:len(blob)], error.value.decode()

    def assert_rejected_without_writes(self, blob):
        result, output, error = self.patch(blob)
        self.assertEqual(result, -1)
        self.assertTrue(error)
        self.assertEqual(output, blob)

    def test_foreign_platforms_are_retargeted_without_changing_code_or_architecture(self):
        for platform in (1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12):
            with self.subTest(platform=platform):
                blob = thin([build_version(platform, tools=2)])
                result, output, error = self.patch(blob)
                expected = bytearray(blob)
                struct.pack_into("<3I", expected, 40, 2, MINIMUM, SDK)
                self.assertEqual((result, error), (1, ""))
                self.assertEqual(output, expected)
                self.assertEqual(self.patch(output), (0, output, ""))

    def test_ios_binaries_are_byte_identical(self):
        blob = thin([build_version(2)])
        self.assertEqual(self.patch(blob), (0, blob, ""))

    def test_embedded_ios_framework_minimum_is_lowered_without_changing_sdk(self):
        for endian in ("<", ">"):
            with self.subTest(endian=endian):
                blob = thin([build_version(2, minimum=0x1B0000, sdk=0x1B0000, endian=endian)], endian=endian)
                result, output, error = self.patch(blob)
                expected = bytearray(blob)
                struct.pack_into(endian + "I", expected, 44, MINIMUM)
                self.assertEqual((result, error), (1, ""))
                self.assertEqual(output, expected)
                self.assertEqual(self.patch(output), (0, output, ""))

    def test_embedded_legacy_ios_framework_minimum_is_lowered(self):
        blob = thin([struct.pack("<4I", 0x25, 16, 0x1B0000, 0x1B0000)])
        result, output, error = self.patch(blob)
        expected = bytearray(blob)
        struct.pack_into("<I", expected, 40, MINIMUM)
        self.assertEqual((result, error), (1, ""))
        self.assertEqual(output, expected)

    def test_legacy_platforms_keep_the_same_command_layout(self):
        for kind in (0x24, 0x2F, 0x30):
            for endian in ("<", ">"):
                for wide in (False, True):
                    with self.subTest(kind=kind, endian=endian, wide=wide):
                        blob = thin([struct.pack(endian + "4I", kind, 16, 0x010000, 0x020000)], endian, wide)
                        result, output, error = self.patch(blob)
                        offset = 32 if wide else 28
                        expected = bytearray(blob)
                        struct.pack_into(endian + "4I", expected, offset, 0x25, 16, MINIMUM, SDK)
                        self.assertEqual((result, error), (1, ""))
                        self.assertEqual(output, expected)

    def test_legacy_ios_is_unchanged(self):
        blob = thin([struct.pack("<4I", 0x25, 16, 0x10000, 0x20000)])
        self.assertEqual(self.patch(blob), (0, blob, ""))

    def test_big_endian_build_version(self):
        blob = thin([build_version(3, endian=">")], endian=">")
        result, output, _ = self.patch(blob)
        self.assertEqual(result, 1)
        self.assertEqual(struct.unpack_from(">3I", output, 40), (2, MINIMUM, SDK))

    def test_universal_32_and_64_tables_in_both_byte_orders(self):
        ios = thin([build_version(2)])
        vision = thin([build_version(11)])
        simulator = thin([build_version(7)], cpu=0x01000007, subtype=3)
        for wide in (False, True):
            for endian in ("<", ">"):
                with self.subTest(wide=wide, endian=endian):
                    blob = fat([ios, vision, simulator], endian, wide)
                    result, output, error = self.patch(blob)
                    expected = fat([ios, self.patch(vision)[1], self.patch(simulator)[1]], endian, wide)
                    self.assertEqual((result, error), (2, ""))
                    self.assertEqual(output, expected)

    def test_resources_and_tiny_files_are_unchanged(self):
        for blob in (b"", b"\xca", b"<?xml version='1.0'?><plist/>", b"bplist00", bytes(500)):
            self.assertEqual(self.patch(blob), (0, blob, ""))

    def test_no_platform_command_is_unchanged(self):
        blob = thin([])
        self.assertEqual(self.patch(blob), (0, blob, ""))

    def test_truncated_headers_and_tables(self):
        blob = thin([build_version(3)])
        for length in range(4, 56):
            self.assert_rejected_without_writes(blob[:length])
        self.assert_rejected_without_writes(struct.pack(">2I", 0xCAFEBABE, 100))
        self.assert_rejected_without_writes(struct.pack(">2I", 0xCAFEBABE, 0))

    def test_invalid_load_command_lengths(self):
        for length in (0, 4, 8, 16, 23, 25, 0xFFFFFFFF):
            blob = bytearray(thin([build_version(3)]))
            struct.pack_into("<I", blob, 36, length)
            self.assert_rejected_without_writes(bytes(blob))

    def test_tool_table_must_fit(self):
        blob = bytearray(thin([build_version(3)]))
        struct.pack_into("<I", blob, 52, 100)
        self.assert_rejected_without_writes(bytes(blob))

    def test_ambiguous_and_unknown_platforms(self):
        self.assert_rejected_without_writes(thin([build_version(3), build_version(2)]))
        for platform in (0, 13, 0xFFFFFFFF):
            self.assert_rejected_without_writes(thin([build_version(platform)]))

    def test_encryption_is_not_disabled(self):
        encrypted = struct.pack("<6I", 0x2C, 24, 0, 0, 1, 0)
        self.assert_rejected_without_writes(thin([build_version(3), encrypted]))
        clear = struct.pack("<6I", 0x2C, 24, 0, 0, 0, 0)
        self.assertEqual(self.patch(thin([build_version(3), clear]))[0], 1)

    def test_bad_later_slice_does_not_partially_patch_first(self):
        self.assert_rejected_without_writes(fat([thin([build_version(3)]), thin([build_version(99)])]))

    def test_slice_ranges_and_architecture_table_are_validated(self):
        original = fat([thin([build_version(3)]), thin([build_version(11)])])
        for offset, value in ((16, 4), (20, 0xFFFFFFFF), (24, 64), (8, 0)):
            blob = bytearray(original)
            struct.pack_into(">I", blob, offset, value)
            self.assert_rejected_without_writes(bytes(blob))
        overlapping = bytearray(original)
        overlapping[36:44] = overlapping[16:24]
        self.assert_rejected_without_writes(bytes(overlapping))

    def test_unknown_load_commands_are_preserved(self):
        unknown = struct.pack("<2I", 0x777, 8)
        result, output, error = self.patch(thin([unknown, build_version(11)]))
        self.assertEqual((result, error), (1, ""))
        self.assertEqual(output[32:40], unknown)

    def test_cpu_subtype_capability_bits_are_preserved(self):
        blob = bytearray(fat([thin([build_version(11)])]))
        struct.pack_into(">I", blob, 12, 0x80000000)
        result, output, error = self.patch(bytes(blob))
        self.assertEqual((result, error), (1, ""))
        self.assertEqual(output[8:16], blob[8:16])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-swift", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="asign-platform-tests-") as scratch:
        directory = Path(scratch)
        library = directory / ("platform.dylib" if sys.platform == "darwin" else "platform.so")
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        str(ROOT / "Asign/Utilities/MachO/PlatformCompatibility.c"), "-o", str(library)], check=True)
        loaded = ctypes.CDLL(str(library))
        patcher = loaded.KsignPatchPlatformMetadata
        patcher.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32,
                            ctypes.c_void_p, ctypes.c_size_t]
        patcher.restype = ctypes.c_int
        PlatformTests.patcher = staticmethod(patcher)
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PlatformTests))
        if not result.wasSuccessful():
            return 1
        fuzz = directory / "platform-fuzz"
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-I", str(ROOT / "Asign/Utilities/MachO"),
                        str(ROOT / "Asign/Utilities/MachO/PlatformCompatibility.c"),
                        str(ROOT / "Tests/PlatformCompatibility/fuzz.c"), "-o", str(fuzz)], check=True)
        # This parser allocates no heap memory. Keep address/UB checks enabled;
        # LeakSanitizer cannot inspect processes in traced development containers.
        fuzz_env = dict(os.environ)
        fuzz_env["ASAN_OPTIONS"] = fuzz_env.get("ASAN_OPTIONS", "") + ":detect_leaks=0"
        subprocess.run([str(fuzz)], env=fuzz_env, check=True)
        swift = shutil.which("swiftc")
        if not swift:
            print("Swift trigger/plist tests unavailable: swiftc is not installed.", flush=True)
            return 1 if args.require_swift else 0
        module = directory / ("libIDeviceSwift.dylib" if sys.platform == "darwin" else "libIDeviceSwift.so")
        swift_flags = ["-swift-version", "5"]
        if sys.platform == "darwin":
            swift_flags += ["-target", platform.machine() + "-apple-macosx14.0"]
        subprocess.run([swift, *swift_flags, "-emit-library", "-emit-module", "-module-name", "IDeviceSwift",
                        str(ROOT / "Native/Device/InstallPreflight.swift"),
                        "-emit-module-path", str(directory / "IDeviceSwift.swiftmodule"), "-o", str(module)], check=True)
        executable = directory / "platform-tests"
        subprocess.run([swift, *swift_flags, "-I", scratch, "-L", scratch, "-lIDeviceSwift",
                        str(ROOT / "Asign/Utilities/Handlers/SigningPlatformCompatibility.swift"),
                        str(ROOT / "Asign/Views/Signing/SigningPreflight.swift"),
                        str(ROOT / "Tests/PlatformCompatibility/main.swift"), "-o", str(executable)], check=True)
        env = dict(os.environ)
        env["DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"] = scratch
        subprocess.run([str(executable)], env=env, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
