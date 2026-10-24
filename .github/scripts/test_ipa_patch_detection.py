#!/usr/bin/env python3
"""Exercise read-only prepatched detection using the production native code."""
import ctypes
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

from test_ipa_patching import ROOT, dylib, fat, runpath, thin


class PatchDetectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="asign-patch-detection-")
        cls.directory = Path(cls.scratch.name)
        library = cls.directory / ("detect.dylib" if sys.platform == "darwin" else "detect.so")
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-shared",
                        str(ROOT / "Asign/Utilities/MachO/IPAPatch.c"), "-o", str(library)], check=True)
        cls.native = ctypes.CDLL(str(library))
        cls.detect = cls.native.KsignIPAFileHasPatchLibrary
        cls.detect.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
        cls.detect.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def inspect(self, blob, library=b"blatantsPatch.dylib"):
        target = self.directory / "Executable"
        if target.exists():
            target.chmod(0o644)
        target.write_bytes(blob)
        target.chmod(0o444)
        error = ctypes.create_string_buffer(512)
        result = self.detect(os.fsencode(target), library, error, len(error))
        self.assertEqual(target.read_bytes(), blob)
        self.assertEqual(target.stat().st_mode & 0o777, 0o444)
        return result, error.value.decode()

    def test_strong_and_weak_loads_in_all_thin_formats(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                for weak in (False, True):
                    for path in (b"@rpath/blatantsPatch.dylib", b"@executable_path/blatantsPatch.dylib",
                                 b"@loader_path/../../Frameworks/blatantsPatch.dylib"):
                        with self.subTest(endian=endian, wide=wide, weak=weak, path=path):
                            self.assertEqual(self.inspect(thin([dylib(path, weak, endian, wide)],
                                                               endian, wide)), (1, ""))

    def test_every_universal_slice_must_already_load_the_patch(self):
        patched = thin([dylib(b"@rpath/blatantsPatch.dylib")])
        patched32 = thin([dylib(b"@rpath/blatantsPatch.dylib", wide=False)], wide=False)
        for endian in ("<", ">"):
            for wide in (False, True):
                for slices, expected in (([patched, patched32], 1), ([patched, thin()], 0),
                                         ([thin(), patched], 0)):
                    with self.subTest(endian=endian, wide=wide, expected=expected):
                        self.assertEqual(self.inspect(fat(slices, endian, wide)), (expected, ""))

    def test_companion_and_blatant_loads_are_detected_independently(self):
        identity = b"asignIdentity.dylib"
        for loads, expected in (([], (0, 0)), ([dylib(b"@rpath/blatantsPatch.dylib")], (1, 0)),
                                ([dylib(b"@rpath/asignIdentity.dylib")], (0, 1)),
                                ([dylib(b"@rpath/blatantsPatch.dylib"), dylib(b"@rpath/asignIdentity.dylib")], (1, 1))):
            blob = thin(loads)
            self.assertEqual((self.inspect(blob)[0], self.inspect(blob, identity)[0]), expected)
        both = thin([dylib(b"@rpath/blatantsPatch.dylib"), dylib(b"@rpath/asignIdentity.dylib")])
        partial = fat([both, thin([dylib(b"@rpath/blatantsPatch.dylib")])])
        self.assertEqual(self.inspect(partial), (1, ""))
        self.assertEqual(self.inspect(partial, identity), (0, ""))

    def test_incidental_strings_and_different_library_names_are_not_patch_loads(self):
        for blob in (thin(), thin() + b"blatantsPatch.dylib\0",
                     thin([runpath(b"@rpath/blatantsPatch.dylib")]),
                     thin([dylib(b"@rpath/notblatantsPatch.dylib")]),
                     thin([dylib(b"@rpath/blatantsPatch.dylib.backup")])):
            self.assertEqual(self.inspect(blob), (0, ""))
        # LC_ID_DYLIB names the image itself; it does not load a patch.
        identity = bytearray(dylib(b"@rpath/blatantsPatch.dylib"))
        struct.pack_into("<I", identity, 0, 0xD)
        self.assertEqual(self.inspect(thin([identity])), (0, ""))

    def test_detection_does_not_require_rewriting_legacy_section_layouts(self):
        legacy = bytearray(thin([dylib(b"@rpath/blatantsPatch.dylib")]))
        struct.pack_into("<I", legacy, 32 + 72 + 48, 32)  # Section overlaps the headers.
        self.assertEqual(self.inspect(legacy), (1, ""))

    def test_malformed_command_tables_never_count_as_patched(self):
        good = thin([dylib(b"@rpath/blatantsPatch.dylib")])
        bad_size = bytearray(good)
        struct.pack_into("<I", bad_size, 32 + 4, len(good))
        bad_path = bytearray(dylib(b"@rpath/blatantsPatch.dylib"))
        struct.pack_into("<I", bad_path, 8, len(bad_path))
        bad_tail = bytearray(good)
        last = 32 + struct.unpack_from("<I", bad_tail, 20)[0] - 16
        struct.pack_into("<I", bad_tail, last + 4, 0)
        bad_fat = bytearray(fat([good, good]))
        struct.pack_into(">I", bad_fat, 36, 64)  # Overlapping slices.
        for blob in (b"", b"abcd", good[:90], bad_size, thin([bad_path]), bad_tail, bad_fat):
            with self.subTest(size=len(blob)):
                result, error = self.inspect(blob)
                self.assertEqual(result, -1)
                self.assertTrue(error)

    def test_missing_files_and_symlinks_are_rejected(self):
        target = self.directory / "UntrustedLink"
        target.symlink_to(self.directory / "Executable")
        for path in (target, self.directory / "Missing", self.directory):
            error = ctypes.create_string_buffer(512)
            self.assertEqual(self.detect(os.fsencode(path), b"blatantsPatch.dylib", error, len(error)), -1)
            self.assertTrue(error.value)


if __name__ == "__main__":
    unittest.main(verbosity=2)
