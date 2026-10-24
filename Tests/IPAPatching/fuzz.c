#include "IPAPatch.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t state = 0x4271;
static uint32_t random32(void) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

int main(int argc, char **argv) {
    size_t attempts = 0;
    for (int fixture = 1; fixture < argc; ++fixture) {
        FILE *file = fopen(argv[fixture], "rb");
        assert(file);
        assert(fseek(file, 0, SEEK_END) == 0);
        long length = ftell(file);
        assert(length > 0 && length < 1024 * 1024);
        rewind(file);
        size_t size = (size_t)length;
        uint8_t *original = malloc(size), *input = malloc(size), *snapshot = malloc(size);
        assert(original && input && snapshot);
        assert(fread(original, 1, size, file) == size);
        fclose(file);
        for (unsigned iteration = 0; iteration < 20000; ++iteration) {
            memcpy(input, original, size);
            for (unsigned change = 0, changes = random32() % 8; change < changes; ++change)
                input[random32() % size] ^= (uint8_t)random32();
            size_t used = iteration % 4 ? size : random32() % size;
            memcpy(snapshot, input, size);
            char error[256];
            const char *path = iteration % 2 ? "@executable_path/Frameworks/blatantsPatch.dylib" :
                                             "@executable_path/Frameworks/asignIdentity.dylib";
            int result = KsignPatchIPALoadCommands(input, used, path, NULL, NULL, error, sizeof(error));
            if (result < 0) {
                assert(error[0]);
                assert(memcmp(input, snapshot, size) == 0);
            }
            ++attempts;
        }
        free(snapshot);
        free(input);
        free(original);
    }
    printf("IPA patch parser: %zu mutation/truncation checks passed under ASan/UBSan\n", attempts);
    return 0;
}
