#ifndef KSIGN_IPA_PATCH_H
#define KSIGN_IPA_PATCH_H

#include <stddef.h>

// Resolve LC_RPATH in the original executable's location, rather than its
// staging directory. Return 1 for the installed patch library, 0 for a known
// absent candidate, or -1 for a shadowing/unverifiable candidate. The first
// nonzero result wins. NULL retains the explicit executable-relative path.
typedef int (*KsignIPARunpathResolver)(const char *runpath, void *context);

// Edits only load commands. All slices, code, and existing signature blobs
// (including entitlements) survive for the normal signing stage. Validates
// every slice before writing; returns -1 with an error on failure.
int KsignPatchIPALoadCommands(void *bytes, size_t size, const char *loadPath,
                             KsignIPARunpathResolver resolver, void *context,
                             char *error, size_t errorSize);

// Operates only on a staged private copy. Maps the file so large executables
// need no full-size Data allocation or rewrite just to edit their header.
int KsignPatchIPAFile(const char *file, const char *loadPath,
                     KsignIPARunpathResolver resolver, void *context,
                     char *error, size_t errorSize);

#endif
