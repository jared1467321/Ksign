//
//  MachOUtils.h
//  Feather
//
//  Created by samara on 12.06.2025.
//

@import Darwin;
@import Foundation;
@import MachO;

NSString *LCPatchMachOFixupARM64eSlice(const char *path);
NSString *LCPatchMachOForSDK26(const char *path);

// nil on success (including resources and already-iOS binaries).
NSString * _Nullable KsignPatchMachOForIOS(const char * _Nonnull path,
                                          uint32_t minimumOS, uint32_t sdk,
                                          NSUInteger * _Nonnull changedSlices);
