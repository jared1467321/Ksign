#ifndef KSIGN_IPA_PATCH_H
#define KSIGN_IPA_PATCH_H

#include <stddef.h>

// Edits only load commands. All slices, code, and existing signature blobs
// (including entitlements) survive for the normal signing stage. Validates
// every slice before writing; returns -1 with an error on failure.
int KsignPatchIPALoadCommands(void *bytes, size_t size, const char *loadPath,
                             char *error, size_t errorSize);

// Operates only on a staged private copy. Maps the file so large executables
// need no full-size Data allocation or rewrite just to edit their header.
int KsignPatchIPAFile(const char *file, const char *loadPath, char *error, size_t errorSize);

#endif
