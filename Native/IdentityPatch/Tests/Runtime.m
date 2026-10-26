// Compile against the macOS SDK; exercise the production implementations with
// controlled capability snapshots and temporary storage. Never touch Keychain
// Services or install import hooks in the test process.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <Security/Security.h>
static OSStatus TestSecItemAdd(CFDictionaryRef, CFTypeRef *);
static OSStatus TestSecItemCopyMatching(CFDictionaryRef, CFTypeRef *);
static OSStatus TestSecItemUpdate(CFDictionaryRef, CFDictionaryRef);
static OSStatus TestSecItemDelete(CFDictionaryRef);
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#include "../PatchPolicy.m"
#define SecItemAdd TestSecItemAdd
#define SecItemCopyMatching TestSecItemCopyMatching
#define SecItemUpdate TestSecItemUpdate
#define SecItemDelete TestSecItemDelete
#include "../CompatibilityPatch.m"
#undef SecItemAdd
#undef SecItemCopyMatching
#undef SecItemUpdate
#undef SecItemDelete
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

static OSStatus NativeStatus, NativeRetryStatus = errSecSuccess;
static NSMutableArray *SeenQueries, *SeenAttributes;
static NSMutableArray<NSMutableDictionary *> *StoredItems;

// Model Security independently of the patch's mapping policy: an unauthorized
// add fails with missing-entitlement, while searches in that group find no
// items. Stored items remain in their actual group across API calls.
static BOOL FixtureAuthorizedGroup(id group) {
    return !group || [group isEqual:@"NEW.default"] || [group isEqual:@"NEW.allowed"];
}

static NSMutableDictionary *FixtureItem(NSDictionary *query) {
    id group = query[(__bridge id)kSecAttrAccessGroup];
    if (!FixtureAuthorizedGroup(group)) return nil;
    for (NSMutableDictionary *item in StoredItems) {
        BOOL matches = YES;
        for (id key in @[(__bridge id)kSecClass, (__bridge id)kSecAttrAccessGroup,
                          (__bridge id)kSecAttrService, (__bridge id)kSecAttrAccount]) {
            if (query[key] && ![query[key] isEqual:item[key]]) { matches = NO; break; }
        }
        if (matches) return item;
    }
    return nil;
}

static OSStatus StoredKeychainCall(unsigned operation, NSDictionary *query,
                                  NSDictionary *attributes, CFTypeRef *result) {
    if (result) *result = NULL;
    if (operation == 0) {
        if (!FixtureAuthorizedGroup(query[(__bridge id)kSecAttrAccessGroup])) return errSecMissingEntitlement;
        NSMutableDictionary *item = [query mutableCopy];
        if (!item[(__bridge id)kSecAttrAccessGroup]) item[(__bridge id)kSecAttrAccessGroup] = @"NEW.default";
        if (FixtureItem(item)) return errSecDuplicateItem;
        [StoredItems addObject:item];
        return errSecSuccess;
    }
    NSMutableDictionary *item = FixtureItem(query);
    if (!item) return errSecItemNotFound;
    if (operation == 1) {
        if (result) *result = CFRetain((__bridge CFTypeRef)item[(__bridge id)kSecValueData]);
    } else if (operation == 2) {
        if (!FixtureAuthorizedGroup(attributes[(__bridge id)kSecAttrAccessGroup])) return errSecMissingEntitlement;
        [item addEntriesFromDictionary:attributes];
    } else {
        [StoredItems removeObjectIdenticalTo:item];
    }
    return errSecSuccess;
}

static OSStatus TestKeychainCall(unsigned operation, CFDictionaryRef query,
                                CFDictionaryRef attributes, CFTypeRef *result) {
    [SeenQueries addObject:(__bridge id)query];
    if (operation == 2) [SeenAttributes addObject:(__bridge id)attributes];
    if (StoredItems) return StoredKeychainCall(operation, (__bridge id)query, (__bridge id)attributes, result);
    OSStatus status = SeenQueries.count == 1 ? NativeStatus : NativeRetryStatus;
    if (result) *result = status == errSecSuccess ? CFRetain(SeenQueries.count == 1 ? CFSTR("native") : CFSTR("repaired")) : NULL;
    return status;
}
static OSStatus TestSecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    return TestKeychainCall(0, query, NULL, result);
}
static OSStatus TestSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return TestKeychainCall(1, query, NULL, result);
}
static OSStatus TestSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    return TestKeychainCall(2, query, attributes, NULL);
}
static OSStatus TestSecItemDelete(CFDictionaryRef query) {
    return TestKeychainCall(3, query, NULL, NULL);
}

static void KeychainChecks(void) {
    NSDictionary *lost = @{(__bridge id)kSecAttrAccessGroup: @"OLD.app", @"account": @"keep"};
    NSDictionary *plain = @{@"account": @"keep"};
    NSDictionary *unknown = @{(__bridge id)kSecAttrAccessGroup: @"UNKNOWN"};
    NSDictionary *authorized = @{(__bridge id)kSecAttrAccessGroup: @"NEW.allowed"};
    OSStatus statuses[] = {errSecSuccess, errSecItemNotFound, errSecDuplicateItem, errSecAuthFailed,
                          errSecInteractionNotAllowed, errSecParam, errSecMissingEntitlement};
    for (NSUInteger i = 0; i < sizeof(statuses) / sizeof(statuses[0]); ++i) {
        NativeStatus = statuses[i];
        for (NSDictionary *query in @[lost, plain, unknown, authorized]) {
            for (unsigned operation = 0; operation < 4; ++operation) {
                BOOL retry = query == lost && (NativeStatus == errSecMissingEntitlement ||
                                               (operation != 0 && NativeStatus == errSecItemNotFound));
                SeenQueries = [NSMutableArray array];
                SeenAttributes = [NSMutableArray array];
                CFTypeRef result = NULL;
                OSStatus status;
                CFDictionaryRef raw = (__bridge CFDictionaryRef)query;
                if (operation == 0) status = AsignSecItemAdd(raw, &result);
                else if (operation == 1) status = AsignSecItemCopyMatching(raw, &result);
                else if (operation == 2) status = AsignSecItemUpdate(raw, raw);
                else status = AsignSecItemDelete(raw);
                CHECK(status == (retry ? errSecSuccess : NativeStatus));
                CHECK(SeenQueries.count == (retry ? 2 : 1));
                CHECK(SeenQueries.firstObject == query);
                if (retry) {
                    CHECK([SeenQueries.lastObject[(__bridge id)kSecAttrAccessGroup] isEqual:@"NEW.default"]);
                    CHECK([SeenQueries.lastObject[@"account"] isEqual:@"keep"]);
                }
                if (operation < 2 && status == errSecSuccess) CHECK(CFEqual(result, retry ? CFSTR("repaired") : CFSTR("native")));
                if (result) CFRelease(result);
                if (operation == 2) {
                    CHECK(SeenAttributes.firstObject == query);
                    if (retry) CHECK([SeenAttributes.lastObject[(__bridge id)kSecAttrAccessGroup] isEqual:@"NEW.default"]);
                }
            }
        }
    }
    // An authorized query can fail because the requested update destination
    // lost permission. Repair only that attributes dictionary on the retry.
    SeenQueries = [NSMutableArray array];
    SeenAttributes = [NSMutableArray array];
    CHECK(AsignSecItemUpdate((__bridge CFDictionaryRef)authorized, (__bridge CFDictionaryRef)lost) == errSecSuccess);
    CHECK(SeenQueries.count == 2 && SeenQueries.lastObject == authorized);
    CHECK([SeenAttributes.lastObject[(__bridge id)kSecAttrAccessGroup] isEqual:@"NEW.default"]);
    CHECK([lost[(__bridge id)kSecAttrAccessGroup] isEqual:@"OLD.app"]);

    // Attributes alone cannot justify retrying an item-not-found query.
    NativeStatus = errSecItemNotFound;
    for (NSDictionary *query in @[plain, unknown, authorized]) {
        SeenQueries = [NSMutableArray array];
        SeenAttributes = [NSMutableArray array];
        CHECK(AsignSecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)lost) == errSecItemNotFound);
        CHECK(SeenQueries.count == 1 && SeenAttributes.count == 1);
    }

    // Preserve failures from the fallback, with no third attempt and no
    // fabricated result. Add keeps its narrower missing-entitlement retry.
    for (NSUInteger i = 0; i < sizeof(statuses) / sizeof(statuses[0]); ++i) {
        NativeRetryStatus = statuses[i];
        for (unsigned operation = 0; operation < 4; ++operation) {
            NativeStatus = operation == 0 ? errSecMissingEntitlement : errSecItemNotFound;
            SeenQueries = [NSMutableArray array];
            SeenAttributes = [NSMutableArray array];
            CFDictionaryRef raw = (__bridge CFDictionaryRef)lost;
            CFTypeRef result = NULL;
            OSStatus status;
            if (operation == 0) status = AsignSecItemAdd(raw, &result);
            else if (operation == 1) status = AsignSecItemCopyMatching(raw, &result);
            else if (operation == 2) status = AsignSecItemUpdate(raw, raw);
            else status = AsignSecItemDelete(raw);
            CHECK(status == NativeRetryStatus && SeenQueries.count == 2);
            if (operation < 2) {
                CHECK(NativeRetryStatus == errSecSuccess ? result != NULL : result == NULL);
                if (result) CFRelease(result);
            }
        }
    }
    NativeRetryStatus = errSecSuccess;

    // Unreadable signatures and absent/invalid original snapshots never
    // broaden an explicit group, even for the new item-not-found path.
    NSDictionary *savedInfo = OriginalInfo, *savedCapabilities = SignedCapabilities;
    for (unsigned scenario = 0; scenario < 4; ++scenario) {
        OriginalInfo = scenario == 0 ? savedInfo : scenario == 1 ? @{} :
            @{@"AsignOriginalKeychainAccessGroups": scenario == 2 ? @[] : @[@"*"]};
        SignedCapabilities = scenario == 0 ? nil : savedCapabilities;
        for (NSUInteger i = 0; i < sizeof(statuses) / sizeof(statuses[0]); ++i) {
            NativeStatus = statuses[i];
            for (unsigned operation = 0; operation < 4; ++operation) {
                SeenQueries = [NSMutableArray array];
                SeenAttributes = [NSMutableArray array];
                CFDictionaryRef raw = (__bridge CFDictionaryRef)lost;
                OSStatus status;
                if (operation == 0) status = AsignSecItemAdd(raw, NULL);
                else if (operation == 1) status = AsignSecItemCopyMatching(raw, NULL);
                else if (operation == 2) status = AsignSecItemUpdate(raw, raw);
                else status = AsignSecItemDelete(raw);
                CHECK(status == NativeStatus && SeenQueries.count == 1);
            }
        }
    }
    OriginalInfo = savedInfo;
    SignedCapabilities = savedCapabilities;
}

static void KeychainLifecycleChecks(void) {
    StoredItems = [NSMutableArray array];
    SeenQueries = [NSMutableArray array];
    SeenAttributes = [NSMutableArray array];
    NSData *first = [@"first" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *second = [@"second" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: @"fixture",
                            (__bridge id)kSecAttrAccount: @"account",
                            (__bridge id)kSecAttrAccessGroup: @"OLD.app"};
    NSMutableDictionary *add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = first;
    CHECK(AsignSecItemAdd((__bridge CFDictionaryRef)add, NULL) == errSecSuccess);
    CHECK(SeenQueries.count == 2 && StoredItems.count == 1);
    CHECK([StoredItems.firstObject[(__bridge id)kSecAttrAccessGroup] isEqual:@"NEW.default"]);
    CHECK([add[(__bridge id)kSecAttrAccessGroup] isEqual:@"OLD.app"]);

    NSMutableDictionary *read = [query mutableCopy];
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    CHECK(AsignSecItemCopyMatching((__bridge CFDictionaryRef)read, &result) == errSecSuccess);
    CHECK([(__bridge id)result isEqual:first]);
    if (result) CFRelease(result);

    // A duplicate write must not overwrite the existing value or reset it.
    CHECK(AsignSecItemAdd((__bridge CFDictionaryRef)add, NULL) == errSecDuplicateItem);
    NSDictionary *update = @{(__bridge id)kSecValueData: second};
    CHECK(AsignSecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update) == errSecSuccess);
    result = NULL;
    CHECK(AsignSecItemCopyMatching((__bridge CFDictionaryRef)read, &result) == errSecSuccess);
    CHECK([(__bridge id)result isEqual:second]);
    if (result) CFRelease(result);

    // Default queries retain their all-groups search. An authorized or
    // unknown explicit group cannot read or delete the remapped item.
    NSMutableDictionary *other = [read mutableCopy];
    [other removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    CHECK(AsignSecItemCopyMatching((__bridge CFDictionaryRef)other, NULL) == errSecSuccess);
    for (NSString *group in @[@"NEW.allowed", @"UNKNOWN"]) {
        other[(__bridge id)kSecAttrAccessGroup] = group;
        CHECK(AsignSecItemCopyMatching((__bridge CFDictionaryRef)other, NULL) == errSecItemNotFound);
        CHECK(AsignSecItemUpdate((__bridge CFDictionaryRef)other, (__bridge CFDictionaryRef)update) == errSecItemNotFound);
        CHECK(AsignSecItemDelete((__bridge CFDictionaryRef)other) == errSecItemNotFound);
        CHECK(StoredItems.count == 1);
    }

    // Deleting through the original group must leave a same-account item in
    // another authorized group untouched.
    NSMutableDictionary *allowed = [add mutableCopy];
    allowed[(__bridge id)kSecAttrAccessGroup] = @"NEW.allowed";
    CHECK(AsignSecItemAdd((__bridge CFDictionaryRef)allowed, NULL) == errSecSuccess);
    CHECK(StoredItems.count == 2);
    CHECK(AsignSecItemDelete((__bridge CFDictionaryRef)query) == errSecSuccess);
    CHECK(StoredItems.count == 1);
    CHECK([StoredItems.firstObject[(__bridge id)kSecAttrAccessGroup] isEqual:@"NEW.allowed"]);
    result = NULL;
    CHECK(AsignSecItemCopyMatching((__bridge CFDictionaryRef)read, &result) == errSecItemNotFound);
    CHECK(result == NULL);
    CHECK(AsignSecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update) == errSecItemNotFound);
    CHECK(AsignSecItemDelete((__bridge CFDictionaryRef)query) == errSecItemNotFound);
    CHECK(StoredItems.count == 1);
    StoredItems = nil;
}

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
    CHECK(AsignNeedsAppGroupPatch());
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
    CHECK(!AsignNeedsAppGroupPatch());
    CHECK(!AsignNeedsKeychainPatch());
    CHECK(KeychainQuery((__bridge CFDictionaryRef)lost) == lost);
    SignedCapabilities = @{@"keychain-access-groups": @[@"*"], @"application-identifier": @"NEW.app"};
    CHECK(!AsignNeedsKeychainPatch());
    SignedCapabilities = @{@"application-identifier": @"NEW.app"};
    CHECK([AsignKeychainReplacementGroup(@"OLD.app") isEqual:@"NEW.app"]);
    SignedCapabilities = @{@"com.apple.security.application-groups": @[@"*", @"group.authorized", @42]};
    CHECK(AsignAppGroupNeedsFallback(@"group.lost"));
    CHECK(!AsignAppGroupNeedsFallback(@"group.authorized"));
    CHECK([AsignInstalledAppGroups() isEqual:@[@"group.authorized"]]);
    SignedCapabilities = @{@"com.apple.security.application-groups": @"*",
                           @"keychain-access-groups": @[@"NEW.default", @42], @"application-identifier": @42};
    CHECK([AsignKeychainReplacementGroup(@"OLD.app") isEqual:@"NEW.default"]);
    SignedCapabilities = @{@"keychain-access-groups": @[@"NEW.default", @"*"]};
    CHECK(!AsignNeedsKeychainPatch());
    SignedCapabilities = @{@"com.apple.security.application-groups": @"*"};
    CHECK(AsignAppGroupNeedsFallback(@"group.lost"));
    CHECK(AsignInstalledAppGroups() == nil);
    SignedCapabilities = @{@"com.apple.security.application-groups": @[@"group.lost", @"group.authorized"]};
    CHECK(!AsignNeedsAppGroupPatch());
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

static id TestPublicDefaults(id self __attribute__((ns_consumed)), __unused SEL selector,
                             __unused NSString *suite) __attribute__((ns_returns_retained));
static id TestPublicDefaults(id self __attribute__((ns_consumed)), __unused SEL selector,
                             __unused NSString *suite) {
    return self;
}

static void InstallationChecks(void) {
    NSDictionary *savedInfo = OriginalInfo, *savedCapabilities = SignedCapabilities;
    OriginalInfo = @{@"AsignOriginalAppGroupIdentifiers": @[@"group.lost"]};
    SEL group = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    SEL internal = NSSelectorFromString(@"_initWithSuiteName:container:");
    SEL public = @selector(initWithSuiteName:);
    for (unsigned scenario = 0; scenario < 6; ++scenario) {
        Class manager = objc_allocateClassPair(NSObject.class,
            [[NSString stringWithFormat:@"AsignFixtureManager%u", scenario] UTF8String], 0);
        Class defaults = objc_allocateClassPair(NSObject.class,
            [[NSString stringWithFormat:@"AsignFixtureDefaults%u", scenario] UTF8String], 0);
        CHECK(manager && defaults);
        CHECK(class_addMethod(manager, group, (IMP)NativeGroup,
                              scenario == 4 ? "v@:@" : (scenario == 5 ? "@\"NSURL\"@:@\"NSString\"" : "@@:@")));
        if (scenario != 1) CHECK(class_addMethod(defaults, internal, (IMP)TestDefaults,
                                                scenario == 2 ? "v@:@@" : "@@:@@"));
        if (scenario != 3) CHECK(class_addMethod(defaults, public, (IMP)TestPublicDefaults, "@@:@"));
        objc_registerClassPair(manager);
        objc_registerClassPair(defaults);
        Method nativeGroup = class_getInstanceMethod(manager, group);
        Method nativeInternal = class_getInstanceMethod(defaults, internal);
        Method nativePublic = class_getInstanceMethod(defaults, public);
        IMP groupBefore = method_getImplementation(nativeGroup);
        IMP internalBefore = nativeInternal ? method_getImplementation(nativeInternal) : NULL;
        IMP publicBefore = nativePublic ? method_getImplementation(nativePublic) : NULL;
        // A conclusive original snapshot alone is not reason to swizzle a
        // working app. Unknown signatures must also leave method tables alone.
        for (id capabilities in @[@{@"com.apple.security.application-groups": @[@"group.lost"]}, NSNull.null]) {
            SignedCapabilities = capabilities == NSNull.null ? nil : capabilities;
            InstallAppGroupPatch(manager, defaults);
            CHECK(method_getImplementation(nativeGroup) == groupBefore);
            CHECK(!nativeInternal || method_getImplementation(nativeInternal) == internalBefore);
            CHECK(!nativePublic || method_getImplementation(nativePublic) == publicBefore);
        }
        // Reproduce the missing/changed-private-ABI condition: the supported
        // file API must still be repaired, without touching unsupported defaults.
        SignedCapabilities = @{};
        InstallAppGroupPatch(manager, defaults);
        CHECK(method_getImplementation(nativeGroup) == (scenario == 4 ? groupBefore : (IMP)GroupContainer));
        if (scenario == 0 || scenario == 5) {
            CHECK(method_getImplementation(nativeInternal) == (IMP)Defaults);
            CHECK(method_getImplementation(nativePublic) == (IMP)PublicDefaults);
        } else {
            CHECK(!nativeInternal || method_getImplementation(nativeInternal) == internalBefore);
            CHECK(!nativePublic || method_getImplementation(nativePublic) == publicBefore);
        }
    }
    OriginalGroupContainer = NULL;
    OriginalDefaults = NULL;
    OriginalPublicDefaults = NULL;
    OriginalInfo = savedInfo;
    SignedCapabilities = savedCapabilities;
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
    // The first listed signed group may have no registered native container.
    // A later usable group should still provide shared storage.
    NSDictionary *savedCapabilities = SignedCapabilities;
    NSMutableDictionary *capabilities = [SignedCapabilities mutableCopy];
    capabilities[@"com.apple.security.application-groups"] = @[@"group.unavailable", @"group.signed", @"group.authorized"];
    SignedCapabilities = capabilities;
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
    SignedCapabilities = savedCapabilities;
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
    NSDictionary *localized = @{@"CFBundleDisplayName": @"Fixture"};
    CHECK(IdentityView(localized, @"test.original") == localized);
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
        KeychainChecks();
        KeychainLifecycleChecks();
        InstallationChecks();
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        StorageChecks(root);
        IdentityChecks(root);
        CHECK([NSFileManager.defaultManager removeItemAtURL:root error:NULL]);
        printf("%u runtime checks passed\n", Checks);
    }
    return 0;
}
