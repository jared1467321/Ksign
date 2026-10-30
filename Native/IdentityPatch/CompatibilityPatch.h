#import <Security/Security.h>
#import <Foundation/Foundation.h>

void AsignInstallCompatibilityPatch(void);
BOOL AsignNeedsBackgroundAssetsCompatibility(void);
void *AsignWithBackgroundAssetsCompatibility(void *(^operation)(void));
OSStatus AsignSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result);
OSStatus AsignSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);
OSStatus AsignSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes);
OSStatus AsignSecItemDelete(CFDictionaryRef query);
