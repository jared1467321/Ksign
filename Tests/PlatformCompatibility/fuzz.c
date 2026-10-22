#include "PlatformCompatibility.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint32_t state = 12345;
static uint32_t random32(void) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

int main(void) {
    // A valid arm64 visionOS executable and universal wrapper seed mutations
    // near every offset, command length, count and slice range.
    const uint32_t thin[] = {0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0,
                             0x32, 24, 11, 0x10000, 0x20000, 0};
    unsigned char seeds[3][256] = {{0}};
    memcpy(seeds[0], thin, sizeof(thin));
    const unsigned char fat[] = {0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1,
        1, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, sizeof(thin), 0, 0, 0, 6};
    memcpy(seeds[1], fat, sizeof(fat));
    memcpy(seeds[1] + 64, thin, sizeof(thin));
    const unsigned char fat64[] = {0xca, 0xfe, 0xba, 0xbf, 0, 0, 0, 1,
        1, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64,
        0, 0, 0, 0, 0, 0, 0, sizeof(thin), 0, 0, 0, 6, 0, 0, 0, 0};
    memcpy(seeds[2], fat64, sizeof(fat64));
    memcpy(seeds[2] + 64, thin, sizeof(thin));
    for (unsigned attempt = 0; attempt < 50000; ++attempt) {
        size_t size = random32() % 257;
        unsigned char original[256], output[256];
        memcpy(original, seeds[random32() % 3], sizeof(original));
        unsigned changes = random32() % 12;
        for (unsigned i = 0; i < changes; ++i) original[random32() % 256] = (unsigned char)random32();
        memcpy(output, original, sizeof(output));
        char error[256];
        int result = KsignPatchPlatformMetadata(output, size, 0x1a0000, 0x1a0000, error, sizeof(error));
        if (result <= 0) assert(memcmp(original, output, sizeof(output)) == 0);
        if (result < 0) assert(error[0] != '\0');
        if (result > 0) {
            assert(KsignPatchPlatformMetadata(output, size, 0x1a0000, 0x1a0000, error, sizeof(error)) == 0);
        }
    }
    puts("50,000 malformed/truncated Mach-O mutations passed with address/undefined-behavior sanitizers.");
    return 0;
}
