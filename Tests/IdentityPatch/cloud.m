#import <Foundation/Foundation.h>
#import "CloudKitPatch.h"

// The production hooks run against SDK stand-ins with the same selectors.
// Separate entitlement sources model the kernel signature and SDK caches.
static NSDictionary *SignedValues, *SDKValues;
static BOOL ThrowDuringSetup, CheckOtherThread;
static unsigned OriginalAccounts, OriginalRecords, Enqueued;
NSDictionary *AsignTestCloudEntitlements(void) { return SignedValues; }
bool AsignInitializeLocalCloudConfiguration(__unused void *result, __unused const char *identifier) { return false; }

static NSString *const Services = @"com.apple.developer.icloud-services";
static NSString *const Identifiers = @"com.apple.developer.icloud-container-identifiers";
static NSString *const Environment = @"com.apple.developer.icloud-container-environment";
static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}
static NSDictionary *allowed(NSString *identifier) {
    return @{Services: @[@"CloudKit"], Identifiers: @[identifier], Environment: @"Development", @"keep": @"value"};
}

@interface CKEntitlements : NSObject
@property(nonatomic, copy) NSDictionary *entitlementsDict;
- (instancetype)initWithEntitlementsDict:(NSDictionary *)dictionary;
- (NSArray *)cloudServices;
- (NSArray *)cloudKitContainerIdentifiers;
- (NSString *)cloudKitEnvironment;
@end
@implementation CKEntitlements
- (instancetype)initWithEntitlementsDict:(NSDictionary *)dictionary {
    self = [super init];
    if (self) _entitlementsDict = [dictionary copy];
    return self;
}
- (NSArray *)cloudServices { return _entitlementsDict[Services]; }
- (NSArray *)cloudKitContainerIdentifiers { return _entitlementsDict[Identifiers]; }
- (NSString *)cloudKitEnvironment { return _entitlementsDict[Environment]; }
@end
static CKEntitlements *Cached;

@interface CKDatabase : NSObject
@property(nonatomic) NSInteger databaseScope;
@property(nonatomic) BOOL expectsCancellation;
- (void)addOperation:(NSOperation *)operation;
- (void)_scheduleConvenienceOperation:(NSOperation *)operation;
@end
@implementation CKDatabase
- (void)addOperation:(NSOperation *)operation {
    ++Enqueued;
    check(operation.isCancelled == self.expectsCancellation, "Cloud operation cancellation did not match container permissions");
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = [NSOperationQueue new]; });
    [queue addOperation:operation];
}
- (void)_scheduleConvenienceOperation:(NSOperation *)operation { [self addOperation:operation]; }
@end

@interface CKContainer : NSObject
@property(nonatomic, copy) NSString *containerIdentifier;
@property(nonatomic) BOOL setupCalled;
@property(nonatomic, strong) NSMutableDictionary *databases;
+ (instancetype)containerWithIdentifier:(NSString *)identifier;
+ (instancetype)defaultContainer;
+ (void)_checkSelfCloudServicesEntitlement;
+ (NSString *)_checkSelfContainerIdentifier;
+ (id)_untrustedEntitlementForKey:(NSString *)key;
- (instancetype)_initWithContainerIdentifier:(NSString *)identifier;
- (instancetype)_initWithContainerIdentifier:(NSString *)identifier environment:(NSInteger)environment;
- (void)_setupWithContainerID:(id)identifier options:(id)options;
- (id)_untrustedContainerEntitlementsForKey:(NSString *)key;
- (CKDatabase *)databaseWithDatabaseScope:(NSInteger)scope;
- (CKDatabase *)privateCloudDatabase;
- (CKDatabase *)publicCloudDatabase;
- (CKDatabase *)sharedCloudDatabase;
- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger, NSError *))completion;
- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(id, NSError *))completion;
- (void)addOperation:(NSOperation *)operation;
- (void)_scheduleConvenienceOperation:(NSOperation *)operation;
@end
@implementation CKContainer
+ (instancetype)containerWithIdentifier:(NSString *)identifier { return [[self alloc] _initWithContainerIdentifier:identifier]; }
+ (instancetype)defaultContainer { return [self containerWithIdentifier:[self _checkSelfContainerIdentifier]]; }
+ (void)_checkSelfCloudServicesEntitlement {
    if (![SDKValues[Services] containsObject:@"CloudKit"]) [NSException raise:@"MissingCloudKit" format:@"Missing CloudKit service"];
}
+ (NSString *)_checkSelfContainerIdentifier { return [SDKValues[Identifiers] firstObject]; }
+ (id)_untrustedEntitlementForKey:(NSString *)key { return SDKValues[key]; }
- (instancetype)_initWithContainerIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) {
        [CKContainer _checkSelfCloudServicesEntitlement];
        NSArray *identifiers = [CKContainer _untrustedEntitlementForKey:Identifiers];
        if (![identifiers containsObject:identifier]) [NSException raise:@"UnauthorizedContainer" format:@"Missing container"];
        CKEntitlements *fresh = [[CKEntitlements alloc] initWithEntitlementsDict:SDKValues];
        check([fresh.cloudServices containsObject:@"CloudKit"], "Constructor did not receive a complete SDK entitlement view");
        check([Cached.cloudServices containsObject:@"CloudKit"], "Cached SDK entitlement accessor was not adapted");
        check([Cached.cloudKitContainerIdentifiers containsObject:identifier], "Cached container list was not adapted");
        check(fresh.cloudKitEnvironment != nil, "SDK environment was missing");
        _containerIdentifier = [identifier copy];
        _databases = [NSMutableDictionary dictionary];
        [self _setupWithContainerID:identifier options:nil];
    }
    return self;
}
- (instancetype)_initWithContainerIdentifier:(NSString *)identifier environment:(__unused NSInteger)environment {
    return [self _initWithContainerIdentifier:identifier];
}
- (void)_setupWithContainerID:(__unused id)identifier options:(__unused id)options {
    if (ThrowDuringSetup) [NSException raise:@"SetupFailure" format:@"Injected failure"];
    self.setupCalled = YES;
    if (CheckOtherThread) {
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            check([CKContainer _untrustedEntitlementForKey:Identifiers] == SDKValues[Identifiers],
                  "Local construction entitlement view leaked to another thread");
        });
    }
}
- (id)_untrustedContainerEntitlementsForKey:(NSString *)key { return SDKValues[key]; }
- (CKDatabase *)databaseWithDatabaseScope:(NSInteger)scope {
    check(self.setupCalled, "Partial container setup reached a database getter");
    if (!self.databases[@(scope)]) {
        CKDatabase *database = [CKDatabase new]; database.databaseScope = scope; self.databases[@(scope)] = database;
    }
    return self.databases[@(scope)];
}
- (CKDatabase *)privateCloudDatabase { return [self databaseWithDatabaseScope:2]; }
- (CKDatabase *)publicCloudDatabase { return [self databaseWithDatabaseScope:1]; }
- (CKDatabase *)sharedCloudDatabase { return [self databaseWithDatabaseScope:3]; }
- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger, NSError *))completion { ++OriginalAccounts; completion(1, nil); }
- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(id, NSError *))completion { ++OriginalRecords; completion(@"real-user", nil); }
- (void)addOperation:(NSOperation *)operation { [self.privateCloudDatabase addOperation:operation]; }
- (void)_scheduleConvenienceOperation:(NSOperation *)operation { [self addOperation:operation]; }
@end

static void waitForCallback(dispatch_semaphore_t semaphore) {
    check(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, "Callback never completed");
}
int main(void) {
    @autoreleasepool {
        NSString *real = @"iCloud.org.example.real", *unavailable = @"iCloud.org.example.original";
        SignedValues = SDKValues = allowed(real);
        Cached = [[CKEntitlements alloc] initWithEntitlementsDict:SDKValues];
        AsignInstallCloudKitPatch();

        CKContainer *valid = [CKContainer containerWithIdentifier:real];
        check(valid && valid.setupCalled, "Authorized container was not fully initialized");
        [valid accountStatusWithCompletionHandler:^(NSInteger status, NSError *error) { check(status == 1 && !error, "Authorized account changed"); }];
        [valid fetchUserRecordIDWithCompletionHandler:^(id record, NSError *error) { check([record isEqual:@"real-user"] && !error, "Authorized cloud request changed"); }];
        check(OriginalAccounts == 1 && OriginalRecords == 1, "Authorized requests bypassed original SDK methods");
        dispatch_semaphore_t authorizedOperation = dispatch_semaphore_create(0);
        NSBlockOperation *allowedOperation = [NSBlockOperation blockOperationWithBlock:^{ dispatch_semaphore_signal(authorizedOperation); }];
        [valid.privateCloudDatabase addOperation:allowedOperation];
        waitForCallback(authorizedOperation);
        check(!allowedOperation.isCancelled, "An authorized cloud operation was cancelled");
        CKEntitlements *unchanged = [[CKEntitlements alloc] initWithEntitlementsDict:SDKValues];
        check([unchanged.entitlementsDict isEqual:SDKValues], "Authorized cloud entitlements were stripped");

        // A CloudKit-capable profile does not authorize every container. One
        // unavailable identifier must not disable another permitted one.
        CKContainer *other = [CKContainer containerWithIdentifier:@"iCloud.org.another.application"];
        dispatch_semaphore_t otherAccount = dispatch_semaphore_create(0);
        [other accountStatusWithCompletionHandler:^(NSInteger status, NSError *error) {
            check(status == 2 && !error, "A different container was incorrectly authorized");
            dispatch_semaphore_signal(otherAccount);
        }];
        waitForCallback(otherAccount);
        check([CKContainer containerWithIdentifier:real].setupCalled, "Unavailable container changed permitted container initialization");
        check([Cached.cloudServices containsObject:@"CloudKit"] &&
              [Cached.cloudKitContainerIdentifiers isEqual:@[real]], "SDK permissions leaked between containers");

        SignedValues = SDKValues = @{};
        Cached = [[CKEntitlements alloc] initWithEntitlementsDict:SDKValues];
        CheckOtherThread = YES;
        CKContainer *local = [CKContainer containerWithIdentifier:unavailable];
        check(local && local.setupCalled && [local.containerIdentifier isEqual:unavailable], "Local container was null or partially initialized");
        check(local.privateCloudDatabase && local.sharedCloudDatabase && local.publicCloudDatabase, "Local database objects were missing");
        check(local.privateCloudDatabase == local.privateCloudDatabase, "Local database identity changed");
        check(![Cached.cloudServices containsObject:@"CloudKit"] && SDKValues.count == 0, "Signed capabilities or SDK cache were mutated");
        check([local _untrustedContainerEntitlementsForKey:Identifiers] != nil, "Later local container checks lost construction context");
        check([CKContainer defaultContainer] != nil, "Default container fallback did not use the original snapshot");
        check([[CKContainer alloc] _initWithContainerIdentifier:unavailable environment:1] != nil, "Environment initializer lost fallback");

        dispatch_semaphore_t account = dispatch_semaphore_create(0), record = dispatch_semaphore_create(0);
        [local accountStatusWithCompletionHandler:^(NSInteger status, NSError *error) {
            check(status == 2 && !error, "Local account incorrectly advertised cloud availability"); dispatch_semaphore_signal(account);
        }];
        [local fetchUserRecordIDWithCompletionHandler:^(id value, NSError *error) {
            check(!value && [error.domain isEqual:@"CKErrorDomain"] && error.code == 9, "Local request did not report cloud unavailability"); dispatch_semaphore_signal(record);
        }];
        waitForCallback(account); waitForCallback(record);
        check(OriginalAccounts == 1 && OriginalRecords == 1, "Local requests reached cloud account services");
        dispatch_semaphore_t operations = dispatch_semaphore_create(0);
        unsigned enqueuedBeforeLocal = Enqueued;
        for (CKDatabase *database in @[local.privateCloudDatabase, local.publicCloudDatabase, local.sharedCloudDatabase]) {
            database.expectsCancellation = YES;
            NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{ check(NO, "Cancelled cloud operation executed"); }];
            operation.completionBlock = ^{ dispatch_semaphore_signal(operations); };
            [database addOperation:operation];
        }
        NSOperation *containerOperation = [NSBlockOperation blockOperationWithBlock:^{ check(NO, "Container cloud operation executed"); }];
        containerOperation.completionBlock = ^{ dispatch_semaphore_signal(operations); };
        [local _scheduleConvenienceOperation:containerOperation];
        for (unsigned i = 0; i < 4; ++i) waitForCallback(operations);
        check(Enqueued == enqueuedBeforeLocal + 4, "Cancelled operations were dropped instead of being queued for completion");

        ThrowDuringSetup = YES;
        BOOL threw = NO;
        @try { [CKContainer containerWithIdentifier:unavailable]; } @catch (__unused NSException *error) { threw = YES; }
        ThrowDuringSetup = NO;
        check(threw && [CKContainer _untrustedEntitlementForKey:Identifiers] == nil, "Construction context survived an exception");

        SignedValues = nil; SDKValues = allowed(real);
        Cached = [[CKEntitlements alloc] initWithEntitlementsDict:SDKValues];
        CKContainer *unknown = [CKContainer containerWithIdentifier:real];
        [unknown accountStatusWithCompletionHandler:^(NSInteger status, NSError *error) { check(status == 1 && !error, "Unknown capability state was treated as denied"); }];
        check(OriginalAccounts == 2, "Unknown state did not preserve SDK behavior");
        printf("Conditional CloudKit access, full initialization, local database identity, callbacks and construction isolation passed\n");
    }
    return 0;
}
