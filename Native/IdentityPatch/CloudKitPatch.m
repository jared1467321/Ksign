#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "CloudKitPatch.h"
#import "CloudKitABI.h"
#import "MethodHook.h"

__attribute__((used, visibility("default")))
const char AsignCloudKitPatchVersion[] = "AsignCloudKitPatch/v1";

static NSString *const ServicesKey = @"com.apple.developer.icloud-services";
static NSString *const ContainersKey = @"com.apple.developer.icloud-container-identifiers";
static NSString *const EnvironmentKey = @"com.apple.developer.icloud-container-environment";
static char LocalIdentifierKey;
// Only synchronous SDK construction sees this view. Other threads and the
// Security entitlement APIs continue to see the real signed capabilities.
static _Thread_local __unsafe_unretained NSString *ConstructingLocalIdentifier;
static _Thread_local __unsafe_unretained id ConstructingLocalReceiver;

typedef id (*ObjectGetter)(id, SEL);
typedef id (*ObjectArgument)(id, SEL, id);
typedef id (*Initializer)(id __attribute__((ns_consumed)), SEL, id) __attribute__((ns_returns_retained));
typedef id (*EnvironmentInitializer)(id __attribute__((ns_consumed)), SEL, id, NSInteger) __attribute__((ns_returns_retained));
typedef id (*OptionsInitializer)(id __attribute__((ns_consumed)), SEL, id, id) __attribute__((ns_returns_retained));
typedef void (*OperationMethod)(id, SEL, NSOperation *);
typedef void (^StoreCompletion)(NSPersistentStoreDescription *, NSError *);
static ObjectArgument OriginalContainer, OriginalEntitlement, OriginalContainerEntitlement;
static ObjectGetter OriginalDefault, OriginalDefaultIdentifier;
static Initializer OriginalInit, OriginalPublicInit, OriginalEntitlementsInit;
static EnvironmentInitializer OriginalEnvironmentInit;
static OptionsInitializer OriginalOptionsInit;
static void (*OriginalCheckServices)(id, SEL);
static void (*OriginalAccountStatus)(id, SEL, void (^)(NSInteger, NSError *));
static void (*OriginalUserRecord)(id, SEL, void (^)(id, NSError *));
static ObjectGetter OriginalPrivateDatabase, OriginalPublicDatabase, OriginalSharedDatabase;
static id (*OriginalDatabaseScope)(id, SEL, NSInteger);
static OperationMethod OriginalContainerOperation, OriginalContainerConvenience;
static OperationMethod OriginalDatabaseOperation, OriginalDatabaseConvenience;
static void (*OriginalLoadPersistentStores)(NSPersistentCloudKitContainer *, SEL, StoreCompletion);
static void (*OriginalLoadStoreDescriptions)(NSPersistentCloudKitContainer *, SEL, NSArray *, StoreCompletion);
static struct {
    const char *name;
    NSString *key;
    ObjectGetter original;
} EntitlementGetters[] = {
    {"cloudServices", @"com.apple.developer.icloud-services", NULL},
    {"cloudKitContainerIdentifiers", @"com.apple.developer.icloud-container-identifiers", NULL},
    {"entitlementsDict", nil, NULL},
    {"entitlements", nil, NULL}
};
static AsignCloudAutomaticGetter OriginalAutomatic;

static id Object(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = receiver ? class_getInstanceMethod(object_getClass(receiver), selector) : NULL;
    return AsignMethodMatches(method, "@", NULL, NULL) ? ((ObjectGetter)objc_msgSend)(receiver, selector) : nil;
}

static NSDictionary *SignedEntitlements(void) {
    static NSDictionary *entitlements;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // SecTask is not exposed by all iOS SDK headers. Resolve the API rather
        // than introducing an unavailable device import. Read the running
        // process's signature, never the profile or our SDK compatibility view.
        CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        CFDictionaryRef (*copy)(CFTypeRef, CFArrayRef, CFErrorRef *) =
            dlsym(RTLD_DEFAULT, "SecTaskCopyValuesForEntitlements");
        if (!create || !copy) return;
        CFTypeRef task = create(kCFAllocatorDefault);
        if (!task) return;
        NSArray *keys = @[ServicesKey, ContainersKey, EnvironmentKey];
        CFErrorRef error = NULL;
        CFDictionaryRef values = copy(task, (__bridge CFArrayRef)keys, &error);
        if (values && !error && CFGetTypeID(values) == CFDictionaryGetTypeID()) {
            entitlements = [(__bridge NSDictionary *)values copy];
        }
        if (values) CFRelease(values);
        if (error) CFRelease(error);
        CFRelease(task);
    });
    return entitlements;
}

static BOOL ValidIdentifier(id identifier) {
    if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:@"iCloud."] || [identifier length] <= 7) return NO;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [[NSCharacterSet characterSetWithCharactersInString:
                    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"] invertedSet];
    });
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL Authorized(NSDictionary *entitlements, NSString *identifier) {
    id services = entitlements[ServicesKey], containers = entitlements[ContainersKey];
    return [services isKindOfClass:NSArray.class] && [services containsObject:@"CloudKit"] &&
        [containers isKindOfClass:NSArray.class] && [containers containsObject:identifier];
}

static NSArray *OriginalContainers(void) {
    id identifiers = NSBundle.mainBundle.infoDictionary[@"AsignOriginalCloudContainerIdentifiers"];
    if (![identifiers isKindOfClass:NSArray.class]) return nil;
    for (id identifier in identifiers) if (!ValidIdentifier(identifier)) return nil;
    return identifiers;
}

static BOOL NeedsLocal(NSString *identifier) {
    NSDictionary *signedValues = SignedEntitlements();
    // Enabling this family for one lost container is not permission to change
    // arbitrary container requests or turn unrelated Core Data stores local.
    return signedValues && ValidIdentifier(identifier) &&
        [OriginalContainers() containsObject:identifier] && !Authorized(signedValues, identifier);
}

static BOOL NeedsCloudKitPatch(void) {
    // Installing a forwarding swizzle still changes the SDK's method tables.
    // Require evidence of lost CloudKit capabilities before touching them.
    // Empty, missing and malformed original-container snapshots never
    // establish that need. A failed signature read is also inconclusive.
    NSArray *originals = OriginalContainers();
    if (!originals.count) return NO;
    NSDictionary *signedValues = SignedEntitlements();
    if (![signedValues isKindOfClass:NSDictionary.class]) return NO;
    // A readable signature can contain provisioning-profile values such as
    // icloud-services = "*". That is not a usable CloudKit service array, not
    // an unknown signature. Use the same exact authorization rule as each
    // request so unusable signed values enable the fallback instead of
    // disabling every hook. Wildcards never grant container access here.
    for (NSString *identifier in originals) if (!Authorized(signedValues, identifier)) return YES;
    return NO;
}

static NSString *DefaultIdentifier(void) {
    NSDictionary *signedValues = SignedEntitlements();
    if (!signedValues) return nil;
    id containers = signedValues[ContainersKey];
    if ([containers isKindOfClass:NSArray.class]) {
        for (id identifier in containers) {
            if (ValidIdentifier(identifier) && Authorized(signedValues, identifier)) return identifier;
        }
    }
    return [OriginalContainers() firstObject];
}

static NSDictionary *ConstructionEntitlements(NSDictionary *original) {
    NSString *identifier = ConstructingLocalIdentifier;
    if (!identifier || (original && ![original isKindOfClass:NSDictionary.class])) return original;
    NSMutableDictionary *view = original ? [original mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *signedValues = SignedEntitlements();
    id containers = view[ContainersKey];
    NSMutableArray *identifiers = [containers isKindOfClass:NSArray.class] ? [containers mutableCopy] : [NSMutableArray array];
    id permittedContainers = signedValues[ContainersKey];
    if ([permittedContainers isKindOfClass:NSArray.class]) {
        for (id permitted in permittedContainers) if (![identifiers containsObject:permitted]) [identifiers addObject:permitted];
    }
    if (![identifiers containsObject:identifier]) [identifiers addObject:identifier];
    view[ContainersKey] = identifiers;
    id services = view[ServicesKey];
    NSMutableArray *enabled = [services isKindOfClass:NSArray.class] ? [services mutableCopy] : [NSMutableArray array];
    id permittedServices = signedValues[ServicesKey];
    if ([permittedServices isKindOfClass:NSArray.class]) {
        for (id permitted in permittedServices) if (![enabled containsObject:permitted]) [enabled addObject:permitted];
    }
    if (![enabled containsObject:@"CloudKit"]) [enabled addObject:@"CloudKit"];
    view[ServicesKey] = enabled;
    if ([signedValues[EnvironmentKey] isKindOfClass:NSString.class]) view[EnvironmentKey] = signedValues[EnvironmentKey];
    else if (![view[EnvironmentKey] isKindOfClass:NSString.class]) view[EnvironmentKey] = @"Production";
    return [view copy];
}

static id Construct(NSString *identifier, id receiver, id (^original)(void)) {
    BOOL local = NeedsLocal(identifier);
    NSString *previous = ConstructingLocalIdentifier;
    id previousReceiver = ConstructingLocalReceiver;
    ConstructingLocalIdentifier = local ? identifier : nil;
    ConstructingLocalReceiver = local ? receiver : nil;
    @try {
        // Always use the real SDK initializer and its real database objects.
        // Skipping setup or returning an NSObject substitute breaks Swift and
        // CKSyncEngine before they even get a chance to check account status.
        id container = original();
        if (local && container) objc_setAssociatedObject(container, &LocalIdentifierKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return container;
    } @finally {
        ConstructingLocalIdentifier = previous;
        ConstructingLocalReceiver = previousReceiver;
    }
}

extern bool AsignInitializeLocalCloudConfiguration(void *destination, const char *identifier);
static void __attribute__((swiftcall)) Automatic(void *result __attribute__((swift_indirect_result))) {
    NSString *identifier = DefaultIdentifier();
    if (identifier && NeedsLocal(identifier) &&
        AsignInitializeLocalCloudConfiguration(result, identifier.UTF8String)) return;
    OriginalAutomatic(result);
}

AsignIdentityBinding AsignCloudKitAutomaticBinding(void) {
    // Even a forwarding import replacement is unnecessary when .automatic can
    // use a signed container. Keep that import pointing at the real getter.
    if (!NeedsCloudKitPatch() || !NeedsLocal(DefaultIdentifier())) return (AsignIdentityBinding){0};
    const char *symbol = "$s9SwiftData18ModelConfigurationV16CloudKitDatabaseV9automaticAEvgZ";
    OriginalAutomatic = dlsym(RTLD_DEFAULT, symbol);
    return (AsignIdentityBinding){symbol, (void *)OriginalAutomatic, (void *)Automatic, 0};
}

static id Container(id cls, SEL selector, NSString *identifier) {
    return Construct(identifier, nil, ^{ return OriginalContainer(cls, selector, identifier); });
}
static id DefaultContainer(id cls, SEL selector) {
    NSString *identifier = DefaultIdentifier();
    if (NeedsLocal(identifier) && OriginalContainer) {
        return Construct(identifier, nil, ^{ return OriginalContainer(cls, @selector(containerWithIdentifier:), identifier); });
    }
    return OriginalDefault(cls, selector);
}
static id Init(id self __attribute__((ns_consumed)), SEL selector, NSString *identifier) __attribute__((ns_returns_retained));
static id Init(id self __attribute__((ns_consumed)), SEL selector, NSString *identifier) {
    return Construct(identifier, self, ^{ return OriginalInit(self, selector, identifier); });
}
static id PublicInit(id self __attribute__((ns_consumed)), SEL selector, NSString *identifier) __attribute__((ns_returns_retained));
static id PublicInit(id self __attribute__((ns_consumed)), SEL selector, NSString *identifier) {
    return Construct(identifier, self, ^{ return OriginalPublicInit(self, selector, identifier); });
}
static id EnvironmentInit(id self __attribute__((ns_consumed)), SEL selector, NSString *identifier, NSInteger environment) __attribute__((ns_returns_retained));
static id EnvironmentInit(id self __attribute__((ns_consumed)), SEL selector, NSString *identifier, NSInteger environment) {
    return Construct(identifier, self, ^{ return OriginalEnvironmentInit(self, selector, identifier, environment); });
}
static id OptionsInit(id self __attribute__((ns_consumed)), SEL selector, id containerID, id options) __attribute__((ns_returns_retained));
static id OptionsInit(id self __attribute__((ns_consumed)), SEL selector, id containerID, id options) {
    return Construct(Object(containerID, @"containerIdentifier"), self, ^{ return OriginalOptionsInit(self, selector, containerID, options); });
}

static NSString *LocalIdentifier(id containerOrDatabase) {
    return objc_getAssociatedObject(containerOrDatabase, &LocalIdentifierKey);
}

static NSString *ReceiverIdentifier(id receiver) {
    // An initializer may ask its own instance for entitlements/databases before
    // Construct has returned and tagged it. Preserve that exact receiver's
    // construction scope, without lending it to another container on the thread.
    return LocalIdentifier(receiver) ?: (receiver && receiver == ConstructingLocalReceiver ? ConstructingLocalIdentifier : nil);
}

static id EntitlementsInit(id self __attribute__((ns_consumed)), SEL selector, NSDictionary *values) __attribute__((ns_returns_retained));
static id EntitlementsInit(id self __attribute__((ns_consumed)), SEL selector, NSDictionary *values) {
    return OriginalEntitlementsInit(self, selector, ConstructionEntitlements(values));
}
static void CheckServices(id cls, SEL selector) {
    if (!ConstructingLocalIdentifier) OriginalCheckServices(cls, selector);
}
static id CheckDefaultIdentifier(id cls, SEL selector) {
    return ConstructingLocalIdentifier ?: OriginalDefaultIdentifier(cls, selector);
}
static id Entitlement(id cls, SEL selector, NSString *key) {
    if (ConstructingLocalIdentifier) {
        id value = ConstructionEntitlements(SignedEntitlements())[key];
        if (value) return value;
    }
    return OriginalEntitlement(cls, selector, key);
}
static id ContainerEntitlement(id self, SEL selector, NSString *key) {
    NSString *previous = ConstructingLocalIdentifier;
    ConstructingLocalIdentifier = ReceiverIdentifier(self);
    @try {
        if (ConstructingLocalIdentifier) {
            id value = ConstructionEntitlements(SignedEntitlements())[key];
            if (value) return value;
        }
        return OriginalContainerEntitlement(self, selector, key);
    } @finally { ConstructingLocalIdentifier = previous; }
}

static id EntitlementGetter(id self, SEL selector) {
    for (size_t i = 0; i < sizeof(EntitlementGetters) / sizeof(EntitlementGetters[0]); ++i) {
        if (strcmp(sel_getName(selector), EntitlementGetters[i].name)) continue;
        ObjectGetter original = EntitlementGetters[i].original;
        if (!ConstructingLocalIdentifier) return original(self, selector);
        NSString *key = EntitlementGetters[i].key;
        id raw = original(self, selector);
        if (!key) return ConstructionEntitlements(raw);
        id value = ConstructionEntitlements(SignedEntitlements())[key];
        // Some SDK versions expose a set rather than the entitlement's array.
        return [raw isKindOfClass:NSSet.class] && [value isKindOfClass:NSArray.class]
            ? [NSSet setWithArray:value] : value;
    }
    return nil;
}

static id Database(id container, SEL selector, ObjectGetter original) {
    NSString *identifier = ReceiverIdentifier(container), *previous = ConstructingLocalIdentifier;
    ConstructingLocalIdentifier = identifier;
    @try {
        id database = original(container, selector);
        if (identifier && database) objc_setAssociatedObject(database, &LocalIdentifierKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return database;
    } @finally { ConstructingLocalIdentifier = previous; }
}
static id PrivateDatabase(id self, SEL selector) { return Database(self, selector, OriginalPrivateDatabase); }
static id PublicDatabase(id self, SEL selector) { return Database(self, selector, OriginalPublicDatabase); }
static id SharedDatabase(id self, SEL selector) { return Database(self, selector, OriginalSharedDatabase); }
static id DatabaseScope(id self, SEL selector, NSInteger scope) {
    NSString *identifier = ReceiverIdentifier(self), *previous = ConstructingLocalIdentifier;
    ConstructingLocalIdentifier = identifier;
    @try {
        id database = OriginalDatabaseScope(self, selector, scope);
        if (identifier && database) objc_setAssociatedObject(database, &LocalIdentifierKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return database;
    } @finally { ConstructingLocalIdentifier = previous; }
}

static void AccountStatus(id self, SEL selector, void (^completion)(NSInteger, NSError *)) {
    if (!LocalIdentifier(self)) { OriginalAccountStatus(self, selector, completion); return; }
    // CKAccountStatusRestricted. The container is usable for local setup but
    // cannot sync under this signature. Do not claim a successful cloud login.
    if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(2, nil); });
}
static void UserRecord(id self, SEL selector, void (^completion)(id, NSError *)) {
    if (!LocalIdentifier(self)) { OriginalUserRecord(self, selector, completion); return; }
    // CKErrorNotAuthenticated. Complete asynchronous callers exactly once.
    NSError *error = [NSError errorWithDomain:@"CKErrorDomain" code:9 userInfo:@{
        NSLocalizedDescriptionKey: @"CloudKit is unavailable for this container under the installed signature."}];
    if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(nil, error); });
}
static void Operation(id self, SEL selector, NSOperation *operation, OperationMethod original) {
    NSString *identifier = LocalIdentifier(self), *previous = ConstructingLocalIdentifier;
    if (identifier) [operation cancel];
    ConstructingLocalIdentifier = identifier;
    @try {
        // Let CloudKit own queuing, cancellation and completion delivery. Simply
        // dropping the operation leaves Swift continuations suspended forever.
        original(self, selector, operation);
    } @finally { ConstructingLocalIdentifier = previous; }
}
static void ContainerOperation(id self, SEL selector, NSOperation *operation) { Operation(self, selector, operation, OriginalContainerOperation); }
static void ContainerConvenience(id self, SEL selector, NSOperation *operation) { Operation(self, selector, operation, OriginalContainerConvenience); }
static void DatabaseOperation(id self, SEL selector, NSOperation *operation) { Operation(self, selector, operation, OriginalDatabaseOperation); }
static void DatabaseConvenience(id self, SEL selector, NSOperation *operation) { Operation(self, selector, operation, OriginalDatabaseConvenience); }

static void PrepareLocalStores(NSArray<NSPersistentStoreDescription *> *descriptions) {
    // Core Data can initialize CloudKit (including its logging/entitlement
    // checks) before it constructs a CKContainer. Handle unavailable stores
    // before that path starts, instead of catching an exception and retrying a
    // partially loaded container. Keep each store and its local options intact.
    for (NSPersistentStoreDescription *description in descriptions) {
        if (NeedsLocal(description.cloudKitContainerOptions.containerIdentifier)) {
            description.cloudKitContainerOptions = nil;
        }
    }
}

static void LoadPersistentStores(NSPersistentCloudKitContainer *self, SEL selector, StoreCompletion completion) {
    PrepareLocalStores(self.persistentStoreDescriptions);
    // Preserve Core Data's own loading, errors and asynchronous callbacks.
    OriginalLoadPersistentStores(self, selector, completion);
}

static void LoadStoreDescriptions(NSPersistentCloudKitContainer *self, SEL selector,
                                  NSArray *descriptions, StoreCompletion completion) {
    // SwiftData's CoreDataSPI load: can call NSPersistentContainer's public
    // implementation directly, bypassing our subclass override. Intercept the
    // cloud subclass's internal entry before it constructs a mirroring delegate.
    // Use the actual argument: it need not be self.persistentStoreDescriptions.
    PrepareLocalStores(descriptions);
    OriginalLoadStoreDescriptions(self, selector, descriptions, completion);
}

static void InstallStoreDescriptionsHook(void) {
    Class cls = NSPersistentCloudKitContainer.class;
    AsignHookMethod(cls, NSSelectorFromString(@"_loadStoreDescriptions:withCompletionHandler:"),
                    (IMP)LoadStoreDescriptions, (IMP *)&OriginalLoadStoreDescriptions, "v", "@", "@?");
}

void AsignInstallCloudKitPatch(void) {
    // Check before dispatch_once and class lookup: apps that did not use
    // CloudKit, authorized apps and unknown snapshots get no SDK swizzles.
    if (!NeedsCloudKitPatch()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class container = NSClassFromString(@"CKContainer"), meta = object_getClass(container);
        Class entitlements = NSClassFromString(@"CKEntitlements"), database = NSClassFromString(@"CKDatabase");
#define INSTALL(cls, name, replacement, original, type, first, second) \
        AsignHookMethod(cls, NSSelectorFromString(@name), (IMP)replacement, (IMP *)&original, type, first, second)
        INSTALL(meta, "containerWithIdentifier:", Container, OriginalContainer, "@", "@", NULL);
        INSTALL(meta, "defaultContainer", DefaultContainer, OriginalDefault, "@", NULL, NULL);
        INSTALL(container, "_initWithContainerIdentifier:", Init, OriginalInit, "@", "@", NULL);
        INSTALL(container, "initWithContainerIdentifier:", PublicInit, OriginalPublicInit, "@", "@", NULL);
        INSTALL(container, "_initWithContainerIdentifier:environment:", EnvironmentInit, OriginalEnvironmentInit, "@", "@", @encode(NSInteger));
        INSTALL(container, "initWithContainerID:options:", OptionsInit, OriginalOptionsInit, "@", "@", "@");
        INSTALL(entitlements, "initWithEntitlementsDict:", EntitlementsInit, OriginalEntitlementsInit, "@", "@", NULL);
        INSTALL(meta, "_checkSelfCloudServicesEntitlement", CheckServices, OriginalCheckServices, "v", NULL, NULL);
        INSTALL(meta, "_checkSelfContainerIdentifier", CheckDefaultIdentifier, OriginalDefaultIdentifier, "@", NULL, NULL);
        INSTALL(meta, "_untrustedEntitlementForKey:", Entitlement, OriginalEntitlement, "@", "@", NULL);
        INSTALL(container, "_untrustedContainerEntitlementsForKey:", ContainerEntitlement, OriginalContainerEntitlement, "@", "@", NULL);
        INSTALL(container, "privateCloudDatabase", PrivateDatabase, OriginalPrivateDatabase, "@", NULL, NULL);
        INSTALL(container, "publicCloudDatabase", PublicDatabase, OriginalPublicDatabase, "@", NULL, NULL);
        INSTALL(container, "sharedCloudDatabase", SharedDatabase, OriginalSharedDatabase, "@", NULL, NULL);
        INSTALL(container, "databaseWithDatabaseScope:", DatabaseScope, OriginalDatabaseScope, "@", @encode(NSInteger), NULL);
        INSTALL(container, "accountStatusWithCompletionHandler:", AccountStatus, OriginalAccountStatus, "v", "@?", NULL);
        INSTALL(container, "fetchUserRecordIDWithCompletionHandler:", UserRecord, OriginalUserRecord, "v", "@?", NULL);
        INSTALL(container, "addOperation:", ContainerOperation, OriginalContainerOperation, "v", "@", NULL);
        INSTALL(container, "_scheduleConvenienceOperation:", ContainerConvenience, OriginalContainerConvenience, "v", "@", NULL);
        INSTALL(database, "addOperation:", DatabaseOperation, OriginalDatabaseOperation, "v", "@", NULL);
        INSTALL(database, "_scheduleConvenienceOperation:", DatabaseConvenience, OriginalDatabaseConvenience, "v", "@", NULL);
        INSTALL(NSPersistentCloudKitContainer.class, "loadPersistentStoresWithCompletionHandler:",
                LoadPersistentStores, OriginalLoadPersistentStores, "v", "@?", NULL);
        InstallStoreDescriptionsHook();
#undef INSTALL
        for (size_t i = 0; i < sizeof(EntitlementGetters) / sizeof(EntitlementGetters[0]); ++i) {
            AsignHookMethod(entitlements, sel_registerName(EntitlementGetters[i].name), (IMP)EntitlementGetter,
                            (IMP *)&EntitlementGetters[i].original, "@", NULL, NULL);
        }
    });
}
