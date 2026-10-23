#include "IPAPatch.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
int KsignPatchIPAFileWithGrowth(const char* file, const char* path,
                               KsignIPARunpathResolver resolver, void* context,
                               char* error, size_t errorSize) {
    return KsignPatchIPAFile(file, path, resolver, context, error, errorSize);
}
#else
#include <LIEF/MachO.hpp>
#include <LIEF/logging.hpp>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
struct Error : std::runtime_error { using std::runtime_error::runtime_error; };

uint64_t read(const Bytes& b, size_t at, size_t width, bool big) {
    if (at > b.size() || width > b.size() - at) throw Error("Truncated header-growth input.");
    uint64_t value = 0;
    for (size_t i = 0; i < width; ++i) value |= uint64_t(b[at + i]) << ((big ? width - i - 1 : i) * 8);
    return value;
}

void write(Bytes& b, size_t at, uint64_t value, size_t width, bool big) {
    if (at > b.size() || width > b.size() - at || (width == 4 && value > UINT32_MAX))
        throw Error("Header-growth offset is out of range.");
    for (size_t i = 0; i < width; ++i) b[at + i] = uint8_t(value >> ((big ? width - i - 1 : i) * 8));
}

size_t aligned(size_t value, size_t alignment) {
    if (value > SIZE_MAX - alignment + 1) throw Error("Header-growth size overflow.");
    return (value + alignment - 1) & ~(alignment - 1);
}

struct Image {
    const Bytes& bytes;
    bool big, wide;
    size_t header, end;
    explicit Image(const Bytes& b) : bytes(b) {
        const uint32_t magic = uint32_t(read(b, 0, 4, true));
        big = magic == 0xfeedfacf || magic == 0xfeedface;
        wide = magic == 0xfeedfacf || magic == 0xcffaedfe;
        header = wide ? 32 : 28;
        end = header + read(b, 20, 4, big);
        if (end > b.size()) throw Error("Invalid expanded command table.");
    }
    size_t command(uint32_t kind) const {
        for (size_t cursor = header; cursor < end;) {
            const size_t length = read(bytes, cursor + 4, 4, big);
            if (length < 8 || length > end - cursor) throw Error("Invalid expanded load command.");
            if (read(bytes, cursor, 4, big) == kind) return cursor;
            cursor += length;
        }
        return 0;
    }
};

struct Section {
    std::string name;
    size_t offset, size;
    uint64_t address;
    uint32_t flags;
};

std::vector<Section> sections(const Bytes& bytes) {
    const Image image(bytes);
    std::vector<Section> result;
    for (size_t cursor = image.header; cursor < image.end;) {
        uint32_t kind = uint32_t(read(bytes, cursor, 4, image.big));
        size_t length = read(bytes, cursor + 4, 4, image.big);
        if (length < 8 || length > image.end - cursor) throw Error("Invalid segment while expanding header.");
        if (kind == 1 || kind == 0x19) {
            bool wide = kind == 0x19;
            size_t base = wide ? 72 : 56, entry = wide ? 80 : 68;
            size_t count = read(bytes, cursor + (wide ? 64 : 48), 4, image.big);
            if (length < base || count > (length - base) / entry) throw Error("Invalid expanded sections.");
            for (size_t i = 0; i < count; ++i) {
                size_t s = cursor + base + i * entry;
                result.push_back({std::string(reinterpret_cast<const char*>(bytes.data() + s),
                    strnlen(reinterpret_cast<const char*>(bytes.data() + s), 16)),
                    size_t(read(bytes, s + (wide ? 48 : 40), 4, image.big)),
                    size_t(read(bytes, s + (wide ? 40 : 36), wide ? 8 : 4, image.big)),
                    read(bytes, s + 32, wide ? 8 : 4, image.big),
                    uint32_t(read(bytes, s + (wide ? 64 : 56), 4, image.big))});
            }
        }
        cursor += length;
    }
    return result;
}

void restoreSignature(Bytes& output, const Bytes& signature) {
    Image image(output);
    size_t code = image.end;
    if (code > output.size() || 16 > output.size() - code) throw Error("No room to retain the original entitlements.");
    size_t start = aligned(output.size(), 16);
    output.resize(start, 0);
    output.insert(output.end(), signature.begin(), signature.end());
    write(output, code, 0x1d, 4, image.big);
    write(output, code + 4, 16, 4, image.big);
    write(output, code + 8, start, 4, image.big);
    write(output, code + 12, signature.size(), 4, image.big);
    write(output, 16, read(output, 16, 4, image.big) + 1, 4, image.big);
    write(output, 20, read(output, 20, 4, image.big) + 16, 4, image.big);
    bool found = false;
    for (size_t cursor = image.header; cursor < image.end; cursor += read(output, cursor + 4, 4, image.big)) {
        uint32_t kind = uint32_t(read(output, cursor, 4, image.big));
        if ((kind != 1 && kind != 0x19) || std::memcmp(output.data() + cursor + 8, "__LINKEDIT", 10)) continue;
        bool wide = kind == 0x19;
        size_t offset = read(output, cursor + (wide ? 40 : 32), wide ? 8 : 4, image.big);
        if (offset > output.size()) throw Error("Invalid expanded LINKEDIT offset.");
        size_t size = output.size() - offset;
        write(output, cursor + (wide ? 48 : 36), size, wide ? 8 : 4, image.big);
        uint64_t previous = read(output, cursor + (wide ? 32 : 28), wide ? 8 : 4, image.big);
        write(output, cursor + (wide ? 32 : 28), std::max<uint64_t>(previous, aligned(size, 0x4000)), wide ? 8 : 4, image.big);
        found = true;
    }
    if (!found) throw Error("No LINKEDIT segment to retain original entitlements.");
}

int64_t signedValue(uint64_t value, unsigned bits) {
    return int64_t((value ^ (UINT64_C(1) << (bits - 1))) - (UINT64_C(1) << (bits - 1)));
}

uint32_t addressInstruction(uint32_t instruction, int64_t immediate) {
    if (immediate < -(INT64_C(1) << 20) || immediate >= (INT64_C(1) << 20))
        throw Error("ARM64 header reference cannot be relocated.");
    uint32_t encoded = uint32_t(immediate) & 0x1fffff;
    return (instruction & ~0x60ffffe0u) | ((encoded & 3) << 29) | ((encoded >> 2) << 5);
}

std::vector<std::pair<size_t, size_t>> dataInCode(const Bytes& original) {
    const Image image(original);
    size_t command = image.command(0x29);
    if (!command) return {};
    size_t offset = read(original, command + 8, 4, image.big), size = read(original, command + 12, 4, image.big);
    if (offset > original.size() || size > original.size() - offset || size % 8)
        throw Error("Invalid data-in-code records during header growth.");
    std::vector<std::pair<size_t, size_t>> ranges;
    for (size_t i = offset; i < offset + size; i += 8) {
        size_t start = read(original, i, 4, image.big), length = read(original, i + 4, 2, image.big);
        if (start > original.size() || length > original.size() - start) throw Error("Invalid data-in-code range.");
        ranges.emplace_back(start, start + length);
    }
    std::sort(ranges.begin(), ranges.end());
    std::vector<std::pair<size_t, size_t>> merged;
    for (auto range : ranges) {
        if (!merged.empty() && range.first <= merged.back().second) merged.back().second = std::max(merged.back().second, range.second);
        else merged.push_back(range);
    }
    return merged;
}

// LIEF moves code/data together. References to the Mach header itself stay at
// the image base, however, so repair those ARM64 address calculations too.
void repairHeaderReferences(const Bytes& original, Bytes& output, uint64_t base, size_t pivot, size_t shift) {
    const Image image(original);
    auto oldSections = sections(original), newSections = sections(output);
    const auto literals = dataInCode(original);
    if (oldSections.size() != newSections.size()) throw Error("Expanded section count changed.");
    auto inHeader = [&](uint64_t address) { return address >= base && address < base + pivot; };
    for (size_t s = 0; s < oldSections.size(); ++s) {
        const auto& old = oldSections[s];
        const auto& next = newSections[s];
        if (old.name != next.name) throw Error("Expanded section order changed.");
        if (!(old.flags & 0x80000400u) || !old.size) continue;
        if (old.offset > original.size() || old.size > original.size() - old.offset ||
            next.offset > output.size() || old.size > output.size() - next.offset)
            throw Error("Code section extends past the expanded executable.");
        size_t literal = 0;
        for (size_t i = 0; i + 4 <= old.size; i += 4) {
            while (literal < literals.size() && literals[literal].second <= old.offset + i) ++literal;
            if (literal < literals.size() && literals[literal].first < old.offset + i + 4) continue;
            uint32_t word = uint32_t(read(original, old.offset + i, 4, image.big));
            uint64_t pc = old.address + i;
            uint32_t kind = word & 0x9f000000u;
            if (kind == 0x10000000u || kind == 0x90000000u) { // ADR / ADRP
                int64_t immediate = signedValue(((word >> 5) & 0x7ffff) << 2 | ((word >> 29) & 3), 21);
                if (kind == 0x10000000u) {
                    if (inHeader(pc + immediate)) write(output, next.offset + i, addressInstruction(word, immediate - int64_t(shift)), 4, image.big);
                    continue;
                }
                uint64_t page = (pc & ~UINT64_C(0xfff)) + immediate * 4096;
                if (page < base || page >= base + pivot) continue;
                bool adjust = page + 4096 <= base + pivot;
                if (!adjust) {
                    if (i + 8 > old.size) throw Error("Unresolved ARM64 header page reference.");
                    uint32_t use = uint32_t(read(original, old.offset + i + 4, 4, image.big));
                    uint32_t reg = word & 31, source = (use >> 5) & 31, destination = use & 31;
                    if ((use & 0x7f000000u) == 0x11000000u && source == reg) { // ADD immediate
                        uint64_t target = page + (((use >> 10) & 0xfff) << ((use & (1u << 22)) ? 12 : 0));
                        if (!inHeader(target)) continue;
                        if (destination == reg) adjust = true;
                        else if (target == page && shift / 4096 <= 0xfff) {
                            // Keep the shared page register for other data users.
                            uint32_t subtract = (use & ~0x007ffc00u) | 0x40400000u | uint32_t(shift / 4096) << 10;
                            write(output, next.offset + i + 4, subtract, 4, image.big);
                            continue;
                        } else throw Error("Unsupported ARM64 header address calculation.");
                    } else if ((use & 0x3b000000u) == 0x39000000u && source == reg) { // LDR/STR unsigned
                        uint64_t target = page + (((use >> 10) & 0xfff) << (use >> 30));
                        if (!inHeader(target)) continue;
                        if (destination == reg && (use & (1u << 22)) && !(use & (1u << 26))) adjust = true;
                        else throw Error("Unsupported ARM64 header load calculation.");
                    } else throw Error("Unsupported ARM64 header page calculation.");
                }
                if (adjust) write(output, next.offset + i, addressInstruction(word, immediate - int64_t(shift / 4096)), 4, image.big);
            } else if ((word & 0x3b000000u) == 0x18000000u) { // LDR literal
                int64_t immediate = signedValue((word >> 5) & 0x7ffff, 19);
                if (!inHeader(pc + immediate * 4)) continue;
                immediate -= int64_t(shift / 4);
                if (immediate < -(INT64_C(1) << 18) || immediate >= (INT64_C(1) << 18))
                    throw Error("ARM64 literal header reference is out of range.");
                write(output, next.offset + i, (word & ~0x00ffffe0u) | (uint32_t(immediate) & 0x7ffff) << 5, 4, image.big);
            }
        }
    }
}

// Compact unwind tables contain image-relative function and LSDA addresses,
// in addition to section-relative indexes that must remain unchanged.
void repairUnwind(const Bytes& original, Bytes& output, uint64_t base, size_t pivot, size_t shift) {
    const Image image(original);
    auto before = sections(original), after = sections(output);
    for (size_t s = 0; s < before.size(); ++s) {
        const auto& old = before[s];
        if ((old.name != "__unwind_info" && old.name != "__compact_unwind") || !old.size) continue;
        const auto& next = after.at(s);
        if (old.size != next.size || old.offset > original.size() || old.size > original.size() - old.offset ||
            next.offset > output.size() || next.size > output.size() - next.offset)
            throw Error("Invalid compact unwind section during header growth.");
        Bytes table(original.begin() + old.offset, original.begin() + old.offset + old.size);
        if (old.name == "__compact_unwind") {
            size_t width = image.wide ? 8 : 4, entry = image.wide ? 32 : 20;
            if (table.size() % entry) throw Error("Invalid compact unwind entries.");
            for (size_t i = 0; i < table.size(); i += entry) {
                for (size_t field : {size_t(0), width + 8, width * 2 + 8}) {
                    uint64_t value = read(table, i + field, width, image.big);
                    if (value >= base + pivot) write(table, i + field, value + shift, width, image.big);
                }
            }
            std::copy(table.begin(), table.end(), output.begin() + next.offset);
            continue;
        }
        auto field = [&](size_t at) { return size_t(read(table, at, 4, image.big)); };
        auto array = [&](size_t at, size_t count, size_t entry) {
            if (at > table.size() || count > (table.size() - at) / entry) throw Error("Invalid compact unwind index.");
        };
        auto relocate = [&](size_t at) {
            uint64_t value = read(table, at, 4, image.big);
            if (value >= pivot) write(table, at, value + shift, 4, image.big);
        };
        if (field(0) != 1 || table.size() < 28) throw Error("Unsupported compact unwind version.");
        size_t personality = field(12), personalities = field(16), index = field(20), count = field(24);
        array(personality, personalities, 4); array(index, count, 12);
        for (size_t p = 0; p < personalities; ++p) relocate(personality + p * 4);
        for (size_t i = 0; i < count; ++i) {
            size_t row = index + i * 12;
            relocate(row);
            if (i + 1 >= count) continue;
            size_t lsda = field(row + 8), lsdaEnd = field(row + 20);
            if (lsdaEnd < lsda || (lsdaEnd - lsda) % 8) throw Error("Invalid compact unwind LSDA range.");
            array(lsda, (lsdaEnd - lsda) / 8, 8);
            for (size_t p = lsda; p < lsdaEnd; p += 8) { relocate(p); relocate(p + 4); }
            size_t page = field(row + 4);
            if (!page) continue;
            uint32_t kind = uint32_t(field(page));
            size_t entries = read(table, page + 4, 2, image.big), entryCount = read(table, page + 6, 2, image.big);
            if (kind == 2) {
                array(page + entries, entryCount, 8);
                for (size_t p = 0; p < entryCount; ++p) relocate(page + entries + p * 8);
            } else if (kind != 3) throw Error("Unsupported compact unwind page type.");
        }
        std::copy(table.begin(), table.end(), output.begin() + next.offset);
    }
}

void repairDataInCode(const Bytes& original, Bytes& output, size_t pivot, size_t shift) {
    const Image before(original), after(output);
    size_t oldCommand = before.command(0x29), newCommand = after.command(0x29);
    if (!oldCommand) return;
    if (!newCommand) throw Error("Data-in-code command was lost during header growth.");
    size_t source = read(original, oldCommand + 8, 4, before.big), size = read(original, oldCommand + 12, 4, before.big);
    size_t destination = read(output, newCommand + 8, 4, after.big);
    if (size % 8 || source > original.size() || size > original.size() - source ||
        destination > output.size() || size > output.size() - destination)
        throw Error("Invalid expanded data-in-code metadata.");
    for (size_t i = 0; i < size; i += 8) {
        uint64_t value = read(original, source + i, 4, before.big);
        write(output, destination + i, value >= pivot ? value + shift : value, 4, after.big);
    }
}

Bytes growSlice(const Bytes& input) {
    const Image image(input);
    if (!image.wide || image.big || read(input, 4, 4, image.big) != 0x0100000c)
        throw Error("Header growth is supported for ARM64 iOS executables; all slices were retained.");
    auto parsed = LIEF::MachO::Parser::parse(input);
    if (!parsed || parsed->size() != 1) throw Error("Cannot parse the executable for header growth.");
    auto& binary = *parsed->at(0);
    auto* text = binary.get_segment("__TEXT");
    if (!text || text->file_offset() != 0) throw Error("No executable TEXT header segment.");
    uint64_t base = text->virtual_address();
    size_t shift = 0x4000;
    for (const auto& section : binary.sections()) {
        if (section.alignment() > 20) throw Error("Section alignment exceeds the header-growth limit.");
        shift = std::max(shift, size_t(1) << section.alignment());
    }
    size_t signatureCommand = image.command(0x1d);
    Bytes signature;
    std::unique_ptr<LIEF::MachO::LoadCommand> savedUUID;
    if (signatureCommand) {
        size_t offset = read(input, signatureCommand + 8, 4, image.big);
        size_t size = read(input, signatureCommand + 12, 4, image.big);
        if (offset > input.size() || size > input.size() - offset) throw Error("Invalid original entitlement signature.");
        signature.assign(input.begin() + offset, input.begin() + offset + size);
        if (!binary.remove_signature()) throw Error("Cannot preserve the original signature for rebuilding.");
    } else {
        // Keep the insertion boundary strictly before section data, including
        // unsigned executables whose first instruction touches the old table.
        auto* uuid = binary.uuid();
        if (!uuid) throw Error("Unsigned header growth requires a UUID command.");
        savedUUID = uuid->clone();
        if (!binary.remove(*uuid)) throw Error("Cannot prepare unsigned header growth.");
    }
    if (LIEF::is_err(binary.shift(shift))) throw Error("Cannot expand the executable's load-command space.");
    if (savedUUID && !binary.add(std::move(savedUUID))) throw Error("Cannot restore the executable UUID.");
    Bytes output;
    if (LIEF::is_err(LIEF::MachO::Builder::write(binary, output))) throw Error("Cannot rebuild the expanded executable.");
    // The signature contents are retained verbatim, then replaced by the normal
    // signer. No intermediate ad hoc signing or entitlement replacement occurs.
    if (signatureCommand) restoreSignature(output, signature);
    repairHeaderReferences(input, output, base, image.end, shift);
    repairUnwind(input, output, base, image.end, shift);
    repairDataInCode(input, output, image.end, shift);
    if (output.size() < 16 || !std::equal(input.begin() + 4, input.begin() + 16, output.begin() + 4))
        throw Error("Header growth changed the executable architecture.");
    return output;
}

Bytes rebuild(const Bytes& input, const char* path, KsignIPARunpathResolver resolver, void* context) {
    uint32_t magic = uint32_t(read(input, 0, 4, true));
    bool fat = magic == 0xcafebabe || magic == 0xbebafeca || magic == 0xcafebabf || magic == 0xbfbafeca;
    bool wide = magic == 0xcafebabf || magic == 0xbfbafeca;
    bool big = magic == 0xcafebabe || magic == 0xcafebabf;
    size_t count = fat ? read(input, 4, 4, big) : 1, entry = wide ? 32 : 20;
    if (!count || count > 64) throw Error("Invalid header-growth architecture count.");
    std::vector<Bytes> slices;
    std::vector<size_t> alignments;
    char error[512];
    for (size_t i = 0; i < count; ++i) {
        size_t row = 8 + i * entry;
        size_t offset = fat ? read(input, row + 8, wide ? 8 : 4, big) : 0;
        size_t size = fat ? read(input, row + (wide ? 16 : 12), wide ? 8 : 4, big) : input.size();
        size_t alignment = fat ? read(input, row + (wide ? 24 : 16), 4, big) : 0;
        if (offset > input.size() || size > input.size() - offset || alignment > 30) throw Error("Invalid header-growth slice range.");
        Bytes original(input.begin() + offset, input.begin() + offset + size), patched = original;
        int result = KsignPatchIPALoadCommands(patched.data(), patched.size(), path, resolver, context, error, sizeof(error));
        if (result == KSIGN_IPA_HEADER_SPACE) {
            patched = growSlice(original);
            result = KsignPatchIPALoadCommands(patched.data(), patched.size(), path, resolver, context, error, sizeof(error));
        }
        if (result < 0) throw Error(error);
        slices.push_back(std::move(patched));
        alignments.push_back(std::max<size_t>(alignment, 14));
    }
    if (!fat) return std::move(slices[0]);
    Bytes output(input.begin(), input.begin() + 8 + count * entry);
    for (size_t i = 0; i < count; ++i) {
        size_t offset = aligned(output.size(), size_t(1) << alignments[i]);
        output.resize(offset, 0);
        output.insert(output.end(), slices[i].begin(), slices[i].end());
        size_t row = 8 + i * entry;
        write(output, row + 8, offset, wide ? 8 : 4, big);
        write(output, row + (wide ? 16 : 12), slices[i].size(), wide ? 8 : 4, big);
        write(output, row + (wide ? 24 : 16), alignments[i], 4, big);
    }
    return output;
}

Bytes readFile(const char* file, mode_t& mode) {
    int fd = open(file, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) throw Error("Cannot read the staged executable for header growth.");
    struct Close { int fd; ~Close() { close(fd); } } closeOnExit{fd};
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 4 || uint64_t(info.st_size) > SIZE_MAX)
        throw Error("Invalid staged header-growth file.");
    mode = info.st_mode & 0777;
    Bytes bytes(size_t(info.st_size));
    size_t offset = 0;
    while (offset < bytes.size()) {
        ssize_t amount = ::read(fd, bytes.data() + offset, bytes.size() - offset);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) throw Error("Cannot read complete header-growth input.");
        offset += size_t(amount);
    }
    return bytes;
}

void replaceFile(const char* file, const Bytes& bytes, mode_t mode) {
    std::string pattern = std::string(file) + ".growth.XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back(0);
    int fd = mkstemp(name.data());
    if (fd < 0) throw Error("Cannot stage the expanded executable.");
    struct Cleanup { int fd; const char* path; ~Cleanup() { if (fd >= 0) close(fd); unlink(path); } } cleanup{fd, name.data()};
    if (fchmod(fd, mode)) throw Error("Cannot preserve expanded executable permissions.");
    size_t offset = 0;
    while (offset < bytes.size()) {
        ssize_t amount = ::write(fd, bytes.data() + offset, bytes.size() - offset);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) throw Error("Cannot save the expanded executable.");
        offset += size_t(amount);
    }
    if (close(fd)) { cleanup.fd = -1; throw Error("Cannot finish the expanded executable."); }
    cleanup.fd = -1;
    if (rename(name.data(), file)) throw Error("Cannot install the expanded staged executable.");
}
} // namespace

int KsignPatchIPAFileWithGrowth(const char* file, const char* path,
                               KsignIPARunpathResolver resolver, void* context,
                               char* error, size_t errorSize) {
    int result = KsignPatchIPAFile(file, path, resolver, context, error, errorSize);
    if (result != KSIGN_IPA_HEADER_SPACE) return result;
    // Full rebuilds use more memory than header-only edits. Keep one active
    // across concurrent batches, and do not expose LIEF's success logs to users.
    static std::mutex growthMutex;
    std::lock_guard<std::mutex> lock(growthMutex);
    LIEF::logging::disable();
    try {
        mode_t mode;
        Bytes input = readFile(file, mode);
        Bytes output = rebuild(input, path, resolver, context);
        replaceFile(file, output, mode);
        if (error && errorSize) error[0] = 0;
        return 0;
    } catch (const std::exception& failure) {
        if (error && errorSize) std::snprintf(error, errorSize, "%s", failure.what());
        return -1;
    } catch (...) {
        if (error && errorSize) std::snprintf(error, errorSize, "Unexpected executable header-growth failure.");
        return -1;
    }
}
#endif
