#!/usr/bin/env python3
"""Host regression checks for the optional ARM64 module-tracing workaround.

Uses a small compiler-pattern fixture and mocked Mach calls; no IPA or Apple SDK
is needed. These checks do not replace Apple compilation and device validation.
"""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Native/IdentityPatch"
U32 = ctypes.c_uint32
U64 = ctypes.c_uint64
WORDS = U32 * 384
PREFIX = [
    0x910163e2, 0x910153e3, 0x52800221, 0x95d4abfb, 0x35001ca0, 0xb00583e1,
    0x912d2821, 0x52800042, 0x9405de11, 0xb90017e0, 0xd0067b88, 0xf9446900,
    0x95d4a89c, 0x95d4a7ef, 0xaa0003e1, 0x9101c3e0, 0x97f6dda8, 0x910103e8,
    0x9101c3e0, 0x94049adc, 0xf9403be0, 0xb4000040, 0x97fd84ec, 0xf9402ffc,
    0xa9077fff, 0xb9400788, 0x34001988, 0xd2800013, 0xf005e7e8, 0x9117c108,
    0xf9400108, 0xf90007e8, 0xd005833a, 0x91334b5a, 0xf0055754, 0x91301a94,
    0x14000005, 0x91000673, 0xb9400788, 0xeb08027f, 0x540017c2, 0xf9400788,
    0x52800309, 0x9b092277, 0xf94002f5, 0x294222b8, 0x528203e9,
]
EXIT = [
    0xf85a83a8, 0x90067b29, 0xf9424d29, 0xf9400129, 0xeb08013f, 0x54000121,
    0xa94e7bfd, 0xa94d4ff4, 0xa94c57f6, 0xa94b5ff8, 0xa94a67fa, 0xa9496ffc,
    0x9103c3ff, 0xd65f03c0, 0x95d4a9ba,
]


class DyldPatchChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="asign-dyld-check-")
        cls.addClassCleanup(cls.scratch.cleanup)
        root = Path(cls.scratch.name)
        (root / "mach").mkdir()
        (root / "mach/mach.h").write_text("""
#ifndef MOCK_MACH_H
#define MOCK_MACH_H
#include <stdint.h>
typedef int kern_return_t;
typedef unsigned task_name_t;
typedef int task_flavor_t;
typedef int *task_info_t;
typedef unsigned mach_msg_type_number_t;
typedef uintptr_t vm_address_t;
typedef uintptr_t vm_size_t;
#define KERN_SUCCESS 0
#define KERN_FAILURE 5
#define TASK_DYLD_INFO 17
task_name_t mach_task_self(void);
kern_return_t task_info(task_name_t, task_flavor_t, task_info_t, mach_msg_type_number_t *);
kern_return_t vm_read_overwrite(task_name_t, vm_address_t, vm_size_t,
                              vm_address_t, vm_size_t *);
#endif
""")
        # The public iOS SDK deliberately rejects this macOS-only header.
        (root / "mach/mach_vm.h").write_text('#error mach_vm.h unsupported.\n')
        (root / "shim.c").write_text("""
#include "DyldPatch.c"
static uintptr_t start;
static size_t length;
static int originalStatus, reads, calls, failReads;
task_name_t mach_task_self(void) { return 1; }
kern_return_t task_info(task_name_t task, task_flavor_t flavor, task_info_t info,
                        mach_msg_type_number_t *count) {
    (void)task; (void)flavor;
    ++calls;
    if (!originalStatus && info && count) { info[0] = 123; *count = 5; }
    return originalStatus;
}
kern_return_t vm_read_overwrite(task_name_t task, vm_address_t address,
    vm_size_t size, vm_address_t output, vm_size_t *copied) {
    (void)task; ++reads;
    if (failReads || address < start || size > length || address - start > length - size) return 5;
    memcpy((void *)(uintptr_t)output, (void *)(uintptr_t)address, (size_t)size);
    *copied = size;
    return 0;
}
void configure(uintptr_t pointer, size_t size, int status, int unreadable) {
    start = pointer; length = size; originalStatus = status; failReads = unreadable;
    reads = calls = 0;
}
int query(uintptr_t caller, unsigned task, int flavor, int *info, unsigned *count) {
    return taskInfoForCaller(task, flavor, info, count, caller);
}
int readCount(void) { return reads; }
int callCount(void) { return calls; }
int appScopedBinding(void) {
    AsignIdentityBinding b = AsignDyldTaskInfoBinding();
    return !strcmp(b.name, "task_info") && b.original == (void *)task_info &&
        b.replacement == (void *)CompatibleTaskInfo && !b.includeSystemImages;
}
""")
        compiler = shutil.which(os.environ.get("CC", "cc"))
        if not compiler:
            raise RuntimeError("A host C compiler is required")
        lib = root / ("checks.dylib" if os.uname().sysname == "Darwin" else "checks.so")
        subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-D__arm64__=1",
                        "-shared", "-fPIC", "-I", str(root), "-I", str(SOURCE),
                        str(root / "shim.c"), str(SOURCE / "DyldPatchMatch.c"), "-o", str(lib)], check=True)
        cls.lib = ctypes.CDLL(str(lib))
        cls.match = cls.lib.AsignMatchUnsafeModuleTrace
        cls.match.argtypes = [ctypes.POINTER(U32), ctypes.c_size_t, U64,
                              ctypes.POINTER(U64), ctypes.POINTER(U64)]
        cls.lib.configure.argtypes = [ctypes.c_size_t, ctypes.c_size_t, ctypes.c_int, ctypes.c_int]
        cls.lib.query.argtypes = [ctypes.c_size_t, ctypes.c_uint, ctypes.c_int,
                                  ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint)]

    def fixture(self):
        words = WORDS()
        words[:len(PREFIX)] = PREFIX
        words[233:233 + len(EXIT)] = EXIT
        return words

    def matches(self, words, count=384, address=0x100718848):
        program, linkedit = U64(), U64()
        result = self.match(words, count, address, ctypes.byref(program), ctypes.byref(linkedit))
        return result, program.value, linkedit.value

    def runtime_fixture(self):
        words = self.fixture()
        base = ctypes.addressof(words)
        # Place both diagnostic strings inside the checked mock memory range.
        ctypes.memmove(base + 1200, "Program\0".encode("utf-16le"), 16)
        ctypes.memmove(base + 1240, b"__LINKEDIT\0", 11)
        for index, target in ((5, base + 1200), (34, base + 1240)):
            pc = base + index * 4
            pages = ((target & ~4095) - (pc & ~4095)) // 4096
            immediate = pages & 0x1fffff
            reg = words[index] & 31
            words[index] = 0x90000000 | (immediate & 3) << 29 | (immediate >> 2) << 5 | reg
            words[index + 1] = 0x91000000 | (target & 4095) << 10 | reg << 5 | reg
        return words

    def route(self, words, *, task=1, flavor=17, status=0, unreadable=0):
        base = ctypes.addressof(words)
        self.lib.configure(base, ctypes.sizeof(words), status, unreadable)
        info, count = ctypes.c_int(0), ctypes.c_uint(5)
        result = self.lib.query(base + 16, task, flavor, ctypes.byref(info), ctypes.byref(count))
        self.assertEqual(self.lib.callCount(), 1)
        return result, info.value, count.value

    def test_crash_pattern_and_relocated_addresses(self):
        self.assertEqual(self.matches(self.fixture()), (1, 0x10b795b4a, 0x10b203c06))
        for slide in (0x4000, 0x734000, 0x120000000):
            self.assertEqual(self.matches(self.fixture(), address=0x100718848 + slide),
                             (1, 0x10b795b4a + slide, 0x10b203c06 + slide))

    def test_register_and_stack_variants(self):
        w = self.fixture()
        info, index, entry, header = 27, 22, 24, 20
        w[0] = 0x910183e2  # output now at sp+0x60
        w[23] = 0xf9400000 | 12 << 10 | 31 << 5 | info
        w[25] = w[38] = 0xb9400400 | info << 5 | 8
        w[27] = 0xd2800000 | index
        w[37] = 0x91000400 | index << 5 | index
        w[39] = 0xeb08001f | index << 5
        w[41] = 0xf9400400 | info << 5 | 8
        w[43] = 0x9b092000 | index << 5 | entry
        w[44] = 0xf9400000 | entry << 5 | header
        w[45] = (w[45] & ~0x3e0) | header << 5
        self.assertEqual(self.matches(w)[0], 1)

    def test_negative_page_reference(self):
        words = self.fixture()
        pages = (-4) & 0x1fffff
        words[5] = 0x90000001 | (pages & 3) << 29 | (pages >> 2) << 5
        self.assertEqual(self.matches(words)[1], 0x100714b4a)

    def test_unknown_or_guarded_patterns_rejected(self):
        for index, replacement in ((2, 0x52800021), (4, 0xd503201f), (7, 0xd503201f),
                                   (21, 0xb4000060), (42, 0x52800209), (43, 0xd503201f),
                                   (44, 0xb40000f7), (45, 0xd503201f), (46, 0x52800009),
                                   (233, 0x94000001), (246, 0xd503201f)):
            with self.subTest(index=index):
                words = self.fixture()
                words[index] = replacement
                self.assertEqual(self.matches(words)[0], 0)

    def test_truncated_and_invalid_branches_rejected(self):
        for count in (0, 4, 46, 64, 233, 247):
            self.assertEqual(self.matches(self.fixture(), count=count)[0], 0)
        for branch in (0x35ffffe0, 0x35000020, 0x357fffe0):
            words = self.fixture()
            words[4] = branch
            self.assertEqual(self.matches(words)[0], 0)
        self.assertEqual(self.matches(self.fixture(), address=1)[0], 0)

    def test_recognized_optional_trace_uses_error_exit(self):
        self.assertEqual(self.route(self.runtime_fixture()), (5, 123, 5))
        self.assertEqual(self.lib.readCount(), 3)
        self.assertEqual(self.lib.appScopedBinding(), 1)

    def test_other_queries_and_original_errors_pass_through(self):
        for arguments in (dict(task=2), dict(flavor=4), dict(status=4), dict(status=5)):
            with self.subTest(arguments=arguments):
                result, _, _ = self.route(self.runtime_fixture(), **arguments)
                self.assertEqual(result, arguments.get("status", 0))
                self.assertEqual(self.lib.readCount(), 0)

    def test_unreadable_or_changed_code_passes_through(self):
        words = self.runtime_fixture()
        self.assertEqual(self.route(words, unreadable=1), (0, 123, 5))
        self.assertEqual(self.route(words), (5, 123, 5))
        words[44] = 0xd503201f
        self.assertEqual(self.route(words), (0, 123, 5))  # no stale classification cache

    def test_diagnostic_strings_required(self):
        for offset in (1200, 1240):
            words = self.runtime_fixture()
            ctypes.memset(ctypes.addressof(words) + offset, 0, 1)
            self.assertEqual(self.route(words), (0, 123, 5))


if __name__ == "__main__":
    unittest.main(verbosity=2)
