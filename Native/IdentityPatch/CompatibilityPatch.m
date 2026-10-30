#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <string.h>
#import "CompatibilityPatch.h"
#import "CloudKitPatch.h"
#import "SubscriptionPatch.h"
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
static _Thread_local __unsafe_unretained NSString *BackgroundAssetsGroup;
static _Thread_local BOOL ReadingNativeGroupRecord;
typedef id (*RecordGetter)(id, SEL);
static RecordGetter OriginalRecordGroupIdentifiers, OriginalRecordGroupURLs;
static NSURL *CompatibilityGroupURL(NSString *identifier, NSURL *native);
static void InstallBackgroundAssetsRecordPatch(void);

static NSURL *NativeGroupContainer(id manager, SEL selector, NSString *identifier) {
    if (!OriginalGroupContainer) return nil;
    BOOL previous = ReadingNativeGroupRecord;
    ReadingNativeGroupRecord = YES;
    @try { return OriginalGroupContainer(manager, selector, identifier); }
    @finally { ReadingNativeGroupRecord = previous; }
}

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
            GroupRoot = NativeGroupContainer(NSFileManager.defaultManager,
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

static NSString *BackgroundAssetsFallbackGroup(void) {
    if (!AsignPatchEnabled(AsignPatchBackgroundAssets) || !AsignPatchEnabled(AsignPatchAppGroups)) return nil;
    id group = NSBundle.mainBundle.infoDictionary[@"BAAppGroupID"];
    return GroupIdentifier(group) && AsignAppGroupNeedsFallback(group) ? group : nil;
}

BOOL AsignNeedsBackgroundAssetsCompatibility(void) {
    return BackgroundAssetsFallbackGroup() != nil;
}

void *AsignWithBackgroundAssetsCompatibility(void *(^operation)(void)) {
    NSString *previous = BackgroundAssetsGroup;
    BackgroundAssetsGroup = BackgroundAssetsFallbackGroup();
    @try {
        if (BackgroundAssetsGroup) {
            // Native lookup and fallback-directory preparation can initialize
            // LaunchServices after +load. Retry the record hooks now, before
            // the SDK validates its registered group membership.
            NSURL *native = NativeGroupContainer(NSFileManager.defaultManager,
                @selector(containerURLForSecurityApplicationGroupIdentifier:), BackgroundAssetsGroup);
            if (!native) (void)CompatibilityGroupURL(BackgroundAssetsGroup, nil);
            InstallBackgroundAssetsRecordPatch();
        }
        return operation();
    }
    @finally { BackgroundAssetsGroup = previous; }
}

static BOOL BackgroundAssetsGroupForCaller(NSString *group, const void *caller) {
    // Only the declared, captured original group can receive SDK repair. A
    // synchronous scope also covers calls made through Foundation helpers.
    if (!GroupIdentifier(group) || ![group isEqualToString:BackgroundAssetsFallbackGroup()]) return NO;
    if ([group isEqualToString:BackgroundAssetsGroup]) return YES;
    Dl_info source, sdk;
    if (!caller || !dladdr(caller, &source) || !source.dli_fbase) return NO;
    // Resolve on demand, without loading the optional framework or invoking
    // Swift. Later SDK calls need the same repair after shared initialization.
    const char *metadata[] = {"$s16BackgroundAssets16AssetPackManagerCMa",
                              "$s29ManagedBackgroundAssetsHelper7AppInfoVMa"};
    for (size_t i = 0; i < sizeof(metadata) / sizeof(metadata[0]); ++i) {
        void *type = dlsym(RTLD_DEFAULT, metadata[i]);
        if (type && dladdr(type, &sdk) && sdk.dli_fbase && source.dli_fbase == sdk.dli_fbase) return YES;
    }
    return NO;
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

static BOOL SwiftDataCaller(const void *caller) {
    Dl_info source, sdk;
    if (!caller || !dladdr(caller, &source) || !source.dli_fbase) return NO;
    // Identify the loaded framework by a public metadata accessor, without
    // calling Swift or depending on SDK paths/offsets. Resolve on demand so a
    // failed lookup before SwiftData loads cannot disable later repairs.
    void *configuration = dlsym(RTLD_DEFAULT, "$s9SwiftData18ModelConfigurationVMa");
    return configuration && dladdr(configuration, &sdk) && sdk.dli_fbase &&
        source.dli_fbase == sdk.dli_fbase;
}

static BOOL CurrentBundleRecord(id record) {
    SEL selector = NSSelectorFromString(@"bundleIdentifier");
    Method method = class_getInstanceMethod(object_getClass(record), selector);
    if (!AsignMethodMatches(method, "@", NULL, NULL)) return NO;
    id identifier = ((RecordGetter)method_getImplementation(method))(record, selector);
    // This library's CF imports retain the installed identity. A record for
    // another app/extension must never receive this process's local group view.
    NSString *installed = (__bridge NSString *)CFBundleGetIdentifier(CFBundleGetMainBundle());
    return [identifier isKindOfClass:NSString.class] && installed && [identifier isEqualToString:installed];
}

static id BackgroundAssetsRecordGroups(id record, SEL selector, const void *caller, BOOL identifiers) {
    RecordGetter original = identifiers ? OriginalRecordGroupIdentifiers : OriginalRecordGroupURLs;
    BOOL previous = ReadingNativeGroupRecord;
    ReadingNativeGroupRecord = YES;
    @try {
        id native = original(record, selector);
        if (previous) return native;
        NSString *group = BackgroundAssetsFallbackGroup();
        if (!BackgroundAssetsGroupForCaller(group, caller) || !CurrentBundleRecord(record)) return native;
        if (identifiers) {
            if (native && ![native isKindOfClass:NSSet.class] && ![native isKindOfClass:NSArray.class]) return native;
            if ([native containsObject:group]) return native;
        } else {
            if (native && ![native isKindOfClass:NSDictionary.class]) return native;
            if (native[group]) return native;
        }
        NSURL *url = NativeGroupContainer(NSFileManager.defaultManager,
            @selector(containerURLForSecurityApplicationGroupIdentifier:), group);
        url = url ?: CompatibilityGroupURL(group, nil);
        if (!url) return native;
        // Expose one real local directory to SDK validation. Neither the native
        // LaunchServices record nor any signed entitlement is modified.
        if (identifiers) {
            if (!native) return [NSSet setWithObject:group];
            id view = [native mutableCopy];
            [view addObject:group];
            return [view copy];
        }
        NSMutableDictionary *view = native ? [native mutableCopy] : [NSMutableDictionary dictionary];
        view[group] = url;
        return [view copy];
    } @finally { ReadingNativeGroupRecord = previous; }
}

static id RecordGroupIdentifiers(id self, SEL selector) {
    return BackgroundAssetsRecordGroups(self, selector, __builtin_return_address(0), YES);
}

static id RecordGroupURLs(id self, SEL selector) {
    return BackgroundAssetsRecordGroups(self, selector, __builtin_return_address(0), NO);
}

static void InstallBackgroundAssetsRecordPatch(void) {
    if (!AsignNeedsBackgroundAssetsCompatibility()) return;
    // Use the concrete app-record class so an SDK override cannot bypass a
    // superclass hook. Inherited methods receive an override on this class.
    Class record = NSClassFromString(@"LSApplicationRecord");
    if (!record) return; // A later manager request can retry after it loads.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AsignHookMethod(record, NSSelectorFromString(@"groupContainerIdentifiers"),
                        (IMP)RecordGroupIdentifiers, (IMP *)&OriginalRecordGroupIdentifiers, "@", NULL, NULL);
        AsignHookMethod(record, NSSelectorFromString(@"groupContainerURLs"),
                        (IMP)RecordGroupURLs, (IMP *)&OriginalRecordGroupURLs, "@", NULL, NULL);
    });
}

static NSURL *GroupContainerForCaller(id self, SEL selector, NSString *identifier, const void *caller) {
    NSURL *native = NativeGroupContainer(self, selector, identifier);
    if (!AsignPatchCallerIsApp(caller)) {
        // Preserve working native containers, including legacy upgrades. SDK
        // repair requires a known lost group and an identified caller/scope.
        if (native || !AsignAppGroupNeedsFallback(identifier) ||
            (!SwiftDataCaller(caller) && !BackgroundAssetsGroupForCaller(identifier, caller))) return native;
    }
    return CompatibilityGroupURL(identifier, native) ?: native;
}

static NSURL *GroupContainer(id self, SEL selector, NSString *identifier) {
    return GroupContainerForCaller(self, selector, identifier, __builtin_return_address(0));
}

static id PublicDefaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite) __attribute__((ns_returns_retained));
static id PublicDefaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite) {
    NSString *previous = AppDefaultsSuite;
    NSString *previousGroup = BackgroundAssetsGroup;
    const void *caller = __builtin_return_address(0);
    BOOL background = BackgroundAssetsGroupForCaller(suite, caller);
    AppDefaultsSuite = (AsignPatchCallerIsApp(caller) || background) && GroupIdentifier(suite) ? suite : nil;
    // Carry only this suite through Foundation's initializer. Unrelated nested
    // suites must not inherit a Background Assets request's provenance.
    BackgroundAssetsGroup = background ? suite : nil;
    @try { return OriginalPublicDefaults(self, selector, suite); }
    @finally { AppDefaultsSuite = previous; BackgroundAssetsGroup = previousGroup; }
}

static id Defaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite, NSURL *container) __attribute__((ns_returns_retained));
static id Defaults(id self __attribute__((ns_consumed)), SEL selector, NSString *suite, NSURL *container) {
    const void *caller = __builtin_return_address(0);
    BOOL background = BackgroundAssetsGroupForCaller(suite, caller);
    if (!container && GroupIdentifier(suite) &&
        ([suite isEqual:AppDefaultsSuite] || AsignPatchCallerIsApp(caller) || background)) {
        NSURL *native = NativeGroupContainer(NSFileManager.defaultManager,
            @selector(containerURLForSecurityApplicationGroupIdentifier:), suite);
        if (!background || !native) container = CompatibilityGroupURL(suite, native);
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
    InstallBackgroundAssetsRecordPatch();
    // The public initializer carries app provenance through Foundation's
    // internal call. Install these together only when both ABIs are supported.
    Method internal = defaults ? class_getInstanceMethod(defaults, NSSelectorFromString(@"_initWithSuiteName:container:")) : NULL;
    Method public = defaults ? class_getInstanceMethod(defaults, @selector(initWithSuiteName:)) : NULL;
    if (!CompatibleMethod(internal, 4) || !CompatibleMethod(public, 3)) return;
    Hook(defaults, @"_initWithSuiteName:container:", (IMP)Defaults, (IMP *)&OriginalDefaults, 4);
    Hook(defaults, @"initWithSuiteName:", (IMP)PublicDefaults, (IMP *)&OriginalPublicDefaults, 3);
}

void AsignInstallCompatibilityPatch(void) {
    if (AsignPatchEnabled(AsignPatchSubscriptionRegistration)) AsignInstallSubscriptionPatch();
    if (AsignPatchEnabled(AsignPatchCloudKit)) AsignInstallCloudKitPatch();
    if (AsignPatchEnabled(AsignPatchAppGroups)) InstallAppGroupPatch(NSFileManager.class, NSUserDefaults.class);
}
