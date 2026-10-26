#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <string.h>
#import "CompatibilityPatch.h"
#import "CloudKitPatch.h"
#import "PatchPolicy.h"
#import "PatchOptions.h"
#import "MethodHook.h"

// Source-built equivalents of the legacy patch's keychain, app-group,
// defaults and CloudKit hooks. They share one image and rebinder with identity.
__attribute__((used, visibility("default")))
const char AsignCompatibilityPatchVersion[] = "AsignCompatibilityPatch/v1";

static NSURL *GroupRoot;
typedef id (*InitSuite)(id __attribute__((ns_consumed)), SEL, NSString *, NSURL *) __attribute__((ns_returns_retained));
typedef id (*InitPublicSuite)(id __attribute__((ns_consumed)), SEL, NSString *) __attribute__((ns_returns_retained));
static InitSuite OriginalDefaults;
static InitPublicSuite OriginalPublicDefaults;
static NSURL *(*OriginalGroupContainer)(id, SEL, NSString *);
static _Thread_local __unsafe_unretained NSString *AppDefaultsSuite;

static BOOL CompatibleMethod(Method method, unsigned arguments) {
    return (arguments == 3 || arguments == 4) &&
        AsignMethodMatches(method, "@", "@", arguments == 4 ? "@" : NULL);
}

static void Hook(Class cls, NSString *name, IMP replacement, IMP *original, unsigned arguments) {
    if (arguments != 3 && arguments != 4) return;
    AsignHookMethod(cls, NSSelectorFromString(name), replacement, original,
                    "@", "@", arguments == 4 ? "@" : NULL);
}

static NSDictionary *KeychainQuery(CFDictionaryRef query) {
    NSDictionary *original = (__bridge NSDictionary *)query;
    if (![original isKindOfClass:NSDictionary.class]) return original;
#if TARGET_OS_IPHONE
    NSString *replacement = AsignKeychainReplacementGroup(original[(__bridge id)kSecAttrAccessGroup]);
    if (!replacement) return original;
    NSMutableDictionary *copy = [original mutableCopy];
    copy[(__bridge id)kSecAttrAccessGroup] = replacement;
    return copy;
#else
    return original;
#endif
}

static OSStatus KeychainResult(OSStatus (*original)(CFDictionaryRef, CFTypeRef *),
                               CFDictionaryRef query, CFTypeRef *result, BOOL search) {
    CFTypeRef value = NULL;
    OSStatus status = original(query, result ? &value : NULL);
    // An unauthorized explicit group can be reported as item-not-found by
    // searches, even when Add reported missing-entitlement for that group.
    // Still require KeychainQuery's conclusive original/signed group mapping.
    if (status == errSecMissingEntitlement || (search && status == errSecItemNotFound)) {
        NSDictionary *repaired = KeychainQuery(query);
        if ((__bridge CFDictionaryRef)repaired != query) {
            if (value) { CFRelease(value); value = NULL; }
            status = original((__bridge CFDictionaryRef)repaired, result ? &value : NULL);
        }
    }
    if (result) *result = value;
    return status;
}

OSStatus AsignSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return KeychainResult(SecItemAdd, attributes, result, NO);
}
OSStatus AsignSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return KeychainResult(SecItemCopyMatching, query, result, YES);
}
OSStatus AsignSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    OSStatus status = SecItemUpdate(query, attributes);
    if (status != errSecMissingEntitlement && status != errSecItemNotFound) return status;
    NSDictionary *repairedQuery = KeychainQuery(query);
    // A missing item in an authorized/default/unknown query is not repaired
    // merely because the update attributes name an unavailable destination.
    if (status == errSecItemNotFound && (__bridge CFDictionaryRef)repairedQuery == query) return status;
    NSDictionary *repairedAttributes = KeychainQuery(attributes);
    if ((__bridge CFDictionaryRef)repairedQuery == query && (__bridge CFDictionaryRef)repairedAttributes == attributes) return status;
    return SecItemUpdate((__bridge CFDictionaryRef)repairedQuery, (__bridge CFDictionaryRef)repairedAttributes);
}
OSStatus AsignSecItemDelete(CFDictionaryRef query) {
    OSStatus status = SecItemDelete(query);
    if (status != errSecMissingEntitlement && status != errSecItemNotFound) return status;
    NSDictionary *repaired = KeychainQuery(query);
    return (__bridge CFDictionaryRef)repaired == query ? status : SecItemDelete((__bridge CFDictionaryRef)repaired);
}

static NSURL *SharedRoot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!OriginalGroupContainer) return;
        for (NSString *group in AsignInstalledAppGroups()) {
            GroupRoot = OriginalGroupContainer(NSFileManager.defaultManager,
                @selector(containerURLForSecurityApplicationGroupIdentifier:), group);
            if (GroupRoot) break;
        }
    });
    return GroupRoot;
}

static BOOL GroupIdentifier(NSString *identifier) {
    return [identifier isKindOfClass:NSString.class] && identifier.length > 6 &&
        [identifier hasPrefix:@"group."] &&
        [identifier rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\*"]].location == NSNotFound;
}

static NSURL *CompatibilityGroupURL(NSString *identifier, NSURL *native) {
    if (!GroupIdentifier(identifier)) return nil;
    BOOL legacy = AsignPreservesLegacyGroupDirectories();
    BOOL needsFallback = AsignAppGroupNeedsFallback(identifier);
    // Folder-name coincidence is not evidence of an earlier patch. A valid
    // native group wins unless signing explicitly recorded a legacy upgrade.
    if (!legacy && (native || !needsFallback)) return nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *shared = SharedRoot();
    NSURL *documents = [[manager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    // Reuse the old layout only when it exists. Do not move or merge data:
    // both the file API and group defaults must keep choosing the same path.
    for (NSURL *root in shared ? @[shared, documents ?: shared] : (documents ? @[documents] : @[])) {
        NSURL *existing = [root URLByAppendingPathComponent:identifier isDirectory:YES];
        NSDictionary *attributes = [manager attributesOfItemAtPath:existing.path error:NULL];
        if ([attributes[NSFileType] isEqual:NSFileTypeDirectory]) return existing;
    }
    if (native || !needsFallback) return nil;
    NSURL *root = shared ?: documents;
    NSURL *url = [root URLByAppendingPathComponent:identifier isDirectory:YES];
    // Refuse symlinks and non-directory collisions instead of following a
    // legacy-looking path outside the selected container.
    if (!url || [manager attributesOfItemAtPath:url.path error:NULL]) return nil;
    if (![manager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL]) {
        // Another app/extension may have created the same shared fallback.
        if (![[manager attributesOfItemAtPath:url.path error:NULL][NSFileType] isEqual:NSFileTypeDirectory]) return nil;
    }
    return [[manager attributesOfItemAtPath:url.path error:NULL][NSFileType] isEqual:NSFileTypeDirectory] ? url : nil;
}

static NSURL *GroupContainer(id self, SEL selector, NSString *identifier) {
    NSURL *native = OriginalGroupContainer(self, selector, identifier);
    if (!AsignPatchCallerIsApp(__builtin_return_address(0))) return native;
    return CompatibilityGroupURL(identifier, native) ?: native;
}

static id PublicDefaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite) __attribute__((ns_returns_retained));
static id PublicDefaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite) {
    NSString *previous = AppDefaultsSuite;
    AppDefaultsSuite = AsignPatchCallerIsApp(__builtin_return_address(0)) && GroupIdentifier(suite) ? suite : nil;
    @try { return OriginalPublicDefaults(self, selector, suite); }
    @finally { AppDefaultsSuite = previous; }
}

static id Defaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite, NSURL *container) __attribute__((ns_returns_retained));
static id Defaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite, NSURL *container) {
    if (!container && GroupIdentifier(suite) &&
        ([suite isEqual:AppDefaultsSuite] || AsignPatchCallerIsApp(__builtin_return_address(0)))) {
        NSURL *native = OriginalGroupContainer(NSFileManager.defaultManager,
            @selector(containerURLForSecurityApplicationGroupIdentifier:), suite);
        container = CompatibilityGroupURL(suite, native);
    }
    return OriginalDefaults(self, selector, suite, container);
}

static void InstallAppGroupPatch(Class manager, Class defaults) {
    if (!AsignNeedsAppGroupPatch()) return;
    Method group = class_getInstanceMethod(manager, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (!CompatibleMethod(group, 3)) return;
    // File access is a public API. An absent or changed private defaults
    // initializer must not silently remove the file-container repair too:
    // apps can require that container while initializing their startup logs.
    Hook(manager, @"containerURLForSecurityApplicationGroupIdentifier:",
         (IMP)GroupContainer, (IMP *)&OriginalGroupContainer, 3);
    // The public initializer carries app provenance through Foundation's
    // internal call. Install these together only when both ABIs are supported.
    Method internal = defaults ? class_getInstanceMethod(defaults, NSSelectorFromString(@"_initWithSuiteName:container:")) : NULL;
    Method public = defaults ? class_getInstanceMethod(defaults, @selector(initWithSuiteName:)) : NULL;
    if (!CompatibleMethod(internal, 4) || !CompatibleMethod(public, 3)) return;
    Hook(defaults, @"_initWithSuiteName:container:", (IMP)Defaults, (IMP *)&OriginalDefaults, 4);
    Hook(defaults, @"initWithSuiteName:", (IMP)PublicDefaults, (IMP *)&OriginalPublicDefaults, 3);
}

void AsignInstallCompatibilityPatch(void) {
    if (AsignPatchEnabled(AsignPatchCloudKit)) AsignInstallCloudKitPatch();
    if (AsignPatchEnabled(AsignPatchAppGroups)) InstallAppGroupPatch(NSFileManager.class, NSUserDefaults.class);
}
