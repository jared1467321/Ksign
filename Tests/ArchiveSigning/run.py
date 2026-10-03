#!/usr/bin/env python3
"""Native archive/signing regression tests; pass a SideStore/minizip-ng checkout."""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile
import unittest
import warnings
import zipfile

REPO = Path(__file__).resolve().parents[2]
ROOT = 'Payload/Test.app'


def build(dependency, output):
    names = ['mz_crypt', 'mz_os', 'mz_os_posix', 'mz_strm', 'mz_strm_buf',
             'mz_strm_mem', 'mz_strm_split', 'mz_strm_zlib', 'mz_strm_os_posix',
             'mz_zip', 'mz_zip_rw']
    lib = output / 'libarchive_signing.so'
    subprocess.run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', '-O1',
                    '-I' + str(dependency / 'include'), '-I' + str(dependency),
                    '-I' + str(REPO / 'ASignArchiveKit/Sources/CASignArchive/include'),
                    str(REPO / 'ASignArchiveKit/Sources/CASignArchive/CASignArchive.c'),
                    *[str(dependency / (n + '.c')) for n in names], '-lz', '-o', str(lib)], check=True)
    core = REPO / 'ZsignLatest/Sources/ZsignC/Core'
    sources = [*core.glob('*.cpp'), *core.joinpath('common').glob('*.cpp')]
    driver = output / 'sign-fixture'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1',
                    '-Wno-deprecated-declarations', '-I' + str(dependency / 'include'),
                    '-I' + str(core), '-I' + str(core / 'common'),
                    str(REPO / 'Tests/ArchiveSigning/SignFixture.cpp'),
                    *map(str, sources), str(lib), '-lcrypto', '-lssl', '-lz', '-pthread',
                    '-o', str(driver)], check=True)
    return lib, driver


class ArchiveSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.source = self.dir / 'source.ipa'
        self.output = self.dir / 'signed.ipa'
        self.overlay = self.dir / 'Test.app'
        self.overlay.mkdir()

    def archive(self, entries):
        with warnings.catch_warnings(), zipfile.ZipFile(self.source, 'w') as z:
            warnings.simplefilter('ignore', UserWarning)
            for name, data, method, mode in entries:
                info = zipfile.ZipInfo(ROOT + '/' + name)
                info.compress_type = method
                info.create_system = 3
                info.external_attr = mode << 16
                z.writestr(info, data)

    def materialize(self):
        return self.lib.asign_archive_materialize_signing_inputs(
            os.fsencode(self.source), ROOT.encode(), os.fsencode(self.overlay), 0)

    def rebuild(self, level=0, deleted=b''):
        return self.lib.asign_archive_rebuild_with_overlay(
            os.fsencode(self.source), os.fsencode(self.output), ROOT.encode(),
            os.fsencode(self.overlay), deleted, 1, level, None, None)

    @staticmethod
    def raw_payload(path, info):
        with open(path, 'rb') as f:
            f.seek(info.header_offset)
            header = f.read(30)
            name_len, extra_len = struct.unpack_from('<HH', header, 26)
            f.seek(name_len + extra_len, 1)
            return f.read(info.compress_size)

    def test_raw_copy_preserves_method_payload_and_bytes(self):
        self.archive([(name, b'untouched resource ' * 1000, method, stat.S_IFREG | 0o644)
                      for name, method in [('deflated', 8), ('stored', 0)]])
        for level in (0, 6):
            self.assertEqual(self.rebuild(level), 0)
            with zipfile.ZipFile(self.source) as original, zipfile.ZipFile(self.output) as final:
                self.assertIsNone(final.testzip())
                for src in original.infolist():
                    dst = final.getinfo(src.filename)
                    self.assertEqual(dst.compress_type, src.compress_type)
                    self.assertEqual(final.read(dst), original.read(src))
                    self.assertEqual(dst.external_attr, src.external_attr)
                    self.assertEqual(self.raw_payload(self.output, dst), self.raw_payload(self.source, src))

    def test_untouched_duplicate_last_wins_once(self):
        self.archive([('resource', data, 8, stat.S_IFREG | 0o644) for data in (b'first', b'last')])
        self.assertEqual(self.rebuild(), 0)
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(len(z.infolist()), 1)
            self.assertEqual(z.read(ROOT + '/resource'), b'last')

    def test_duplicate_macho_then_resource_is_not_materialized(self):
        self.archive([('changing', data, 8, stat.S_IFREG | 0o755)
                      for data in (struct.pack('<I', 0xfeedfacf) + b'old binary', b'final resource')])
        self.assertEqual(self.materialize(), 0)
        self.assertFalse((self.overlay / 'changing').exists())
        self.assertEqual(self.rebuild(), 0)
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.read(ROOT + '/changing'), b'final resource')

    def test_duplicate_resource_then_macho_is_materialized(self):
        binary = struct.pack('<I', 0xfeedfacf) + b'final binary'
        self.archive([('changing', data, 8, stat.S_IFREG | 0o755) for data in (b'old resource', binary)])
        self.assertEqual(self.materialize(), 0)
        self.assertEqual((self.overlay / 'changing').read_bytes(), binary)
        self.assertEqual((self.overlay / 'changing').stat().st_mode & 0o777, 0o755)

    def test_overlay_replaces_all_duplicates(self):
        self.archive([('Main', data, 8, stat.S_IFREG | 0o755) for data in (b'first', b'last')])
        (self.overlay / 'Main').write_bytes(b'signed')
        (self.overlay / 'Main').chmod(0o755)
        self.assertEqual(self.rebuild(), 0)
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(len(z.infolist()), 1)
            self.assertEqual(z.read(ROOT + '/Main'), b'signed')
            self.assertEqual(z.getinfo(ROOT + '/Main').external_attr >> 16 & 0o777, 0o755)

    def test_crc_corruption_is_not_silently_accepted(self):
        self.archive([('Info.plist', b'original bytes', 0, stat.S_IFREG | 0o644)])
        with zipfile.ZipFile(self.source) as z:
            info = z.infolist()[0]
        data = bytearray(self.source.read_bytes())
        name_len, extra_len = struct.unpack_from('<HH', data, info.header_offset + 26)
        data[info.header_offset + 30 + name_len + extra_len] ^= 1
        self.source.write_bytes(data)
        self.assertEqual(self.materialize(), -105)
        result = ctypes.c_void_p()
        size = ctypes.c_int64()
        self.assertEqual(self.lib.asign_archive_read_entry(os.fsencode(self.source),
                         (ROOT + '/Info.plist').encode(), 100, ctypes.byref(result), ctypes.byref(size)), -105)
        self.assertFalse(result.value)

    def test_sparse_native_signing_matches_final_ipa(self):
        self.assert_sparse_signing((REPO / 'Zsign/test/dylib/bin/demo1.dylib').read_bytes())

    def test_fat_macho_signing_preserves_executable_mode(self):
        first = (REPO / 'Zsign/test/dylib/bin/demo1.dylib').read_bytes()
        second = bytearray(first)
        struct.pack_into('<I', second, 8, 2)  # arm64e subtype
        offset1 = 16384
        offset2 = (offset1 + len(first) + 16383) & ~16383
        header = struct.pack('>II', 0xcafebabe, 2)
        header += struct.pack('>IIIII', 0x100000c, 0, offset1, len(first), 14)
        header += struct.pack('>IIIII', 0x100000c, 2, offset2, len(second), 14)
        binary = header.ljust(offset1, b'\0') + first
        binary = binary.ljust(offset2, b'\0') + second
        self.assert_sparse_signing(binary)

    def assert_code_directory_slots(self, binary, info, resources):
        if binary[:4] == bytes.fromhex('cafebabe'):
            count = struct.unpack_from('>I', binary, 4)[0]
            for i in range(count):
                offset, size = struct.unpack_from('>II', binary, 8 + 20 * i + 8)
                self.assert_code_directory_slots(binary[offset:offset + size], info, resources)
            return
        self.assertEqual(binary[:4], bytes.fromhex('cffaedfe'))
        command = 32
        signature = None
        for _ in range(struct.unpack_from('<I', binary, 16)[0]):
            kind, size = struct.unpack_from('<II', binary, command)
            if kind == 0x1d:  # LC_CODE_SIGNATURE
                offset, length = struct.unpack_from('<II', binary, command + 8)
                signature = binary[offset:offset + length]
            command += size
        self.assertIsNotNone(signature)
        magic, length, count = struct.unpack_from('>III', signature)
        self.assertEqual(magic, 0xfade0cc0)
        directories = 0
        for i in range(count):
            _, offset = struct.unpack_from('>II', signature, 12 + i * 8)
            if struct.unpack_from('>I', signature, offset)[0] != 0xfade0c02:
                continue
            directories += 1
            hash_offset = struct.unpack_from('>I', signature, offset + 16)[0]
            hash_size, hash_type = signature[offset + 36:offset + 38]
            digest = {1: hashlib.sha1, 2: hashlib.sha256}[hash_type]
            for slot, data in [(1, info), (3, resources)]:
                start = offset + hash_offset - slot * hash_size
                self.assertEqual(signature[start:start + hash_size], digest(data).digest())
        self.assertGreater(directories, 0)

    def assert_sparse_signing(self, binary):
        bundles = ['', 'Frameworks/Demo.framework/', 'PlugIns/Demo.appex/', 'Watch/Demo.app/']
        entries = []
        for i, prefix in enumerate(bundles):
            info = plistlib.dumps({'CFBundleExecutable': 'Main', 'CFBundleIdentifier': f'com.test.demo{i}',
                                   'CFBundleName': 'Demo', 'CFBundleVersion': '1'})
            entries += [(prefix + 'Info.plist', info, 8, stat.S_IFREG | 0o644),
                        (prefix + 'Main', binary, 8, stat.S_IFREG | 0o755),
                        (prefix + 'resource', b'resource data ' * 100, 8, stat.S_IFREG | 0o644),
                        (prefix + '_CodeSignature/CodeResources', b'old signature', 8, stat.S_IFREG | 0o644)]
        entries += [('duplicate', b'first', 8, stat.S_IFREG | 0o644),
                    ('duplicate', b'last', 8, stat.S_IFREG | 0o644),
                    ('Frameworks/Demo.framework/ResourceLink', b'resource', 0, stat.S_IFLNK | 0o777)]
        self.archive(entries)
        self.assertEqual(self.materialize(), 0)
        self.assertFalse((self.overlay / 'resource').exists())
        signed = subprocess.run([str(self.driver), str(self.overlay), str(self.source), ROOT],
                                cwd=self.dir, capture_output=True, text=True)
        self.assertEqual(signed.returncode, 0, signed.stdout + signed.stderr)
        self.assertEqual(self.rebuild(), 0)
        with zipfile.ZipFile(self.output) as z:
            self.assertIsNone(z.testzip())
            self.assertEqual(len(z.namelist()), len(set(z.namelist())))
            for prefix in bundles:
                bundle_root = ROOT + '/' + prefix
                resources = z.read(bundle_root + '_CodeSignature/CodeResources')
                seal = plistlib.loads(resources)
                self.assert_code_directory_slots(z.read(bundle_root + 'Main'),
                                                 z.read(bundle_root + 'Info.plist'), resources)
                for name, record in seal['files2'].items():
                    data = z.read(bundle_root + name)
                    if 'symlink' in record:
                        self.assertEqual(data.decode(), record['symlink'])
                        self.assertTrue(stat.S_ISLNK(z.getinfo(bundle_root + name).external_attr >> 16))
                    else:
                        self.assertEqual(hashlib.sha1(data).digest(), record['hash'], bundle_root + name)
                        self.assertEqual(hashlib.sha256(data).digest(), record['hash2'], bundle_root + name)
                self.assertEqual(z.read(bundle_root + 'Main'), (self.overlay / (prefix + 'Main')).read_bytes())
                self.assertNotEqual(z.read(bundle_root + 'Main'), binary)
                self.assertEqual(z.getinfo(bundle_root + 'Main').external_attr >> 16 & 0o777, 0o755)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('minizip', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ksign-archive-tests-') as build_dir:
        lib, driver = build(args.minizip.resolve(), Path(build_dir))
        ArchiveSigningTests.lib = ctypes.CDLL(str(lib))
        ArchiveSigningTests.driver = driver
        ArchiveSigningTests.lib.asign_archive_materialize_signing_inputs.argtypes = [ctypes.c_char_p] * 3 + [ctypes.c_uint8]
        ArchiveSigningTests.lib.asign_archive_rebuild_with_overlay.argtypes = [ctypes.c_char_p] * 5 + [ctypes.c_uint8, ctypes.c_int16, ctypes.c_void_p, ctypes.c_void_p]
        ArchiveSigningTests.lib.asign_archive_read_entry.argtypes = [ctypes.c_char_p] * 2 + [ctypes.c_int64, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int64)]
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveSigningTests)
        raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
