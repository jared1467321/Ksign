// Manual macOS checks against the production CloudKit policy and wrappers.
// No CloudKit network requests or persistent-store loads are performed.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
static NSDictionary *FixtureCapabilities, *FixtureInfo;
static void *FixtureDlsym(void *, const char *);
#define dlsym FixtureDlsym
#include "../CloudKitPatch.m"
#undef dlsym

#define CHECK(expression) do { \
    if (!(expression)) { fprintf(stderr, "Failed at line %d: %s\n", __LINE__, #expression); abort(); } \
} while (0)

bool AsignInitializeLocalCloudConfiguration(__unused void *result, __unused const char *identifier) { return false; }
static CFTypeRef FixtureTask(__unused CFAllocatorRef allocator) { return CFRetain(kCFBooleanTrue); }
static CFDictionaryRef FixtureCopy(__unused CFTypeRef task, __unused CFArrayRef keys, __unused CFErrorRef *error) {
    return FixtureCapabilities ? CFBridgingRetain(FixtureCapabilities) : NULL;
}
static void *FixtureDlsym(__unused void *handle, const char *symbol) {
    if (!strcmp(symbol, "SecTaskCreateFromSelf")) return (void *)FixtureTask;
    if (!strcmp(symbol, "SecTaskCopyValuesForEntitlements")) return (void *)FixtureCopy;
    return NULL;
}
static NSDictionary *FixtureBundleInfo(__unused id self, __unused SEL selector) { return FixtureInfo; }
static id NativeEntitlement(__unused id self, __unused SEL selector, __unused id key) {
    CHECK(ConstructingLocalIdentifier == nil);
    return @"native";
}
static id LocalDatabase(__unused id self, __unused SEL selector) {
    CHECK([ConstructingLocalIdentifier isEqual:@"iCloud.lost"]);
    return [NSObject new];
}
static id NativeDatabase(__unused id self, __unused SEL selector) {
    CHECK(ConstructingLocalIdentifier == nil);
    return [NSObject new];
}
static void NativeOperation(__unused id self, __unused SEL selector, NSOperation *operation) {
    CHECK(ConstructingLocalIdentifier == nil);
    CHECK(!operation.cancelled);
}
static void LocalOperation(__unused id self, __unused SEL selector, NSOperation *operation) {
    CHECK([ConstructingLocalIdentifier isEqual:@"iCloud.lost"]);
    CHECK(operation.cancelled);
}

static void MixedChecks(void) {
    CHECK(NeedsCloudKitPatch());
    CHECK(NeedsLocal(@"iCloud.lost"));
    CHECK(!NeedsLocal(@"iCloud.allowed"));
    CHECK(!NeedsLocal(@"iCloud.unrelated"));
    CHECK(!NeedsLocal(nil));
    CHECK([DefaultIdentifier() isEqual:@"iCloud.allowed"]);
    CHECK(AsignCloudKitAutomaticBinding().original == NULL);

    NSMutableArray *stores = [NSMutableArray array];
    for (NSString *identifier in @[@"iCloud.lost", @"iCloud.allowed", @"iCloud.unrelated"]) {
        NSPersistentStoreDescription *store = [NSPersistentStoreDescription new];
        store.URL = [NSURL fileURLWithPath:[@"/tmp" stringByAppendingPathComponent:identifier]];
        store.configuration = identifier;
        store.cloudKitContainerOptions = [[NSPersistentCloudKitContainerOptions alloc] initWithContainerIdentifier:identifier];
        [stores addObject:store];
    }
    NSPersistentStoreDescription *localStore = [NSPersistentStoreDescription new];
    [stores addObject:localStore];
    NSPersistentStoreDescription *lost = stores[0], *authorized = stores[1], *unrelated = stores[2];
    id authorizedOptions = authorized.cloudKitContainerOptions, unrelatedOptions = unrelated.cloudKitContainerOptions;
    NSURL *url = lost.URL;
    PrepareLocalStores(stores);
    CHECK(lost.cloudKitContainerOptions == nil && lost.URL == url);
    CHECK([lost.configuration isEqual:@"iCloud.lost"]);
    CHECK(authorized.cloudKitContainerOptions == authorizedOptions);
    CHECK(unrelated.cloudKitContainerOptions == unrelatedOptions);
    CHECK(localStore.cloudKitContainerOptions == nil);

    NSObject *local = [NSObject new], *native = [NSObject new];
    OriginalContainerEntitlement = NativeEntitlement;
    id result = Construct(@"iCloud.lost", local, ^{
        CHECK(ConstructingLocalReceiver == local);
        // This receiver is still initializing and has not been tagged yet.
        CHECK(LocalIdentifier(local) == nil);
        CHECK([ContainerEntitlement(local, NULL, ServicesKey) containsObject:@"CloudKit"]);
        CHECK([ContainerEntitlement(native, NULL, ServicesKey) isEqual:@"native"]);
        CHECK([ConstructingLocalIdentifier isEqual:@"iCloud.lost"]);
        id database = Database(local, NULL, LocalDatabase);
        CHECK([LocalIdentifier(database) isEqual:@"iCloud.lost"]);
        id nativeDatabase = Database(native, NULL, NativeDatabase);
        CHECK(LocalIdentifier(nativeDatabase) == nil);
        CHECK(Construct(@"iCloud.allowed", native, ^{
            CHECK(ConstructingLocalIdentifier == nil && ConstructingLocalReceiver == nil);
            return native;
        }) == native);
        CHECK(ConstructingLocalReceiver == local);
        @try {
            Construct(@"iCloud.unrelated", native, ^id {
                CHECK(ConstructingLocalIdentifier == nil);
                @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
            });
            CHECK(NO);
        } @catch (NSException *exception) { CHECK([exception.name isEqual:@"Fixture"]); }
        CHECK(ConstructingLocalReceiver == local);
        Operation(native, NULL, [NSBlockOperation blockOperationWithBlock:^{}], NativeOperation);
        CHECK([ConstructingLocalIdentifier isEqual:@"iCloud.lost"]);
        return local;
    });
    CHECK(result == local && [LocalIdentifier(local) isEqual:@"iCloud.lost"]);
    CHECK(ConstructingLocalIdentifier == nil && ConstructingLocalReceiver == nil);
    CHECK(LocalIdentifier(native) == nil);
    Operation(local, NULL, [NSBlockOperation blockOperationWithBlock:^{}], LocalOperation);
    CHECK(ConstructingLocalIdentifier == nil);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        NSString *mode = @(argv[1]);
        FixtureInfo = @{@"AsignOriginalCloudContainerIdentifiers": @[@"iCloud.lost", @"iCloud.allowed"]};
        FixtureCapabilities = @{ServicesKey: @[@"CloudKit"], ContainersKey: @[@"iCloud.allowed"]};
        if ([mode isEqual:@"authorized"]) FixtureCapabilities = @{ServicesKey: @[@"CloudKit"], ContainersKey: @[@"iCloud.lost", @"iCloud.allowed"]};
        if ([mode isEqual:@"missing-snapshot"]) FixtureInfo = @{};
        if ([mode isEqual:@"empty-snapshot"]) FixtureInfo = @{@"AsignOriginalCloudContainerIdentifiers": @[]};
        if ([mode isEqual:@"invalid-snapshot"]) FixtureInfo = @{@"AsignOriginalCloudContainerIdentifiers": @42};
        if ([mode isEqual:@"unreadable"]) FixtureCapabilities = nil;
        Method info = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
        IMP previous = method_setImplementation(info, (IMP)FixtureBundleInfo);
        if ([mode isEqual:@"mixed"]) {
            MixedChecks();
        } else {
            CHECK(!NeedsCloudKitPatch());
            CHECK(!NeedsLocal(@"iCloud.lost"));
            CHECK(AsignCloudKitAutomaticBinding().original == NULL);
            Method load = class_getInstanceMethod(NSPersistentCloudKitContainer.class, @selector(loadPersistentStoresWithCompletionHandler:));
            IMP native = method_getImplementation(load);
            AsignInstallCloudKitPatch();
            CHECK(method_getImplementation(load) == native);
            CHECK(OriginalContainer == NULL && OriginalLoadPersistentStores == NULL);
        }
        method_setImplementation(info, previous);
        printf("CloudKit %s checks passed\n", argv[1]);
    }
    return 0;
}
