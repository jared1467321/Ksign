#ifndef ASIGN_CLOUDKIT_ABI_H
#define ASIGN_CLOUDKIT_ABI_H
// SwiftData's resilient CloudKitDatabase.automatic getter initializes an
// indirect result (x8 on ARM64). Let Swift build the value; never infer the
// private layout of a SwiftData configuration in Objective-C.
typedef void (*AsignCloudAutomaticGetter)(void *result __attribute__((swift_indirect_result)))
    __attribute__((swiftcall));
#endif
