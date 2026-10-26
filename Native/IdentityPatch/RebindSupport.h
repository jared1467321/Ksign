#pragma once
#include <stdint.h>
#include <string.h>

static inline int AsignRangeWithin(uint64_t offset, uint64_t size, uint64_t start, uint64_t length) {
    return offset >= start && offset - start <= length && size <= length - (offset - start);
}

static inline int AsignImportNeedsReplacement(const char *symbol, const char *wanted,
                                              const void *current, const void *original,
                                              const void *replacement, int unresolvedLazy) {
    if (!current || !original || !replacement || current == replacement) return 0;
    // A known symbol name takes precedence over an aliased function address.
    // Preserve another library's hook. Only an actual lazy stub may differ
    // from the original API before our first replacement.
    if (symbol) return !strcmp(symbol, wanted) && (current == original || unresolvedLazy);
    return current == original;
}
