#ifndef KSIGN_PLATFORM_COMPATIBILITY_H
#define KSIGN_PLATFORM_COMPATIBILITY_H

#include <stddef.h>
#include <stdint.h>

int KsignHasMachOMagic(const void *bytes, size_t size);

// Called only for a private signing copy whose root plist failed the platform
// preflight. Validate every slice before writing. CPU types, code and layout
// stay intact. Excessive minimum versions are lowered on embedded iOS slices
// too. Returns changed slices, zero for no change, or -1 with an error.
int KsignPatchPlatformMetadata(void *bytes, size_t size, uint32_t minimumOS,
                               uint32_t sdk, char *error, size_t errorSize);

#endif
