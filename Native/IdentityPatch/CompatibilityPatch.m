#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "CompatibilityPatch.h"
#import "CloudKitPatch.h"

// Source-built equivalents of the legacy patch's keychain, app-group,
// defaults and CloudKit hooks. They share one image and rebinder with identity.
__attribute__((used, visibility("default")))
const char AsignCompatibilityPatchVersion[] = "AsignCompatibilityPatch/v1";

static NSString *AccessGroup;
static NSURL *GroupRoot;
typedef id (*InitSuite)(id __attribute__((ns_consumed)), SEL, NSString *, NSURL *) __attribute__((ns_returns_retained));
static InitSuite OriginalDefaults;

static id SendObject(id object, NSString *selector) {
    SEL method = NSSelectorFromString(selector);
    if (![object respondsToSelector:method]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, method);
}

static void Hook(Class cls, NSString *name, IMP replacement, IMP *original) {
    if (!cls) return;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP previous = method_getImplementation(method);
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        if (original) *original = previous;
    } else {
        previous = method_setImplementation(method, replacement);
        if (original) *original = previous;
    }
}

#if TARGET_OS_IPHONE
static void FindAccessGroup(void) {
    // Keep the legacy probe's account/service so upgrades reuse its item.
    NSDictionary *probe = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrAccount: @"blatantsPatch",
                            (__bridge id)kSecAttrService: @"",
                            (__bridge id)kSecReturnAttributes: @YES};
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)probe, &result);
    if (status == errSecItemNotFound) status = SecItemAdd((__bridge CFDictionaryRef)probe, &result);
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        id group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        if ([group isKindOfClass:NSString.class] && [group length]) AccessGroup = [group copy];
    }
    if (result) CFRelease(result);
}
#endif

static NSDictionary *KeychainQuery(CFDictionaryRef query) {
    NSDictionary *original = (__bridge NSDictionary *)query;
    if (!original || !AccessGroup) return original;
    NSMutableDictionary *copy = [original mutableCopy];
    copy[(__bridge id)kSecAttrAccessGroup] = AccessGroup;
    return copy;
}

OSStatus AsignSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return SecItemAdd((__bridge CFDictionaryRef)KeychainQuery(attributes), result);
}
OSStatus AsignSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return SecItemCopyMatching((__bridge CFDictionaryRef)KeychainQuery(query), result);
}
OSStatus AsignSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    return SecItemUpdate((__bridge CFDictionaryRef)KeychainQuery(query), attributes);
}
OSStatus AsignSecItemDelete(CFDictionaryRef query) {
    return SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(query));
}

static NSURL *SharedRoot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id proxy = SendObject(NSClassFromString(@"LSBundleProxy"), @"bundleProxyForCurrentProcess");
        id entitlements = SendObject(proxy, @"entitlements");
        id urls = SendObject(proxy, @"groupContainerURLs");
        if (![entitlements isKindOfClass:NSDictionary.class] || ![urls isKindOfClass:NSDictionary.class]) return;
        id groups = entitlements[@"com.apple.security.application-groups"];
        if (![groups isKindOfClass:NSArray.class]) return;
        id group = [groups firstObject];
        id url = group ? urls[group] : nil;
        if ([url isKindOfClass:NSURL.class]) GroupRoot = url;
    });
    return GroupRoot;
}

static NSURL *GroupContainer(__unused id self, __unused SEL selector, NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
        [identifier isEqualToString:@"."] || [identifier isEqualToString:@".."] ||
        [identifier rangeOfString:@"/"].location != NSNotFound) return nil;
    NSURL *root = SharedRoot();
    if (!root) root = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                         inDomains:NSUserDomainMask] lastObject];
    NSURL *url = [root URLByAppendingPathComponent:identifier isDirectory:YES];
    if (!url || ![NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES
                                                       attributes:nil error:NULL]) return nil;
    return url;
}

static id Defaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite, NSURL *container) __attribute__((ns_returns_retained));
static id Defaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite, NSURL *container) {
    NSURL *root = SharedRoot();
    if ([suite hasPrefix:@"group"] && root) container = [root URLByAppendingPathComponent:suite];
    return OriginalDefaults(self, selector, suite, container);
}

void AsignInstallCompatibilityPatch(void) {
#if TARGET_OS_IPHONE
    // macOS is only a runtime test host; leave its login keychain alone.
    FindAccessGroup();
#endif
    AsignInstallCloudKitPatch();
    Hook(NSFileManager.class, @"containerURLForSecurityApplicationGroupIdentifier:", (IMP)GroupContainer, NULL);
    Hook(NSUserDefaults.class, @"_initWithSuiteName:container:", (IMP)Defaults, (IMP *)&OriginalDefaults);
}
