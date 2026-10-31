#import <Security/Security.h>

void AsignInstallCompatibilityPatch(void);
OSStatus AsignSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result);
OSStatus AsignSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);
OSStatus AsignSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes);
OSStatus AsignSecItemDelete(CFDictionaryRef query);
