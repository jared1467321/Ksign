// Compile against the macOS SDK; exercise the production implementations with
// controlled capability snapshots and temporary storage. Never touch Keychain
// Services or install import hooks in the test process.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#include "../PatchPolicy.m"
#include "../CompatibilityPatch.m"
// Keep the loader callable without running its +load during test startup.
#define load asign_test_load
#include "../IdentityPatch.m"
#undef load

static unsigned Checks;
#define CHECK(expression) do { \
    ++Checks; \
    if (!(expression)) { fprintf(stderr, "Failed at line %d: %s\n", __LINE__, #expression); abort(); } \
} while (0)

static size_t CapturedCount;
static AsignIdentityBinding CapturedBindings[14];
void AsignIdentityRebind(const AsignIdentityBinding *bindings, size_t count, const char *scope) {
    CHECK(scope != NULL && count <= 14);
    CapturedCount = count;
    memcpy(CapturedBindings, bindings, count * sizeof(*bindings));
}
void AsignInstallCloudKitPatch(void) {}
AsignIdentityBinding AsignCloudKitAutomaticBinding(void) { return (AsignIdentityBinding){0}; }
AsignIdentityBinding AsignDyldTaskInfoBinding(void) { return (AsignIdentityBinding){0}; }

static NSURL *Documents, *Shared, *Native, *SeenDefaultsContainer;
static NSFileManager *FixtureManager;
@interface FixtureFileManager : NSFileManager
@end
@implementation FixtureFileManager
- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domains {
    if (directory == NSDocumentDirectory) return @[Documents];
    return [super URLsForDirectory:directory inDomains:domains];
}
@end
static id TestDefaultManager(__unused id self, __unused SEL selector) { return FixtureManager; }
static NSURL *NativeGroup(__unused id self, __unused SEL selector, NSString *group) {
    if ([group isEqual:@"group.signed"]) return Shared;
    if ([group isEqual:@"group.authorized"]) return Native;
    return nil;
}
static id TestDefaults(id self __attribute__((ns_consumed)), __unused SEL selector,
                       __unused NSString *suite, NSURL *container) __attribute__((ns_returns_retained));
static id TestDefaults(id self __attribute__((ns_consumed)), __unused SEL selector,
                       __unused NSString *suite, NSURL *container) {
    SeenDefaultsContainer = container;
    return self;
}

static void PolicyChecks(void) {
    OriginalInfo = @{@"AsignOriginalAppGroupIdentifiers": @[@"group.lost", @"group.authorized"],
                     @"AsignOriginalKeychainAccessGroups": @[@"OLD.app", @"NEW.allowed", @"group.authorized"]};
    SignedCapabilities = @{@"keychain-access-groups": @[@"NEW.default", @"NEW.allowed"],
                           @"application-identifier": @"NEW.app",
                           @"com.apple.security.application-groups": @[@"group.signed", @"group.authorized"]};
    CHECK(AsignAppGroupNeedsFallback(@"group.lost"));
    CHECK(!AsignAppGroupNeedsFallback(@"group.authorized"));
    CHECK(!AsignAppGroupNeedsFallback(@"group.unknown"));
    CHECK(AsignNeedsKeychainPatch());
    CHECK([AsignKeychainReplacementGroup(@"OLD.app") isEqual:@"NEW.default"]);
    for (id group in @[@"NEW.allowed", @"NEW.app", @"group.authorized", @"UNKNOWN", @"", @"*", @42]) {
        CHECK(AsignKeychainReplacementGroup(group) == nil);
    }
    CHECK(AsignKeychainReplacementGroup(nil) == nil);
    NSDictionary *plain = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword};
    CHECK(KeychainQuery((__bridge CFDictionaryRef)plain) == plain);
    NSDictionary *authorized = @{(__bridge id)kSecAttrAccessGroup: @"NEW.allowed"};
    CHECK(KeychainQuery((__bridge CFDictionaryRef)authorized) == authorized);
    NSDictionary *lost = @{(__bridge id)kSecAttrAccessGroup: @"OLD.app", @"account": @"keep-me"};
    NSDictionary *rewritten = KeychainQuery((__bridge CFDictionaryRef)lost);
    CHECK([rewritten[(__bridge id)kSecAttrAccessGroup] isEqual:@"NEW.default"]);
    CHECK([rewritten[@"account"] isEqual:@"keep-me"]);
    CHECK([lost[(__bridge id)kSecAttrAccessGroup] isEqual:@"OLD.app"]);
    NSDictionary *saved = SignedCapabilities;
    SignedCapabilities = nil;
    CHECK(!AsignAppGroupNeedsFallback(@"group.lost"));
    CHECK(!AsignNeedsKeychainPatch());
    CHECK(KeychainQuery((__bridge CFDictionaryRef)lost) == lost);
    SignedCapabilities = @{@"keychain-access-groups": @[@"*"], @"application-identifier": @"NEW.app"};
    CHECK(!AsignNeedsKeychainPatch());
    SignedCapabilities = @{@"application-identifier": @"NEW.app"};
    CHECK([AsignKeychainReplacementGroup(@"OLD.app") isEqual:@"NEW.app"]);
    SignedCapabilities = saved;
    NSDictionary *original = OriginalInfo;
    OriginalInfo = @{};
    CHECK(!AsignNeedsKeychainPatch());
    CHECK(!AsignNeedsAppGroupPatch());
    OriginalInfo = @{@"AsignOriginalAppGroupIdentifiers": @[], @"AsignOriginalBundleIdentifier": @"app"};
    CHECK(!AsignNeedsAppGroupPatch());
    OriginalInfo = @{@"AsignPreserveLegacyGroupDirectories": @YES};
    CHECK(AsignNeedsAppGroupPatch());
    CHECK(!AsignAppGroupNeedsFallback(@"group.lost"));
    OriginalInfo = original;
}

static void StorageChecks(NSURL *root) {
    NSFileManager *realManager = NSFileManager.defaultManager;
    Documents = [root URLByAppendingPathComponent:@"Documents"];
    Shared = [root URLByAppendingPathComponent:@"Shared"];
    Native = [root URLByAppendingPathComponent:@"Native"];
    for (NSURL *url in @[Documents, Shared, Native]) {
        CHECK([realManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL]);
    }
    FixtureManager = [FixtureFileManager new];
    Method managerMethod = class_getClassMethod(NSFileManager.class, @selector(defaultManager));
    IMP originalManager = method_setImplementation(managerMethod, (IMP)TestDefaultManager);
    OriginalGroupContainer = NativeGroup;
    OriginalDefaults = TestDefaults;
    CHECK([GroupContainer(FixtureManager, NULL, @"group.authorized") isEqual:Native]);
    CHECK(![realManager fileExistsAtPath:[Shared URLByAppendingPathComponent:@"group.authorized"].path]);
    CHECK(GroupContainer(FixtureManager, NULL, @"group.unknown") == nil);
    CHECK(![realManager fileExistsAtPath:[Shared URLByAppendingPathComponent:@"group.unknown"].path]);
    NSURL *fallback = GroupContainer(FixtureManager, NULL, @"group.lost");
    CHECK([fallback isEqual:[Shared URLByAppendingPathComponent:@"group.lost" isDirectory:YES]]);
    NSURL *data = [fallback URLByAppendingPathComponent:@"saved.txt"];
    CHECK([@"saved" writeToURL:data atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    CHECK(Defaults([NSObject new], NULL, @"group.lost", nil) != nil);
    CHECK([SeenDefaultsContainer isEqual:fallback]);
    CHECK(Defaults([NSObject new], NULL, @"group.authorized", nil) != nil);
    CHECK(SeenDefaultsContainer == nil);
    CHECK(Defaults([NSObject new], NULL, nil, nil) != nil);
    CHECK(SeenDefaultsContainer == nil);
    CHECK(Defaults([NSObject new], NULL, @"group.lost", Native) != nil);
    CHECK([SeenDefaultsContainer isEqual:Native]);
    // Previously redirected authorized groups keep their app-facing data.
    NSURL *legacy = [Documents URLByAppendingPathComponent:@"group.authorized" isDirectory:YES];
    CHECK([realManager createDirectoryAtURL:legacy withIntermediateDirectories:YES attributes:nil error:NULL]);
    CHECK([GroupContainer(FixtureManager, NULL, @"group.authorized") isEqual:Native]);
    NSDictionary *originalPolicy = OriginalInfo;
    NSMutableDictionary *upgrade = [OriginalInfo mutableCopy];
    upgrade[@"AsignPreserveLegacyGroupDirectories"] = @YES;
    OriginalInfo = upgrade;
    CHECK([GroupContainer(FixtureManager, NULL, @"group.authorized") isEqual:legacy]);
    CHECK(Defaults([NSObject new], NULL, @"group.authorized", nil) != nil);
    CHECK([SeenDefaultsContainer isEqual:legacy]);
    // A system caller must still receive the native container and defaults.
    Dl_info image;
    CHECK(dladdr((void *)&StorageChecks, &image));
    SelfImage = image.dli_fbase;
    CHECK([GroupContainer(FixtureManager, NULL, @"group.authorized") isEqual:Native]);
    CHECK(GroupContainer(FixtureManager, NULL, @"group.lost") == nil);
    CHECK(Defaults([NSObject new], NULL, @"group.authorized", nil) != nil);
    CHECK(SeenDefaultsContainer == nil);
    SelfImage = NULL;
    // Missing snapshots can reuse old data, never create an invented group.
    OriginalInfo = @{};
    CHECK(GroupContainer(FixtureManager, NULL, @"group.lost") == nil);
    OriginalInfo = @{@"AsignPreserveLegacyGroupDirectories": @YES};
    CHECK([GroupContainer(FixtureManager, NULL, @"group.lost") isEqual:fallback]);
    CHECK(GroupContainer(FixtureManager, NULL, @"group.other") == nil);
    CHECK([[NSString stringWithContentsOfURL:data encoding:NSUTF8StringEncoding error:NULL] isEqual:@"saved"]);
    OriginalInfo = originalPolicy;
    // A legacy-looking symlink must not be used as a compatibility folder.
    NSURL *link = [Shared URLByAppendingPathComponent:@"group.symlink"];
    CHECK([realManager createSymbolicLinkAtURL:link withDestinationURL:Native error:NULL]);
    OriginalInfo = @{@"AsignOriginalAppGroupIdentifiers": @[@"group.symlink"]};
    CHECK(GroupContainer(FixtureManager, NULL, @"group.symlink") == nil);
    OriginalInfo = originalPolicy;
    method_setImplementation(managerMethod, originalManager);
}

static void *SeenMetadata;
static void *__attribute__((swiftcall)) TestAssetManager(void *metadata __attribute__((swift_context))) {
    CHECK(InstalledIdentityRequested);
    SeenMetadata = metadata;
    return metadata;
}
static void *__attribute__((swiftcall)) ThrowingAssetManager(__unused void *metadata __attribute__((swift_context))) {
    @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
}

static void IdentityChecks(NSURL *root) {
    CHECK(OriginalIdentifier(@{@"CFBundleIdentifier": @"same", @"AsignOriginalBundleIdentifier": @"same"}) == nil);
    CHECK(OriginalIdentifier(@{@"CFBundleIdentifier": @"same", @"AsignOriginalBundleIdentifier": @42}) == nil);
    NSURL *bundleURL = [root URLByAppendingPathComponent:@"Fixture.bundle" isDirectory:YES];
    NSURL *contents = [bundleURL URLByAppendingPathComponent:@"Contents" isDirectory:YES];
    CHECK([NSFileManager.defaultManager createDirectoryAtURL:contents withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSDictionary *info = @{@"CFBundleIdentifier": @"test.installed", @"AsignOriginalBundleIdentifier": @"test.original"};
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    CHECK([plist writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] options:NSDataWritingAtomic error:NULL]);
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)bundleURL);
    CHECK(bundle != NULL);
    CHECK([(__bridge id)IdentityCFBundleGetIdentifier(bundle) isEqual:@"test.original"]);
    CFDictionaryRef view = IdentityCFBundleGetInfoDictionary(bundle);
    CHECK([((__bridge NSDictionary *)view)[@"CFBundleIdentifier"] isEqual:@"test.original"]);
    CHECK(view == IdentityCFBundleGetInfoDictionary(bundle));
    CHECK([(__bridge id)CFBundleGetIdentifier(bundle) isEqual:@"test.installed"]);
    NSBundle *objcBundle = [NSBundle bundleWithURL:bundleURL];
    GetInfo = (void *)method_getImplementation(class_getInstanceMethod(NSBundle.class, @selector(infoDictionary)));
    GetIdentifier = (void *)method_getImplementation(class_getInstanceMethod(NSBundle.class, @selector(bundleIdentifier)));
    CHECK([BundleIdentifier(objcBundle, @selector(bundleIdentifier)) isEqual:@"test.original"]);
    CHECK([objcBundle.bundleIdentifier isEqual:@"test.installed"]);
    Dl_info image;
    CHECK(dladdr((void *)&IdentityChecks, &image));
    SelfImage = image.dli_fbase;
    CHECK([BundleIdentifier(objcBundle, @selector(bundleIdentifier)) isEqual:@"test.installed"]);
    CHECK(IdentityCFBundleGetInfoDictionary(bundle) == CFBundleGetInfoDictionary(bundle));
    CHECK(!InstalledIdentityRequested);
    SelfImage = NULL;
    InstalledIdentityRequested = YES;
    CHECK([(__bridge id)IdentityCFBundleGetIdentifier(bundle) isEqual:@"test.installed"]);
    CHECK(IdentityCFBundleGetInfoDictionary(bundle) == CFBundleGetInfoDictionary(bundle));
    CHECK([(__bridge id)IdentityCFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleIdentifier")) isEqual:@"test.installed"]);
    CFDictionaryRef copied = IdentityCFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)bundleURL);
    CHECK(copied != NULL);
    CHECK([((__bridge NSDictionary *)copied)[@"CFBundleIdentifier"] isEqual:@"test.installed"]);
    CFRelease(copied);
    InstalledIdentityRequested = NO;
    GetAssetManager = TestAssetManager;
    int metadata;
    CHECK(AssetManager(&metadata) == &metadata && SeenMetadata == &metadata);
    CHECK(!InstalledIdentityRequested);
    InstalledIdentityRequested = YES;
    CHECK(AssetManager(&metadata) == &metadata);
    CHECK(InstalledIdentityRequested);
    InstalledIdentityRequested = NO;
    GetAssetManager = ThrowingAssetManager;
    @try { AssetManager(&metadata); CHECK(NO); }
    @catch (NSException *exception) { CHECK([exception.name isEqual:@"Fixture"]); }
    CHECK(!InstalledIdentityRequested);
    CFRelease(bundle);

    IMP nativeIdentifier = method_getImplementation(class_getInstanceMethod(NSBundle.class, @selector(bundleIdentifier)));
    InstallIdentityPatch();
    // The plain test host has no renamed identity and must not be swizzled.
    CHECK(nativeIdentifier == method_getImplementation(class_getInstanceMethod(NSBundle.class, @selector(bundleIdentifier))));
    CHECK(CapturedCount == 4);
    for (size_t i = 0; i < CapturedCount; ++i) {
        CHECK(!CapturedBindings[i].includeSystemImages);
        CHECK(!strncmp(CapturedBindings[i].name, "SecItem", 7));
    }
}

int main(void) {
    @autoreleasepool {
        AsignInitializePatchPolicy();
        // Treat this executable as app code, with system frameworks outside
        // its directory. The production dylib itself remains excluded normally.
        Dl_info image;
        CHECK(dladdr((void *)&main, &image));
        free(AppScope);
        free(CanonicalScope);
        AppScope = strdup([[[NSString stringWithUTF8String:image.dli_fname] stringByDeletingLastPathComponent] fileSystemRepresentation]);
        CanonicalScope = NULL;
        SelfImage = NULL;
        CHECK(AsignPatchCallerIsApp((void *)&main));
        CHECK(!AsignPatchCallerIsApp((void *)&printf));
        CHECK(!InsideScope("/app-other/file", "/app"));
        PolicyChecks();
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        StorageChecks(root);
        IdentityChecks(root);
        CHECK([NSFileManager.defaultManager removeItemAtURL:root error:NULL]);
        printf("%u runtime checks passed\n", Checks);
    }
    return 0;
}
