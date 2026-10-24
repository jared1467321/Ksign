#if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#include "IPAPatch.h"
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { size_t offset, size, commands; int compact; } PatchSlice;

static uint32_t read32(const uint8_t *p, int big) {
    uint32_t result = 0;
    for (int i = 0; i < 4; ++i) result |= (uint32_t)p[i] << ((big ? 3 - i : i) * 8);
    return result;
}

static uint64_t read64(const uint8_t *p, int big) {
    uint64_t result = 0;
    for (int i = 0; i < 8; ++i) result |= (uint64_t)p[i] << ((big ? 7 - i : i) * 8);
    return result;
}

static void write32(uint8_t *p, uint32_t value, int big) {
    for (int i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> ((big ? 3 - i : i) * 8));
}

static int fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
    return -1;
}

static int thinMagic(uint32_t magic) {
    return magic == 0xfeedface || magic == 0xfeedfacf || magic == 0xcefaedfe || magic == 0xcffaedfe;
}

static const char *basenameOf(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// Share architecture-table validation between read-only detection and edits.
static int collectSlices(const uint8_t *bytes, size_t size, PatchSlice slices[64],
                         uint32_t *sliceCount, char *error, size_t errorSize) {
    if (!bytes || size < 4) return fail(error, errorSize, "Invalid Mach-O executable.");
    uint32_t magic = read32(bytes, 1), count = 1;
    slices[0] = (PatchSlice){0, size, 0, 0};
    if (!thinMagic(magic)) {
        int big = magic == 0xcafebabe || magic == 0xcafebabf;
        int wide = magic == 0xcafebabf || magic == 0xbfbafeca;
        if (size < 8 || !(big || magic == 0xbebafeca || magic == 0xbfbafeca))
            return fail(error, errorSize, "Invalid Mach-O magic.");
        size_t entrySize = wide ? 32 : 20;
        count = read32(bytes + 4, big);
        if (!count || count > 64 || count > (size - 8) / entrySize)
            return fail(error, errorSize, "Invalid universal Mach-O table.");
        size_t tableEnd = 8 + count * entrySize;
        for (uint32_t i = 0; i < count; ++i) {
            const uint8_t *entry = bytes + 8 + i * entrySize;
            uint64_t offset = wide ? read64(entry + 8, big) : read32(entry + 8, big);
            uint64_t length = wide ? read64(entry + 16, big) : read32(entry + 12, big);
            uint32_t alignment = read32(entry + (wide ? 24 : 16), big);
            if (offset < tableEnd || offset > size || length < 28 || length > size - offset ||
                alignment > 63 || (offset & ((UINT64_C(1) << alignment) - 1)))
                return fail(error, errorSize, "Invalid universal Mach-O slice range.");
            for (uint32_t j = 0; j < i; ++j)
                if (offset < slices[j].offset + slices[j].size && slices[j].offset < offset + length)
                    return fail(error, errorSize, "Overlapping Mach-O slices.");
            uint32_t sliceMagic = read32(bytes + offset, 1);
            int sliceBig = sliceMagic == 0xfeedface || sliceMagic == 0xfeedfacf;
            if (!thinMagic(sliceMagic) || read32(entry, big) != read32(bytes + offset + 4, sliceBig) ||
                read32(entry + 4, big) != read32(bytes + offset + 8, sliceBig))
                return fail(error, errorSize, "Universal Mach-O architecture mismatch.");
            slices[i] = (PatchSlice){(size_t)offset, (size_t)length, 0, 0};
        }
    }
    *sliceCount = count;
    return 0;
}

static int legacyPatchName(const char *name) {
    return !strcmp(name, "blatantsPatch.dylib") || !strcmp(name, "asignIdentity.dylib");
}

static int replacesPatch(const char *name, const char *path) {
    const char *destination = basenameOf(path);
    return !strcmp(name, destination) ||
        (!strcmp(destination, "asignpatch.dylib") && legacyPatchName(name));
}

static void patchCommand(uint8_t *command, size_t size, const char *path, int big) {
    memset(command, 0, size);
    write32(command, 0x80000018, big);
    write32(command + 4, (uint32_t)size, big);
    write32(command + 8, 24, big);
    write32(command + 12, 2, big);
    memcpy(command + 24, path, strlen(path) + 1);
}

// Unified upgrades keep each existing dylib command in its original ordinal
// position. Multiple legacy loads resolve to the same single runtime image;
// removing a load could change ordinals used by unrelated symbol bindings.
// Preserve unrelated commands and use the current executable's patch path.
static int patchSlice(uint8_t *bytes, size_t size, const char *path,
                      KsignIPARunpathResolver resolver, void *context, int *compact,
                      uint8_t *scratch,
                      size_t *required, char *error, size_t errorSize) {
    if (size < 28 || !thinMagic(read32(bytes, 1)))
        return fail(error, errorSize, "Invalid Mach-O executable.");
    uint32_t magic = read32(bytes, 1);
    int big = magic == 0xfeedface || magic == 0xfeedfacf;
    int wide = magic == 0xfeedfacf || magic == 0xcffaedfe;
    size_t header = wide ? 32 : 28, alignment = wide ? 8 : 4;
    if (size < header || read32(bytes + 12, big) != 2)
        return fail(error, errorSize, "Bundle executable is not MH_EXECUTE.");
    uint32_t count = read32(bytes + 16, big), length = read32(bytes + 20, big);
    if (length > size - header || length > 4 * 1024 * 1024 || count > length / 8)
        return fail(error, errorSize, "Invalid Mach-O load command table.");

    size_t end = header + length, cursor = header, kept = 0, firstData = size;
    uint32_t keptCount = 0;
    int sawFileData = 0;
    uint32_t matches = 0;
    int unified = !strcmp(basenameOf(path), "asignpatch.dylib");
    int runpathResolution = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (end - cursor < 8) return fail(error, errorSize, "Truncated Mach-O load command.");
        const uint8_t *command = bytes + cursor;
        uint32_t kind = read32(command, big), commandSize = read32(command + 4, big);
        if (commandSize < 8 || commandSize > end - cursor || commandSize % alignment)
            return fail(error, errorSize, "Invalid Mach-O load command size.");
        int remove = 0;
        if (kind == 0xc || kind == 0x80000018) { // LC_LOAD[_WEAK]_DYLIB
            if (commandSize < 24) return fail(error, errorSize, "Invalid dylib load command.");
            uint32_t nameOffset = read32(command + 8, big);
            if (nameOffset < 24 || nameOffset >= commandSize ||
                !memchr(command + nameOffset, 0, commandSize - nameOffset))
                return fail(error, errorSize, "Invalid dylib load path.");
            remove = replacesPatch(basenameOf((const char *)command + nameOffset), path);
            if (remove) ++matches;
        } else if (kind == 0x8000001c) { // LC_RPATH
            if (commandSize < 12) return fail(error, errorSize, "Invalid runpath command.");
            uint32_t pathOffset = read32(command + 8, big);
            if (pathOffset < 12 || pathOffset >= commandSize ||
                !memchr(command + pathOffset, 0, commandSize - pathOffset))
                return fail(error, errorSize, "Invalid runpath string.");
            if (!scratch && resolver && runpathResolution == 0)
                runpathResolution = resolver((const char *)command + pathOffset, context);
        } else if (kind == 1 || kind == 0x19) { // LC_SEGMENT[_64]
            int segmentWide = kind == 0x19;
            size_t base = segmentWide ? 72 : 56, sectionSize = segmentWide ? 80 : 68;
            if (commandSize < base) return fail(error, errorSize, "Invalid Mach-O segment.");
            uint32_t sections = read32(command + (segmentWide ? 64 : 48), big);
            if (sections > (commandSize - base) / sectionSize)
                return fail(error, errorSize, "Invalid Mach-O section table.");
            uint64_t offset = segmentWide ? read64(command + 40, big) : read32(command + 32, big);
            uint64_t dataSize = segmentWide ? read64(command + 48, big) : read32(command + 36, big);
            if (offset > size || dataSize > size - offset)
                return fail(error, errorSize, "Mach-O segment extends past its slice.");
            if (dataSize && offset) {
                if (offset < firstData) firstData = (size_t)offset;
                sawFileData = 1;
            }
            for (uint32_t j = 0; j < sections; ++j) {
                const uint8_t *section = command + base + j * sectionSize;
                uint64_t sectionBytes = segmentWide ? read64(section + 40, big) : read32(section + 36, big);
                uint32_t sectionOffset = read32(section + (segmentWide ? 48 : 40), big);
                uint32_t type = read32(section + (segmentWide ? 64 : 56), big) & 0xff;
                if (!sectionBytes || type == 1 || type == 0xc || type == 0x12) continue; // zero-fill
                if (sectionOffset < end || sectionOffset > size || sectionBytes > size - sectionOffset)
                    return fail(error, errorSize, "Invalid Mach-O section range.");
                if (sectionOffset < firstData) firstData = sectionOffset;
                sawFileData = 1;
            }
        } else if (kind == 0x21 || kind == 0x2c) {
            if (commandSize < (kind == 0x2c ? 24u : 20u))
                return fail(error, errorSize, "Invalid Mach-O encryption command.");
            if (read32(command + 16, big))
                return fail(error, errorSize, "The executable is encrypted.");
        } else if (kind == 0x1d) { // Keep LC_CODE_SIGNATURE and its entitlement blob.
            if (commandSize < 16) return fail(error, errorSize, "Invalid code signature command.");
            uint32_t offset = read32(command + 8, big), dataSize = read32(command + 12, big);
            if (offset < end || offset > size || dataSize > size - offset)
                return fail(error, errorSize, "Invalid code signature range.");
            if (offset < firstData) firstData = offset;
        }
        if (!remove) {
            kept += commandSize;
            ++keptCount;
        }
        cursor += commandSize;
    }
    if (cursor != end || !sawFileData || firstData < end)
        return fail(error, errorSize, "Cannot determine safe Mach-O header padding.");
    // Cache this choice during preflight for each slice. Do not rerun a
    // filesystem resolver after earlier slices have already been modified.
    if (!scratch) *compact = runpathResolution == 1;
    char compactPath[4097];
    if (*compact) {
        snprintf(compactPath, sizeof(compactPath), "@rpath/%s", basenameOf(path));
        path = compactPath;
    }
    size_t added = (24 + strlen(path) + 1 + alignment - 1) & ~(alignment - 1);
    size_t replacements = unified && matches ? matches : 1;
    size_t total = kept + added * replacements;
    if (total > UINT32_MAX) return fail(error, errorSize, "Mach-O load commands are too large.");
    if (total > firstData - header) {
        fail(error, errorSize, "Insufficient Mach-O header space for the patch library.");
        return KSIGN_IPA_HEADER_SPACE;
    }
    // Padding is not executable data. Refuse to overwrite an unrecognized payload.
    for (size_t i = end; i < header + total; ++i)
        if (bytes[i]) return fail(error, errorSize, "Mach-O header padding contains data.");
    *required = total;
    if (scratch) {
        size_t output = 0;
        cursor = header;
        for (uint32_t i = 0; i < count; ++i) {
            const uint8_t *command = bytes + cursor;
            uint32_t kind = read32(command, big), commandSize = read32(command + 4, big);
            int replace = (kind == 0xc || kind == 0x80000018) &&
                replacesPatch(basenameOf((const char *)command + read32(command + 8, big)), path);
            if (replace && unified) {
                patchCommand(scratch + output, added, path, big);
                output += added;
            } else if (!replace) {
                memcpy(scratch + output, command, commandSize);
                output += commandSize;
            }
            cursor += commandSize;
        }
        if (!unified || !matches) patchCommand(scratch + output, added, path, big);
        memcpy(bytes + header, scratch, total);
        if (total < length) memset(bytes + header + total, 0, length - total);
        write32(bytes + 16, keptCount + (uint32_t)replacements, big);
        write32(bytes + 20, (uint32_t)total, big);
    }
    return 0;
}

int KsignPatchIPALoadCommands(void *buffer, size_t size, const char *path,
                             KsignIPARunpathResolver resolver, void *context,
                             char *error, size_t errorSize) {
    if (error && errorSize) error[0] = 0;
    if (!buffer || size < 4 || !path || strncmp(path, "@executable_path/", 17) ||
        !*basenameOf(path) || strlen(path) > 4096)
        return fail(error, errorSize, "Invalid IPA patch input.");
    uint8_t *bytes = buffer;
    uint32_t count;
    PatchSlice slices[64];
    if (collectSlices(bytes, size, slices, &count, error, errorSize) < 0) return -1;
    size_t maximum = 0;
    int needsSpace = 0;
    for (uint32_t i = 0; i < count; ++i) {
        int result = patchSlice(bytes + slices[i].offset, slices[i].size, path,
                       resolver, context, &slices[i].compact, NULL,
                       &slices[i].commands, error, errorSize);
        if (result == KSIGN_IPA_HEADER_SPACE) needsSpace = 1;
        else if (result < 0) return result;
        if (slices[i].commands > maximum) maximum = slices[i].commands;
    }
    if (needsSpace) return KSIGN_IPA_HEADER_SPACE;
    uint8_t *scratch = malloc(maximum);
    if (!scratch) return fail(error, errorSize, "Cannot allocate patch command buffer.");
    for (uint32_t i = 0; i < count; ++i)
        patchSlice(bytes + slices[i].offset, slices[i].size, path,
                   NULL, NULL, &slices[i].compact, scratch,
                   &slices[i].commands, error, errorSize);
    free(scratch);
    return 0;
}

static int hasPatchLibrary(const uint8_t *bytes, size_t size, const char *name,
                           char *error, size_t errorSize) {
    PatchSlice slices[64];
    uint32_t count;
    if (collectSlices(bytes, size, slices, &count, error, errorSize) < 0) return -1;
    int allPatched = 1, anyLegacy = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const uint8_t *slice = bytes + slices[i].offset;
        size_t sliceSize = slices[i].size;
        if (sliceSize < 28 || !thinMagic(read32(slice, 1)))
            return fail(error, errorSize, "Invalid Mach-O executable.");
        uint32_t magic = read32(slice, 1);
        int big = magic == 0xfeedface || magic == 0xfeedfacf;
        int wide = magic == 0xfeedfacf || magic == 0xcffaedfe;
        size_t header = wide ? 32 : 28, alignment = wide ? 8 : 4;
        if (sliceSize < header || read32(slice + 12, big) != 2)
            return fail(error, errorSize, "Bundle executable is not MH_EXECUTE.");
        uint32_t commands = read32(slice + 16, big), length = read32(slice + 20, big);
        if (length > sliceSize - header || length > 4 * 1024 * 1024 || commands > length / 8)
            return fail(error, errorSize, "Invalid Mach-O load command table.");
        size_t cursor = header, end = header + length;
        int found = 0;
        for (uint32_t j = 0; j < commands; ++j) {
            if (end - cursor < 8) return fail(error, errorSize, "Truncated Mach-O load command.");
            const uint8_t *command = slice + cursor;
            uint32_t kind = read32(command, big), commandSize = read32(command + 4, big);
            if (commandSize < 8 || commandSize > end - cursor || commandSize % alignment)
                return fail(error, errorSize, "Invalid Mach-O load command size.");
            if (kind == 0xc || kind == 0x80000018) { // LC_LOAD[_WEAK]_DYLIB
                if (commandSize < 24) return fail(error, errorSize, "Invalid dylib load command.");
                uint32_t offset = read32(command + 8, big);
                if (offset < 24 || offset >= commandSize ||
                    !memchr(command + offset, 0, commandSize - offset))
                    return fail(error, errorSize, "Invalid dylib load path.");
                const char *loaded = basenameOf((const char *)command + offset);
                if (name ? !strcmp(loaded, name) : legacyPatchName(loaded)) found = 1;
            }
            cursor += commandSize;
        }
        if (cursor != end) return fail(error, errorSize, "Invalid Mach-O load command table.");
        allPatched &= found;
        anyLegacy |= found;
    }
    return name ? allPatched : anyLegacy;
}

static int inspectPatchFile(const char *file, const char *name,
                               char *error, size_t errorSize) {
    if (error && errorSize) error[0] = 0;
    if (!file || (name && (!*name || strchr(name, '/'))))
        return fail(error, errorSize, "Invalid IPA patch detection input.");
    int descriptor = open(file, O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) return fail(error, errorSize, "Cannot open the executable for patch detection.");
    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0 || !S_ISREG(attributes.st_mode) ||
        attributes.st_size < 4 || (uint64_t)attributes.st_size > SIZE_MAX) {
        close(descriptor);
        return fail(error, errorSize, "Invalid executable for patch detection.");
    }
    size_t size = (size_t)attributes.st_size;
    void *bytes = mmap(NULL, size, PROT_READ, MAP_PRIVATE, descriptor, 0);
    if (bytes == MAP_FAILED) {
        close(descriptor);
        return fail(error, errorSize, "Cannot map the executable for patch detection.");
    }
    int result = hasPatchLibrary(bytes, size, name, error, errorSize);
    if (munmap(bytes, size) != 0 && result >= 0)
        result = fail(error, errorSize, "Cannot unmap the executable after patch detection.");
    if (close(descriptor) != 0 && result >= 0)
        result = fail(error, errorSize, "Cannot close the executable after patch detection.");
    return result;
}

int KsignIPAFileHasPatchLibrary(const char *file, const char *name,
                               char *error, size_t errorSize) {
    if (!name) return fail(error, errorSize, "Invalid IPA patch detection input.");
    return inspectPatchFile(file, name, error, errorSize);
}

int KsignIPAFileHasLegacyPatchLibrary(const char *file, char *error, size_t errorSize) {
    return inspectPatchFile(file, NULL, error, errorSize);
}

int KsignPatchIPAFile(const char *file, const char *path,
                     KsignIPARunpathResolver resolver, void *context,
                     char *error, size_t errorSize) {
    if (error && errorSize) error[0] = 0;
    int descriptor = open(file, O_RDWR | O_NOFOLLOW);
    if (descriptor < 0) return fail(error, errorSize, "Cannot open the staged executable for patching.");
    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0 || !S_ISREG(attributes.st_mode) ||
        attributes.st_size < 4 || (uint64_t)attributes.st_size > SIZE_MAX) {
        close(descriptor);
        return fail(error, errorSize, "Invalid staged executable.");
    }
    size_t size = (size_t)attributes.st_size;
    void *bytes = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    if (bytes == MAP_FAILED) {
        close(descriptor);
        return fail(error, errorSize, "Cannot map the staged executable.");
    }
    int result = KsignPatchIPALoadCommands(bytes, size, path, resolver, context, error, errorSize);
    if (result == 0 && msync(bytes, size, MS_SYNC) != 0)
        result = fail(error, errorSize, "Cannot save the patched executable.");
    if (munmap(bytes, size) != 0 && result == 0)
        result = fail(error, errorSize, "Cannot unmap the patched executable.");
    if (close(descriptor) != 0 && result == 0)
        result = fail(error, errorSize, "Cannot close the patched executable.");
    return result;
}
