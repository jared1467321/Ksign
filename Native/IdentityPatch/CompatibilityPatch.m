#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <string.h>
#import "CompatibilityPatch.h"
#import "CloudKitPatch.h"
#import "PatchPolicy.h"
#import "PatchOptions.h"

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
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, "@")) return NO;
    for (unsigned i = 2; i < arguments; ++i) {
        method_getArgumentType(method, i, type, sizeof(type));
        if (strcmp(type, "@")) return NO;
    }
    return YES;
}

static void Hook(Class cls, NSString *name, IMP replacement, IMP *original, unsigned arguments) {
    if (!cls) return;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!CompatibleMethod(method, arguments)) return;
    IMP previous = method_getImplementation(method);
    // Publish the forwarding target before exposing the replacement to other
    // threads, including system threads already running during app startup.
    if (original) *original = previous;
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        previous = method_setImplementation(method, replacement);
        if (original) *original = previous;
    }
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

OSStatus AsignSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return SecItemAdd((__bridge CFDictionaryRef)KeychainQuery(attributes), result);
}
OSStatus AsignSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return SecItemCopyMatching((__bridge CFDictionaryRef)KeychainQuery(query), result);
}
OSStatus AsignSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    return SecItemUpdate((__bridge CFDictionaryRef)KeychainQuery(query),
                         (__bridge CFDictionaryRef)KeychainQuery(attributes));
}
OSStatus AsignSecItemDelete(CFDictionaryRef query) {
    return SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(query));
}

static NSURL *SharedRoot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *group = AsignInstalledAppGroups().firstObject;
        if (group && OriginalGroupContainer) {
            GroupRoot = OriginalGroupContainer(NSFileManager.defaultManager,
                @selector(containerURLForSecurityApplicationGroupIdentifier:), group);
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

void AsignInstallCompatibilityPatch(void) {
    if (AsignPatchEnabled(AsignPatchCloudKit)) AsignInstallCloudKitPatch();
    if (!AsignPatchEnabled(AsignPatchAppGroups) || !AsignNeedsAppGroupPatch()) return;
    // The public initializer carries app provenance through Foundation's
    // internal call. Require all three ABIs before installing this family so
    // file access and defaults cannot select inconsistent fallback locations.
    Method group = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method internal = class_getInstanceMethod(NSUserDefaults.class, NSSelectorFromString(@"_initWithSuiteName:container:"));
    Method public = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
    if (!CompatibleMethod(group, 3) || !CompatibleMethod(internal, 4) || !CompatibleMethod(public, 3)) return;
    Hook(NSFileManager.class, @"containerURLForSecurityApplicationGroupIdentifier:",
         (IMP)GroupContainer, (IMP *)&OriginalGroupContainer, 3);
    Hook(NSUserDefaults.class, @"_initWithSuiteName:container:", (IMP)Defaults, (IMP *)&OriginalDefaults, 4);
    Hook(NSUserDefaults.class, @"initWithSuiteName:", (IMP)PublicDefaults, (IMP *)&OriginalPublicDefaults, 3);
}
