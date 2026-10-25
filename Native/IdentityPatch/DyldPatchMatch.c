#include "DyldPatchMatch.h"

static int is(uint32_t word, uint32_t mask, uint32_t value) {
    return (word & mask) == value;
}

static int saved(unsigned reg) { return reg >= 19 && reg <= 28; }

static ptrdiff_t conditionalTarget(size_t at, uint32_t word) {
    int32_t offset = (word >> 5) & 0x7ffff;
    if (offset & 0x40000) offset -= 0x80000;
    return (ptrdiff_t)at + offset;
}

static int addressPair(const uint32_t *w, size_t at, uint64_t address, uint64_t *result) {
    unsigned reg = w[at] & 31;
    if (reg == 31 || !is(w[at], 0x9f000000, 0x90000000) ||
        !is(w[at + 1], 0xffc003ff, 0x91000000 | reg << 5 | reg)) return 0;
    int64_t pages = ((w[at] >> 5) & 0x7ffff) << 2 | ((w[at] >> 29) & 3);
    if (pages & 0x100000) pages -= 0x200000;
    *result = ((address + at * 4) & ~UINT64_C(4095)) + (uint64_t)(pages * 4096) +
        ((w[at + 1] >> 10) & 4095);
    return 1;
}

// Only accept a normal stack-protected return on task_info failure. Do not
// suppress queries whose failure leads to application work or an exception.
static int errorExit(const uint32_t *w, size_t count, size_t at) {
    if (at >= count || count - at < 15) return 0;
    const uint32_t *e = w + at;
    if (!is(e[0], 0xffe00fff, 0xf84003a8) || // ldur x8, [fp, canary]
        !is(e[1], 0x9f00001f, 0x90000009) || // adrp x9, canary page
        !is(e[2], 0xffc003ff, 0xf9400129) || // ldr x9, [x9, offset]
        e[3] != 0xf9400129 || e[4] != 0xeb08013f ||
        !is(e[5], 0xff00001f, 0x54000001) ||
        conditionalTarget(5, e[5]) != 14 || // b.ne stack_chk_fail
        !is(e[14], 0xfc000000, 0x94000000)) return 0;
    static const uint32_t restores[] = {
        0xa9407bfd, 0xa9404ff4, 0xa94057f6,
        0xa9405ff8, 0xa94067fa, 0xa9406ffc
    };
    for (size_t i = 0; i < 6; ++i)
        if (!is(e[6 + i], 0xffc07fff, restores[i])) return 0;
    return is(e[12], 0xffc003ff, 0x910003ff) && e[13] == 0xd65f03c0;
}

int AsignMatchUnsafeModuleTrace(const uint32_t *w, size_t count,
                               uint64_t address, uint64_t *program, uint64_t *linkedit) {
    if (!w || !program || !linkedit || count < 65 || (address & 3)) return 0;
    // task_info(self, TASK_DYLD_INFO, stack buffer, &count); cbnz w0, return
    if (!is(w[0], 0xffc003ff, 0x910003e2) ||
        !is(w[1], 0xffc003ff, 0x910003e3) ||
        w[2] != 0x52800221 || !is(w[3], 0xfc000000, 0x94000000) ||
        !is(w[4], 0xff00001f, 0x35000000)) return 0;
    ptrdiff_t failure = conditionalTarget(4, w[4]);
    if (failure < 50 || (size_t)failure >= count || !errorExit(w, count, (size_t)failure)) return 0;

    // The heap-trace "Program" spec and Foundation path preparation distinguish
    // this diagnostic initializer from functional consumers of TASK_DYLD_INFO.
    if (!addressPair(w, 5, address, program) || (w[5] & 31) != 1 ||
        w[7] != 0x52800042 || !is(w[8], 0xfc000000, 0x94000000) ||
        !is(w[9], 0xffc003ff, 0xb90003e0) ||
        !is(w[10], 0x9f000000, 0x90000000) ||
        !is(w[11], 0xffc0001f, 0xf9400000) ||
        ((w[11] >> 5) & 31) != (w[10] & 31) ||
        !is(w[12], 0xfc000000, 0x94000000) ||
        !is(w[13], 0xfc000000, 0x94000000) || w[14] != 0xaa0003e1 ||
        !is(w[15], 0xffc003ff, 0x910003e0) ||
        !is(w[16], 0xfc000000, 0x94000000) ||
        !is(w[17], 0xffc003ff, 0x910003e8) ||
        !is(w[18], 0xffc003ff, 0x910003e0) ||
        !is(w[19], 0xfc000000, 0x94000000) ||
        !is(w[20], 0xffc003ff, 0xf94003e0) ||
        w[21] != 0xb4000040 || !is(w[22], 0xfc000000, 0x94000000)) return 0;

    unsigned info = w[23] & 31, index = w[27] & 31;
    unsigned channel = w[28] & 31, counter = w[25] & 31;
    unsigned array = w[41] & 31, stride = w[42] & 31;
    unsigned entry = w[43] & 31, header = w[44] & 31;
    uint32_t buffer = (w[0] >> 10) & 4095;
    uint64_t unused;
    if (!saved(info) || !saved(index) || info == index || !saved(header) ||
        channel == 31 || counter == 31 || array == 31 || stride == 31 || entry == 31 ||
        array == stride || entry == info || entry == index ||
        (buffer & 7) || w[23] != (0xf94003e0 | (buffer / 8) << 10 | info) ||
        !is(w[24], 0xffc07fff, 0xa9007fff) ||
        w[25] != (0xb9400400 | info << 5 | counter) ||
        !is(w[26], 0xff00001f, 0x34000000 | counter) ||
        w[27] != (0xd2800000 | index) ||
        !addressPair(w, 28, address, &unused) ||
        w[30] != (0xf9400000 | channel << 5 | channel) ||
        !is(w[31], 0xffc003ff, 0xf90003e0 | channel) ||
        !addressPair(w, 32, address, &unused) ||
        !addressPair(w, 34, address, linkedit) ||
        w[36] != 0x14000005 ||
        w[37] != (0x91000400 | index << 5 | index) ||
        w[38] != w[25] || w[39] != (0xeb00001f | counter << 16 | index << 5) ||
        !is(w[40], 0xff00001f, 0x54000002) ||
        w[41] != (0xf9400400 | info << 5 | array) ||
        w[42] != (0x52800300 | stride) ||
        w[43] != (0x9b000000 | stride << 16 | array << 10 | index << 5 | entry) ||
        w[44] != (0xf9400000 | entry << 5 | header) ||
        !is(w[45], 0xffff83e0, 0x29420000 | header << 5) ||
        !is(w[46], 0xffffffe0, 0x528203e0)) return 0;
    ptrdiff_t cleanup = conditionalTarget(26, w[26]);
    return cleanup >= 50 && cleanup < failure && conditionalTarget(40, w[40]) == cleanup;
}
