#include "PlatformCompatibility.h"
#include <stdio.h>

typedef struct { size_t offset, size; } Slice;

static uint32_t read32(const uint8_t *p, int big) {
    uint32_t value = 0;
    for (int i = 0; i < 4; ++i) value |= (uint32_t)p[i] << ((big ? 3 - i : i) * 8);
    return value;
}

static uint64_t read64(const uint8_t *p, int big) {
    uint64_t value = 0;
    for (int i = 0; i < 8; ++i) value |= (uint64_t)p[i] << ((big ? 7 - i : i) * 8);
    return value;
}

static void write32(uint8_t *p, uint32_t value, int big) {
    for (int i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> ((big ? 3 - i : i) * 8));
}

static int thinMagic(uint32_t magic) {
    return magic == 0xfeedface || magic == 0xfeedfacf || magic == 0xcefaedfe || magic == 0xcffaedfe;
}

static int fatMagic(uint32_t magic) {
    return magic == 0xcafebabe || magic == 0xcafebabf || magic == 0xbebafeca || magic == 0xbfbafeca;
}

int KsignHasMachOMagic(const void *bytes, size_t size) {
    if (size < 4) return 0;
    uint32_t magic = read32(bytes, 1);
    return thinMagic(magic) || fatMagic(magic);
}

static int fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
    return -1;
}

static int patchSlice(uint8_t *bytes, size_t size, uint32_t minimumOS, uint32_t sdk,
                      int apply, char *error, size_t errorSize) {
    if (size < 28) return fail(error, errorSize, "Truncated Mach-O header.");
    uint32_t magic = read32(bytes, 1);
    if (!thinMagic(magic)) return fail(error, errorSize, "Invalid Mach-O slice.");
    int big = magic == 0xfeedface || magic == 0xfeedfacf;
    int wide = magic == 0xfeedfacf || magic == 0xcffaedfe;
    size_t headerSize = wide ? 32 : 28;
    if (size < headerSize) return fail(error, errorSize, "Truncated Mach-O header.");
    uint32_t count = read32(bytes + 16, big), commandBytes = read32(bytes + 20, big);
    if (commandBytes > size - headerSize || commandBytes > 4 * 1024 * 1024 ||
        count > commandBytes / 8 || count > 65536)
        return fail(error, errorSize, "Invalid Mach-O load command table.");

    size_t cursor = headerSize, end = headerSize + commandBytes;
    unsigned platforms = 0;
    int changed = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (end - cursor < 8) return fail(error, errorSize, "Truncated Mach-O load command.");
        uint8_t *command = bytes + cursor;
        uint32_t kind = read32(command, big), length = read32(command + 4, big);
        if (length < 8 || length > end - cursor || length % (wide ? 8 : 4))
            return fail(error, errorSize, "Invalid Mach-O load command size.");

        if (kind == 0x32) { // LC_BUILD_VERSION
            if (length < 24 || read32(command + 20, big) > (length - 24) / 8)
                return fail(error, errorSize, "Invalid LC_BUILD_VERSION.");
            ++platforms;
            uint32_t platform = read32(command + 8, big);
            // Known device/simulator platforms, including visionOS (11/12).
            // Unknown future platforms must not be silently relabeled.
            if (platform == 0 || platform > 12)
                return fail(error, errorSize, "Unsupported Mach-O platform identifier.");
            if (platform != 2) {
                changed = 1;
                if (apply) {
                    write32(command + 8, 2, big); // PLATFORM_IOS
                    write32(command + 12, minimumOS, big);
                    write32(command + 16, sdk, big);
                }
            } else if (read32(command + 12, big) > minimumOS) {
                // A foreign app may embed an iOS framework with a higher floor.
                // This parser only runs inside an activated compatibility shim.
                changed = 1;
                if (apply) write32(command + 12, minimumOS, big);
            }
        } else if (kind == 0x24 || kind == 0x25 || kind == 0x2f || kind == 0x30) {
            // The legacy version-min commands have the same 16-byte layout.
            if (length != 16) return fail(error, errorSize, "Invalid version-min command.");
            ++platforms;
            if (kind != 0x25) {
                changed = 1;
                if (apply) {
                    write32(command, 0x25, big); // LC_VERSION_MIN_IPHONEOS
                    write32(command + 8, minimumOS, big);
                    write32(command + 12, sdk, big);
                }
            } else if (read32(command + 8, big) > minimumOS) {
                changed = 1;
                if (apply) write32(command + 8, minimumOS, big);
            }
        } else if (kind == 0x21 || kind == 0x2c) { // LC_ENCRYPTION_INFO[_64]
            if (length < (kind == 0x2c ? 24u : 20u))
                return fail(error, errorSize, "Invalid Mach-O encryption command.");
            if (read32(command + 16, big) != 0)
                return fail(error, errorSize, "Encrypted executables cannot be converted by a platform metadata shim.");
        }
        cursor += length;
    }
    if (cursor != end || platforms > 1)
        return fail(error, errorSize, "Ambiguous Mach-O platform or load command table.");
    return changed;
}

int KsignPatchPlatformMetadata(void *buffer, size_t size, uint32_t minimumOS,
                               uint32_t sdk, char *error, size_t errorSize) {
    if (error && errorSize) error[0] = '\0';
    if (!KsignHasMachOMagic(buffer, size)) return 0;
    if (!minimumOS || sdk < minimumOS) return fail(error, errorSize, "Invalid target iOS version.");
    uint8_t *bytes = buffer;
    uint32_t magic = read32(bytes, 1);
    Slice slices[64] = {{0, size}};
    uint32_t count = 1;
    if (fatMagic(magic)) {
        if (size < 8) return fail(error, errorSize, "Truncated universal Mach-O header.");
        int big = magic == 0xcafebabe || magic == 0xcafebabf;
        int wide = magic == 0xcafebabf || magic == 0xbfbafeca;
        size_t entrySize = wide ? 32 : 20;
        count = read32(bytes + 4, big);
        if (!count || count > 64 || count > (size - 8) / entrySize)
            return fail(error, errorSize, "Invalid universal Mach-O slice table.");
        size_t tableEnd = 8 + count * entrySize;
        for (uint32_t i = 0; i < count; ++i) {
            const uint8_t *entry = bytes + 8 + i * entrySize;
            uint64_t offset = wide ? read64(entry + 8, big) : read32(entry + 8, big);
            uint64_t length = wide ? read64(entry + 16, big) : read32(entry + 12, big);
            uint32_t align = read32(entry + (wide ? 24 : 16), big);
            if (offset < tableEnd || offset > size || !length || length > size - offset ||
                align > 63 || (offset & ((UINT64_C(1) << align) - 1)))
                return fail(error, errorSize, "Invalid universal Mach-O slice range.");
            slices[i] = (Slice){(size_t)offset, (size_t)length};
            for (uint32_t j = 0; j < i; ++j) {
                if (offset < slices[j].offset + slices[j].size && slices[j].offset < offset + length)
                    return fail(error, errorSize, "Overlapping universal Mach-O slices.");
            }
            if (length < 12 || !thinMagic(read32(bytes + offset, 1)))
                return fail(error, errorSize, "Invalid universal Mach-O slice header.");
            int sliceBig = read32(bytes + offset, 1) == 0xfeedface || read32(bytes + offset, 1) == 0xfeedfacf;
            if (read32(entry, big) != read32(bytes + offset + 4, sliceBig) ||
                ((read32(entry + 4, big) ^ read32(bytes + offset + 8, sliceBig)) & 0x00ffffffu))
                return fail(error, errorSize, "Universal Mach-O architecture table does not match its slice.");
        }
    }

    // No file bytes change if any slice or command is malformed/encrypted.
    int changed = 0;
    for (uint32_t i = 0; i < count; ++i) {
        int result = patchSlice(bytes + slices[i].offset, slices[i].size, minimumOS, sdk, 0, error, errorSize);
        if (result < 0) return -1;
        changed += result;
    }
    if (changed) {
        for (uint32_t i = 0; i < count; ++i)
            patchSlice(bytes + slices[i].offset, slices[i].size, minimumOS, sdk, 1, error, errorSize);
    }
    return changed;
}
