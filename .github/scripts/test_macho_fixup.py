#!/usr/bin/env python3
"""Check the production arm64e patch and count its synchronous disk flushes."""
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

from test_device_connection import swift_block

ROOT = Path(__file__).resolve().parents[2]


def main():
    production = swift_block((ROOT / "Ksign/Utilities/MachO/MachOUtils.m").read_text(),
                             "NSString *LCPatchMachOFixupARM64eSlice(")
    headers = """
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <arpa/inet.h>
#include <stdlib.h>
static int syncs;
static int tracked_msync(void *base, size_t size, int flags) {
    syncs++;
    assert(flags == MS_SYNC);
    return msync(base, size, flags);
}
#define msync tracked_msync
"""
    if sys.platform == "darwin":
        headers += '#import "' + str(ROOT / "Ksign/Utilities/MachO/MachOUtils.h") + '"\n'
    else:
        headers += '#include "' + str(ROOT / "ZsignLatest/Sources/ZsignC/Core/common/mach-o.h") + '"\n'
        headers += "#define OSSwapInt32(x) __builtin_bswap32(x)\n#define YES true\n#define NO false\n#define nil NULL\n"
        # Only bridge Foundation error strings on Linux. Retain the production
        # file mapping, architecture checks, mutation and msync call verbatim.
        production = re.sub(r'\[NSString stringWithFormat:.*?\]', '"patch error"', production)
        production = production.replace("NSString *", "const char *").replace("BOOL ", "bool ")
    harness = """
int main(int argc, char **argv) {
    assert(argc == 4);
    const void *error = LCPatchMachOFixupARM64eSlice(argv[1]);
    assert(syncs == atoi(argv[2]));
    assert((error != NULL) == atoi(argv[3]));
    return 0;
}
"""

    def thin(subtype):
        return struct.pack("<IIIIIIII", 0xfeedfacf, 0x100000c, subtype, 6, 0, 0, 0, 0) + bytes(4096 - 32)

    def fat(subtypes):
        data = struct.pack(">II", 0xcafebabe, len(subtypes))
        for i, subtype in enumerate(subtypes):
            data += struct.pack(">IIIII", 0x100000c, subtype, 4096 * (i + 1), 4096, 12)
        return data.ljust(4096, b"\0") + b"".join(thin(s) for s in subtypes)

    with tempfile.TemporaryDirectory(prefix="asign-macho-fixup-") as folder:
        work = Path(folder)
        source = work / ("fixup.m" if sys.platform == "darwin" else "fixup.c")
        source.write_text(headers + production + harness)
        executable = work / "fixup"
        subprocess.run(["clang", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        *(["-fmodules", "-framework", "Foundation"] if sys.platform == "darwin" else []),
                        str(source), "-o", str(executable)], check=True)

        def check(label, data, syncs=0, error=False):
            path = work / label
            path.write_bytes(data)
            subprocess.run([str(executable), str(path), str(syncs), str(int(error))], check=True, timeout=10)
            return path.read_bytes()

        for label, data in [("thin", thin(0)), ("thin-arm64e", thin(2)), ("fat-arm64", fat([0])),
                            ("fat-fixed", fat([0, 0x80000002]))]:
            assert check(label, data) == data
        for subtypes in ([2], [0, 2]):
            original = fat(subtypes)
            expected = bytearray(original)
            i = len(subtypes) - 1
            struct.pack_into(">I", expected, 8 + 20 * i + 4, 0x80000002)
            struct.pack_into("<I", expected, 4096 * (i + 1) + 8, 0x80000002)
            patched = check(f"patch-{len(subtypes)}", original, syncs=1)
            assert patched == expected
            assert check(f"repeat-{len(subtypes)}", patched) == patched
        for label, data in [("empty", b""), ("short", b"\xca\xfe"),
                            ("short-fat", struct.pack(">I", 0xcafebabe)),
                            ("fat-count", struct.pack(">II", 0xcafebabe, 0xffffffff))]:
            assert check(label, data, error=True) == data
        for label, field, value in [("bad-offset", 16, 0xfffffff0), ("bad-size", 20, 0xffffffff),
                                    ("short-slice", 20, 4), ("bad-header", 4096, 0)]:
            data = bytearray(fat([2]))
            struct.pack_into(">I" if field < 4096 else "<I", data, field, value)
            assert check(label, data, error=True) == data
    print("Passed arm64e fixups, unchanged-file zero flushes, one flush per patch, repeat no-ops and truncated input rejection.")


if __name__ == "__main__":
    main()
