#ifndef ASIGN_DYLD_PATCH_MATCH_H
#define ASIGN_DYLD_PATCH_MATCH_H
#include <stddef.h>
#include <stdint.h>

// ARM64 words beginning four instructions before the task_info return address.
// A match identifies the optional Unreal module-tracing initializer, including
// its checked error exit. Addresses and callee-saved register allocation vary.
// The runtime must also verify the two referenced diagnostic strings.
int AsignMatchUnsafeModuleTrace(const uint32_t *words, size_t count,
                               uint64_t address, uint64_t *program, uint64_t *linkedit);
#endif
