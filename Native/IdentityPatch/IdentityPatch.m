#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <string.h>
#import "Rebind.h"
#import "CompatibilityPatch.h"
#import "CloudKitPatch.h"
#import "DyldPatch.h"

// Written to each app/extension Info.plist before zsign changes its identity.
static NSString *const OriginalKey = @"AsignOriginalBundleIdentifier";
__attribute__((used, visibility("default")))
const char AsignPatchVersion[] = "AsignPatch/v1";

static NSDictionary *(*GetInfo)(NSBundle *, SEL);
static NSDictionary *(*GetLocalizedInfo)(NSBundle *, SEL);
static NSString *(*GetIdentifier)(NSBundle *, SEL);
static id (*GetValue)(NSBundle *, SEL, NSString *);
static NSBundle *(*FindBundle)(id, SEL, NSString *);
static char ViewKey;
// Background Assets validates the installed app using its registered identity.
// Its Swift shared-manager getter can enter Foundation/LaunchServices helpers
// before returning, so preserve this view through the whole synchronous call.
static _Thread_local BOOL InstalledIdentityRequested;
typedef void *(*AssetManagerGetter)(void *metadata __attribute__((swift_context)))
    __attribute__((swiftcall));
static AssetManagerGetter GetAssetManager;

static BOOL NeedsInstalledIdentity(void *caller) {
    if (InstalledIdentityRequested) return YES;
    Dl_info image;
    if (!dladdr(caller, &image) || !image.dli_fname) return NO;
    // Also cover later SDK work outside the initial shared-manager lookup.
    // Include the system directory so an embedded framework with a similar
    // name cannot change the identity view for app-owned code.
    return strstr(image.dli_fname, "/System/Library/Frameworks/BackgroundAssets.framework/") ||
        strstr(image.dli_fname, "/System/Library/PrivateFrameworks/ManagedBackgroundAssetsHelper.framework/");
}

// Restore the prior view for nested calls and Objective-C exceptions. Keep
// the view thread-local: concurrent app lookups must still see the original ID.
#define RETURN_INSTALLED_IDENTITY(expression) do { \
    BOOL previous = InstalledIdentityRequested; \
    InstalledIdentityRequested = YES; \
    @try { return (expression); } \
    @finally { InstalledIdentityRequested = previous; } \
} while (0)

static void *__attribute__((swiftcall)) AssetManager(void *metadata __attribute__((swift_context))) {
    // Forward the Swift metatype/self register and the SDK's retained result
    // unchanged. Never return nil or a substitute for a Swift actor instance.
    RETURN_INSTALLED_IDENTITY(GetAssetManager(metadata));
}

static NSString *OriginalIdentifier(NSDictionary *info) {
    id value = info[OriginalKey];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

// CF's Get APIs require a borrowed result that remains alive after returning.
// Associate one immutable view with the real dictionary rather than handing
// back a temporary copy or modifying Foundation's actual signing metadata.
static NSDictionary *IdentityView(NSDictionary *info, NSString *identifier) {
    if (!info || !identifier || [info[@"CFBundleIdentifier"] isEqual:identifier]) return info;
    @synchronized (info) {
        NSMutableDictionary *views = objc_getAssociatedObject(info, &ViewKey);
        if (!views) {
            views = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(info, &ViewKey, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSDictionary *view = views[identifier];
        if (!view) {
            NSMutableDictionary *copy = [info mutableCopy];
            copy[@"CFBundleIdentifier"] = identifier;
            view = [copy copy];
            views[identifier] = view;
        }
        return view;
    }
}

static NSDictionary *BundleInfo(NSBundle *bundle, SEL selector) {
    if (NeedsInstalledIdentity(__builtin_return_address(0))) {
        RETURN_INSTALLED_IDENTITY(GetInfo(bundle, selector));
    }
    NSDictionary *info = GetInfo(bundle, selector);
    return IdentityView(info, OriginalIdentifier(info));
}

static NSDictionary *BundleLocalizedInfo(NSBundle *bundle, SEL selector) {
    if (NeedsInstalledIdentity(__builtin_return_address(0))) {
        RETURN_INSTALLED_IDENTITY(GetLocalizedInfo(bundle, selector));
    }
    NSDictionary *info = GetInfo(bundle, @selector(infoDictionary));
    return IdentityView(GetLocalizedInfo(bundle, selector), OriginalIdentifier(info));
}

static NSString *BundleIdentifier(NSBundle *bundle, SEL selector) {
    if (NeedsInstalledIdentity(__builtin_return_address(0))) {
        RETURN_INSTALLED_IDENTITY(GetIdentifier(bundle, selector));
    }
    return OriginalIdentifier(GetInfo(bundle, @selector(infoDictionary))) ?: GetIdentifier(bundle, selector);
}

static id BundleValue(NSBundle *bundle, SEL selector, NSString *key) {
    if (NeedsInstalledIdentity(__builtin_return_address(0))) {
        RETURN_INSTALLED_IDENTITY(GetValue(bundle, selector, key));
    }
    if ([key isEqualToString:@"CFBundleIdentifier"]) {
        NSString *identifier = OriginalIdentifier(GetInfo(bundle, @selector(infoDictionary)));
        if (identifier) return identifier;
    }
    return GetValue(bundle, selector, key);
}

static NSBundle *BundleForIdentifier(id cls, SEL selector, NSString *identifier) {
    if (NeedsInstalledIdentity(__builtin_return_address(0))) {
        RETURN_INSTALLED_IDENTITY(FindBundle(cls, selector, identifier));
    }
    NSBundle *found = FindBundle(cls, selector, identifier);
    if (found || !identifier) return found;
    NSBundle *main = NSBundle.mainBundle;
    if ([OriginalIdentifier(GetInfo(main, @selector(infoDictionary))) isEqual:identifier]) return main;
    for (NSBundle *bundle in NSBundle.allBundles) {
        if ([OriginalIdentifier(GetInfo(bundle, @selector(infoDictionary))) isEqual:identifier]) return bundle;
    }
    // Resource bundles can have a CFBundle before appearing in allBundles.
    CFArrayRef bundles = CFBundleGetAllBundles();
    for (CFIndex i = 0; bundles && i < CFArrayGetCount(bundles); ++i) {
        CFBundleRef bundle = (CFBundleRef)CFArrayGetValueAtIndex(bundles, i);
        NSDictionary *info = (__bridge NSDictionary *)CFBundleGetInfoDictionary(bundle);
        if ([OriginalIdentifier(info) isEqual:identifier]) {
            NSURL *url = CFBridgingRelease(CFBundleCopyBundleURL(bundle));
            return [NSBundle bundleWithURL:url];
        }
    }
    return nil;
}

static NSString *CFOriginalIdentifier(CFBundleRef bundle) {
    if (!bundle) return nil;
    return OriginalIdentifier((__bridge NSDictionary *)CFBundleGetInfoDictionary(bundle));
}

static CFStringRef IdentityCFBundleGetIdentifier(CFBundleRef bundle) {
    NSString *identifier = CFOriginalIdentifier(bundle);
    return identifier ? (__bridge CFStringRef)identifier : CFBundleGetIdentifier(bundle);
}

static CFDictionaryRef IdentityCFBundleGetInfoDictionary(CFBundleRef bundle) {
    NSDictionary *info = (__bridge NSDictionary *)CFBundleGetInfoDictionary(bundle);
    return (__bridge CFDictionaryRef)IdentityView(info, OriginalIdentifier(info));
}

static CFDictionaryRef IdentityCFBundleGetLocalInfoDictionary(CFBundleRef bundle) {
    NSDictionary *info = (__bridge NSDictionary *)CFBundleGetLocalInfoDictionary(bundle);
    return (__bridge CFDictionaryRef)IdentityView(info, CFOriginalIdentifier(bundle));
}

static CFTypeRef IdentityCFBundleGetValueForInfoDictionaryKey(CFBundleRef bundle, CFStringRef key) {
    if (key && CFEqual(key, CFSTR("CFBundleIdentifier"))) {
        NSString *identifier = CFOriginalIdentifier(bundle);
        if (identifier) return (__bridge CFStringRef)identifier;
    }
    return CFBundleGetValueForInfoDictionaryKey(bundle, key);
}

static CFDictionaryRef CopyIdentityView(CFDictionaryRef info) CF_RETURNS_RETAINED;
static CFDictionaryRef CopyIdentityView(CFDictionaryRef info) {
    if (!info) return NULL;
    NSDictionary *raw = (__bridge NSDictionary *)info;
    NSDictionary *view = IdentityView(raw, OriginalIdentifier(raw));
    CFDictionaryRef result = (CFDictionaryRef)CFRetain((__bridge CFDictionaryRef)view);
    CFRelease(info);
    return result;
}

static CFDictionaryRef IdentityCFBundleCopyInfoDictionaryForURL(CFURLRef url) CF_RETURNS_RETAINED;
static CFDictionaryRef IdentityCFBundleCopyInfoDictionaryForURL(CFURLRef url) {
    return CopyIdentityView(CFBundleCopyInfoDictionaryForURL(url));
}

static CFDictionaryRef IdentityCFBundleCopyInfoDictionaryInDirectory(CFURLRef url) CF_RETURNS_RETAINED;
static CFDictionaryRef IdentityCFBundleCopyInfoDictionaryInDirectory(CFURLRef url) {
    return CopyIdentityView(CFBundleCopyInfoDictionaryInDirectory(url));
}

static CFBundleRef IdentityCFBundleGetBundleWithIdentifier(CFStringRef identifier) {
    CFBundleRef found = CFBundleGetBundleWithIdentifier(identifier);
    if (found || !identifier) return found;
    NSString *requested = (__bridge NSString *)identifier;
    CFBundleRef main = CFBundleGetMainBundle();
    if ([CFOriginalIdentifier(main) isEqual:requested]) return main;
    CFArrayRef bundles = CFBundleGetAllBundles();
    for (CFIndex i = 0; bundles && i < CFArrayGetCount(bundles); ++i) {
        CFBundleRef bundle = (CFBundleRef)CFArrayGetValueAtIndex(bundles, i);
        if ([CFOriginalIdentifier(bundle) isEqual:requested]) return bundle;
    }
    return NULL;
}

static void InstallIdentityPatch(void) {
    Class cls = NSBundle.class;
    Method info = class_getInstanceMethod(cls, @selector(infoDictionary));
    Method localized = class_getInstanceMethod(cls, @selector(localizedInfoDictionary));
    Method identifier = class_getInstanceMethod(cls, @selector(bundleIdentifier));
    Method value = class_getInstanceMethod(cls, @selector(objectForInfoDictionaryKey:));
    Method find = class_getClassMethod(cls, @selector(bundleWithIdentifier:));
    GetInfo = (void *)method_getImplementation(info);
    GetLocalizedInfo = (void *)method_getImplementation(localized);
    GetIdentifier = (void *)method_getImplementation(identifier);
    GetValue = (void *)method_getImplementation(value);
    FindBundle = (void *)method_getImplementation(find);
    method_setImplementation(info, (IMP)BundleInfo);
    method_setImplementation(localized, (IMP)BundleLocalizedInfo);
    method_setImplementation(identifier, (IMP)BundleIdentifier);
    method_setImplementation(value, (IMP)BundleValue);
    method_setImplementation(find, (IMP)BundleForIdentifier);

    // Our own imports retain the real implementations. Identity is scoped to
    // app code; Security keeps the legacy patch's process-wide import coverage.
#define BIND(name) { #name, (void *)name, (void *)Identity##name, 0 }
    static AsignIdentityBinding bindings[] = {
        BIND(CFBundleGetIdentifier), BIND(CFBundleGetInfoDictionary),
        BIND(CFBundleGetLocalInfoDictionary), BIND(CFBundleGetValueForInfoDictionaryKey),
        BIND(CFBundleCopyInfoDictionaryForURL), BIND(CFBundleCopyInfoDictionaryInDirectory),
        BIND(CFBundleGetBundleWithIdentifier),
        { "SecItemAdd", (void *)SecItemAdd, (void *)AsignSecItemAdd, 1 },
        { "SecItemCopyMatching", (void *)SecItemCopyMatching, (void *)AsignSecItemCopyMatching, 1 },
        { "SecItemUpdate", (void *)SecItemUpdate, (void *)AsignSecItemUpdate, 1 },
        { "SecItemDelete", (void *)SecItemDelete, (void *)AsignSecItemDelete, 1 },
        { NULL, NULL, NULL, 0 },
        { NULL, NULL, NULL, 0 },
        { NULL, NULL, NULL, 0 }
    };
#undef BIND
    NSURL *scope = NSBundle.mainBundle.bundleURL;
    for (NSURL *parent = scope; parent.path.length > 1; parent = parent.URLByDeletingLastPathComponent) {
        if ([parent.pathExtension isEqualToString:@"app"]) { scope = parent; break; }
    }
    size_t count = sizeof(bindings) / sizeof(bindings[0]) - 3;
    AsignIdentityBinding dyld = AsignDyldTaskInfoBinding();
    if (dyld.original) bindings[count++] = dyld;
    AsignIdentityBinding automatic = AsignCloudKitAutomaticBinding();
    if (automatic.original) bindings[count++] = automatic;
    const char *assetManager = "$s16BackgroundAssets16AssetPackManagerC6sharedACvgZ";
    GetAssetManager = dlsym(RTLD_DEFAULT, assetManager);
    if (GetAssetManager) {
        bindings[count++] = (AsignIdentityBinding){assetManager, (void *)GetAssetManager, (void *)AssetManager, 0};
    }
    AsignIdentityRebind(bindings, count, scope.path.fileSystemRepresentation);
}

// +load runs before app initializers; waiting for a later lifecycle callback
// would miss identity checks made during launch.
@interface AsignOriginalIdentityLoader : NSObject
@end
@implementation AsignOriginalIdentityLoader
+ (void)load {
    @autoreleasepool {
        AsignInstallCompatibilityPatch();
        InstallIdentityPatch();
    }
}
@end
