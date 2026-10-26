#pragma once
#include <string.h>

// Qualifiers and quoted object class names do not change the calling ABI.
// Blocks, pointers, structures and integer widths must remain distinguishable.
static inline int AsignTypeMatches(const char *actual, const char *expected) {
    if (!actual || !expected) return 0;
    while (*actual && strchr("rnNoORV", *actual)) ++actual;
    while (*expected && strchr("rnNoORV", *expected)) ++expected;
    if (!strcmp(expected, "@") && actual[0] == '@' && actual[1] == '"') {
        const char *end = strchr(actual + 2, '"');
        return end && end[1] == '\0';
    }
    return *actual && !strcmp(actual, expected);
}
