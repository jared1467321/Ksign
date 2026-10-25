#include "DyldPatch.h"
#include "DyldPatchMatch.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <string.h>

__attribute__((used, visibility("default")))
const char AsignDyldPatchVersion[] = "AsignDyldPatch/v1";

#if defined(__arm64__)
static int readMemory(uint64_t address, void *output, size_t size) {
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, size,
                                 (mach_vm_address_t)(uintptr_t)output, &copied) == KERN_SUCCESS && copied == size;
}

static int unsafeModuleTrace(uintptr_t caller) {
    // Inspect through Mach's checked read API. Never dereference arbitrary
    // caller bytes, or cache a classification across an image unload/reload.
    uint32_t words[384];
    uint64_t program, linkedit;
    int result = 0;
    if (caller >= 16 && !(caller & 3) &&
        readMemory(caller - 16, words, sizeof(words)) &&
        AsignMatchUnsafeModuleTrace(words, sizeof(words) / sizeof(words[0]), caller - 16, &program, &linkedit)) {
        static const uint16_t expectedProgram[] = {'P', 'r', 'o', 'g', 'r', 'a', 'm', 0};
        uint16_t programString[8];
        char linkeditString[11];
        result = readMemory(program, programString, sizeof(programString)) &&
            !memcmp(programString, expectedProgram, sizeof(programString)) &&
            readMemory(linkedit, linkeditString, sizeof(linkeditString)) &&
            !memcmp(linkeditString, "__LINKEDIT", sizeof(linkeditString));
    }
    return result;
}

static kern_return_t taskInfoForCaller(task_name_t task, task_flavor_t flavor,
                                      task_info_t info, mach_msg_type_number_t *count, uintptr_t caller) {
    // Our imports remain untouched by the rebinder. Preserve the actual API's
    // validation and errors, and never interfere with another task or flavor.
    kern_return_t status = task_info(task, flavor, info, count);
    if (status == KERN_SUCCESS && task == mach_task_self() && flavor == TASK_DYLD_INFO &&
        unsafeModuleTrace(caller)) {
        // This recognized optional tracer checks task_info's status and returns
        // normally on error. Skipping module diagnostics avoids its unchecked
        // traversal even if infoArray becomes NULL *after* task_info returns.
        // Do not return a frozen dyld structure, hide images, or catch SIGSEGV.
        return KERN_FAILURE;
    }
    return status;
}

static kern_return_t CompatibleTaskInfo(task_name_t task, task_flavor_t flavor,
                                       task_info_t info, mach_msg_type_number_t *count) {
    return taskInfoForCaller(task, flavor, info, count,
        (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0)));
}
#endif

AsignIdentityBinding AsignDyldTaskInfoBinding(void) {
#if defined(__arm64__)
    return (AsignIdentityBinding){"task_info", (void *)task_info, (void *)CompatibleTaskInfo, 0};
#else
    return (AsignIdentityBinding){0};
#endif
}
