#pragma once
#import <Foundation/Foundation.h>

void AsignInitializePatchPolicy(void);
BOOL AsignPatchCallerIsApp(const void *caller);
BOOL AsignOriginalAppGroup(NSString *identifier);
BOOL AsignAppGroupNeedsFallback(NSString *identifier);
NSArray *AsignInstalledAppGroups(void);
BOOL AsignNeedsKeychainPatch(void);
BOOL AsignNeedsAppGroupPatch(void);
BOOL AsignPreservesLegacyGroupDirectories(void);
NSString *AsignKeychainReplacementGroup(id identifier);
