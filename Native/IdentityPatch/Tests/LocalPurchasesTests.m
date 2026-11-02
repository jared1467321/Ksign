#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "PurchasePatch.h"
#include <assert.h>

static BOOL AppCaller = YES;
BOOL AsignPatchCallerIsApp(const void *caller) { (void)caller; return AppCaller; }
static NSUserDefaults *Defaults;
static id TestDefaults(id self, SEL selector) { (void)self; (void)selector; return Defaults; }
static NSURL *TestSupport;
static NSArray *(*OriginalDirectories)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask);
static NSArray *TestDirectories(id self, SEL selector, NSSearchPathDirectory directory, NSSearchPathDomainMask domain) {
    return directory == NSApplicationSupportDirectory ? @[TestSupport] : OriginalDirectories(self, selector, directory, domain);
}

// StoreKit-shaped objects exercise the shipping hooks without StoreKit, an
// account, a device, a payment prompt, or any network connection.
@interface SKProduct : NSObject
@property(nonatomic, readonly) NSString *productIdentifier;
@property(nonatomic, readonly) NSString *localizedTitle;
@property(nonatomic, readonly) NSString *localizedDescription;
@property(nonatomic, readonly) NSDecimalNumber *price;
@property(nonatomic, readonly) NSLocale *priceLocale;
@end
@implementation SKProduct
- (NSString *)productIdentifier { return nil; }
- (NSString *)localizedTitle { return nil; }
- (NSString *)localizedDescription { return nil; }
- (NSDecimalNumber *)price { return nil; }
- (NSLocale *)priceLocale { return nil; }
@end

@interface SKProductsResponse : NSObject
@property(nonatomic, readonly) NSArray *products;
@property(nonatomic, readonly) NSArray *invalidProductIdentifiers;
@end
@implementation SKProductsResponse
- (NSArray *)products { return nil; }
- (NSArray *)invalidProductIdentifiers { return nil; }
@end

static NSUInteger NativeStarts, NativePayments, NativeFinishes, NativeRestores;
@interface SKRequest : NSObject
@property(nonatomic, weak) id delegate;
- (void)start;
- (void)cancel;
@end
@implementation SKRequest
- (void)start { ++NativeStarts; }
- (void)cancel {}
@end
@interface SKProductsRequest : SKRequest
- (instancetype)initWithProductIdentifiers:(NSSet *)identifiers;
@end
@implementation SKProductsRequest
- (instancetype)initWithProductIdentifiers:(NSSet *)identifiers { (void)identifiers; return [super init]; }
@end
@interface SKReceiptRefreshRequest : SKRequest
@end
@implementation SKReceiptRefreshRequest
@end

@interface SKPayment : NSObject
+ (instancetype)paymentWithProduct:(SKProduct *)product;
@end
@implementation SKPayment
+ (instancetype)paymentWithProduct:(SKProduct *)product { (void)product; return [self new]; }
@end
@interface SKMutablePayment : SKPayment
@property(nonatomic, copy) NSString *productIdentifier;
@property(nonatomic) NSInteger quantity;
@end
@implementation SKMutablePayment
@end
@interface SKPaymentTransaction : NSObject
@property(nonatomic, readonly) SKMutablePayment *payment;
@property(nonatomic, readonly) NSInteger transactionState;
@property(nonatomic, readonly) NSString *transactionIdentifier;
@property(nonatomic, readonly) NSString *matchingIdentifier;
@property(nonatomic, readonly) NSDate *transactionDate;
@property(nonatomic, readonly) NSData *transactionReceipt;
@property(nonatomic, readonly) id originalTransaction;
@property(nonatomic, readonly) NSError *error;
@property(nonatomic, readonly) NSArray *downloads;
@end
@implementation SKPaymentTransaction
- (SKMutablePayment *)payment { return nil; }
- (NSInteger)transactionState { return 0; }
- (NSString *)transactionIdentifier { return nil; }
- (NSString *)matchingIdentifier { return nil; }
- (NSDate *)transactionDate { return nil; }
- (NSData *)transactionReceipt { return nil; }
- (id)originalTransaction { return nil; }
- (NSError *)error { return nil; }
- (NSArray *)downloads { return nil; }
@end
@interface SKPaymentQueue : NSObject
@property(nonatomic, readonly) NSArray *transactions;
+ (BOOL)canMakePayments;
- (void)addPayment:(SKMutablePayment *)payment;
- (void)addTransactionObserver:(id)observer;
- (void)removeTransactionObserver:(id)observer;
- (void)finishTransaction:(id)transaction;
- (void)restoreCompletedTransactions;
- (void)restoreCompletedTransactionsWithApplicationUsername:(NSString *)user;
@end
@implementation SKPaymentQueue
+ (BOOL)canMakePayments { return NO; }
- (NSArray *)transactions { return @[]; }
- (void)addPayment:(SKMutablePayment *)payment { (void)payment; ++NativePayments; }
- (void)addTransactionObserver:(id)observer { (void)observer; }
- (void)removeTransactionObserver:(id)observer { (void)observer; }
- (void)finishTransaction:(id)transaction { (void)transaction; ++NativeFinishes; }
- (void)restoreCompletedTransactions { ++NativeRestores; }
- (void)restoreCompletedTransactionsWithApplicationUsername:(NSString *)user { (void)user; ++NativeRestores; }
@end

@interface TestObserver : NSObject
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic) NSUInteger productCallbacks, finished, restored, removed;
@property(nonatomic, copy) NSArray *products;
@property(nonatomic) BOOL autoFinish;
@end
@implementation TestObserver
- (instancetype)init { self = [super init]; if (self) _events = [NSMutableArray array]; return self; }
- (void)productsRequest:(id)request didReceiveResponse:(SKProductsResponse *)response {
    (void)request; ++self.productCallbacks; self.products = response.products;
}
- (void)requestDidFinish:(id)request { (void)request; ++self.finished; }
- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    [self.events addObjectsFromArray:transactions];
    if (self.autoFinish) for (id transaction in transactions) [queue finishTransaction:transaction];
}
- (void)paymentQueue:(id)queue removedTransactions:(NSArray *)transactions { (void)queue; self.removed += transactions.count; }
- (void)paymentQueueRestoreCompletedTransactionsFinished:(id)queue { (void)queue; ++self.restored; }
@end

static void Drain(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.08];
    while ([deadline timeIntervalSinceNow] > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static void WaitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!condition() && [deadline timeIntervalSinceNow] > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(condition());
}
static SKMutablePayment *Pay(NSString *product) {
    SKMutablePayment *payment = [SKMutablePayment new]; payment.productIdentifier = product; payment.quantity = 1; return payment;
}

static void StoreKitChecks(void) {
    AsignInstallStoreKitPurchasePatch();
    AsignInstallStoreKitPurchasePatch();
    assert(!AsignLocalPurchasesActive());
    assert(!AsignLocalPurchases().count);
    TestObserver *first = [TestObserver new], *second = [TestObserver new];
    SKProductsRequest *a = [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithArray:@[@"a", @"b"]]];
    SKProductsRequest *b = [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithObject:@"c"]];
    a.delegate = first; b.delegate = second;
    [a start]; [a start]; [b start]; [b cancel]; Drain();
    assert(first.productCallbacks == 1 && first.finished == 1 && first.products.count == 2);
    assert(!second.productCallbacks && !NativeStarts);
    assert(AsignLocalPurchasesActive());
    assert([first.products[0] isKindOfClass:SKProduct.class]);
    assert([[(SKProduct *)first.products[0] productIdentifier] isEqual:@"a"]);
    SKMutablePayment *fromProduct = (id)[SKPayment paymentWithProduct:first.products[0]];
    assert([fromProduct isKindOfClass:SKMutablePayment.class] && [fromProduct.productIdentifier isEqual:@"a"] && fromProduct.quantity == 1);
    AppCaller = NO;
    SKProductsRequest *native = [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithObject:@"system"]];
    [native start]; assert(NativeStarts == 1); AppCaller = YES;
    SKReceiptRefreshRequest *refresh = [SKReceiptRefreshRequest new]; refresh.delegate = second;
    [refresh start]; Drain(); assert(second.finished == 1 && NativeStarts == 1);
    NSData *receipt = [NSData dataWithContentsOfURL:AsignLocalReceiptURL()];
    assert([NSJSONSerialization JSONObjectWithData:receipt options:0 error:NULL] != nil);

    SKPaymentQueue *queue = [SKPaymentQueue new];
    first.autoFinish = YES;
    [queue addTransactionObserver:first]; [queue addTransactionObserver:second];
    [queue addPayment:Pay(@"a")]; Drain();
    assert(!NativePayments && !NativeFinishes && AsignLocalPurchases()[@"a"]);
    assert(first.events.count == 1 && second.events.count == 1 && !queue.transactions.count);
    SKPaymentTransaction *transaction = first.events.lastObject;
    assert(transaction.transactionState == 1 && transaction.error == nil && transaction.originalTransaction == nil);
    assert([transaction.transactionIdentifier isEqual:transaction.matchingIdentifier]);
    assert([transaction.payment.productIdentifier isEqual:@"a"] && !AsignLocalPendingPurchases().count);
    [queue finishTransaction:transaction]; Drain(); assert(first.removed == 1);
    [queue finishTransaction:[SKPaymentTransaction new]]; assert(NativeFinishes == 1);
    [queue addPayment:Pay(@"a")]; Drain();
    assert(first.events.count == 2 && ![transaction.transactionIdentifier isEqual:((SKPaymentTransaction *)first.events.lastObject).transactionIdentifier]);
    [queue restoreCompletedTransactions]; Drain();
    assert(!NativeRestores && first.restored == 1 && second.restored == 1);
    transaction = first.events.lastObject;
    assert(transaction.transactionState == 3 && [(SKPaymentTransaction *)transaction.originalTransaction transactionState] == 1);
    assert(first.events.count == 3 && second.events.count == 3);

    // An observer added after purchase but before delivery gets one callback.
    SKPaymentQueue *lateQueue = [SKPaymentQueue new]; TestObserver *late = [TestObserver new];
    [lateQueue addPayment:Pay(@"late")]; [lateQueue addTransactionObserver:late]; Drain();
    assert(late.events.count == 1);
    [lateQueue removeTransactionObserver:late]; [lateQueue addPayment:Pay(@"other")]; Drain();
    assert(late.events.count == 1 && !NativePayments);
}

typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);
typedef NSURLSessionDataTask *(*RequestTransport)(NSURLSession *, SEL, NSURLRequest *, Completion);
typedef NSURLSessionDataTask *(*URLTransport)(NSURLSession *, SEL, NSURL *, Completion);
void AsignTestPurchaseTransport(RequestTransport, URLTransport);
static NSUInteger NativeRequests;
static NSObject *Passthrough;
static BOOL UseFixtures;
static NSUInteger MappingRequests;
@interface FixtureTransportTask : NSObject
@property(nonatomic, copy) dispatch_block_t completion;
- (void)resume;
@end
@implementation FixtureTransportTask
- (void)resume { dispatch_async(dispatch_get_main_queue(), self.completion); }
@end
static NSURLSessionDataTask *Transport(NSURLSession *session, SEL selector, NSURLRequest *request, Completion completion) {
    (void)session; (void)selector; ++NativeRequests;
    if (!UseFixtures) return (id)Passthrough;
    NSDictionary *body;
    if ([request.URL.path isEqual:@"/v1/product_entitlement_mapping"]) {
        ++MappingRequests;
        body = @{@"product_entitlement_mapping":@{@"remote.sku":@{
            @"product_identifier":@"remote.sku", @"entitlements":@[@"reader_remote"]}}};
    } else {
        body = @{@"subscriber":@{@"original_app_user_id":@"newuser", @"entitlements":@{}}};
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    FixtureTransportTask *task = [FixtureTransportTask new];
    task.completion = ^{ completion(data, response, nil); };
    return (id)task;
}
static NSURLSessionDataTask *URLTransportFunction(NSURLSession *session, SEL selector, NSURL *url, Completion completion) {
    (void)url; return Transport(session, selector, nil, completion);
}
static NSMutableURLRequest *Request(NSString *url, NSString *key) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    if (key) [request setValue:key forHTTPHeaderField:@"Authorization"];
    return request;
}

static void RevenueCatChecks(void) {
    NSString *key = @"Bearer public-app-one";
    NSDictionary *mapping = @{@"product_entitlement_mapping":@{
        @"product-a":@{@"product_identifier":@"a", @"entitlements":@[@"reader", @"editor"]}}};
    AsignRememberPurchaseMapping(key, mapping);
    assert(AsignPurchaseMapping(key).count == 1 && !AsignPurchaseMapping(@"Bearer app-two").count);
    NSDictionary *body = AsignLocalSubscriberResponse(key, @"user", @{@"unchanged":@YES,
        @"subscriber":@{@"original_app_user_id":@"user", @"subscriptions":@{}, @"entitlements":@{}, @"non_subscriptions":@{}}});
    assert([body[@"unchanged"] boolValue]);
    assert([body[@"subscriber"][@"entitlements"] count] == 2);
    assert(body[@"subscriber"][@"entitlements"][@"reader"][@"expires_date"] == NSNull.null);
    assert([body[@"subscriber"][@"entitlements"][@"editor"][@"product_identifier"] isEqual:@"a"]);
    assert(!AsignLocalSubscriberResponse(@"unknown", @"user", nil));

    AsignInstallRevenueCatPurchasePatch();
    AsignTestPurchaseTransport(Transport, URLTransportFunction);
    Passthrough = [NSObject new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        delegate:nil delegateQueue:NSOperationQueue.mainQueue];
    RequestTransport factory = (RequestTransport)method_getImplementation(class_getInstanceMethod(NSURLSession.class,
        @selector(dataTaskWithRequest:completionHandler:)));
    __block NSUInteger callbacks = 0;
    NSMutableURLRequest *request = Request(@"https://api.revenuecat.com/v1/subscribers/user", key);
    NSURLSessionDataTask *task = factory(session, @selector(dataTaskWithRequest:completionHandler:), request,
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            assert(!error && data.length && [(NSHTTPURLResponse *)response statusCode] == 200); ++callbacks;
        });
    assert([task isKindOfClass:NSURLSessionDataTask.class] && task.state == NSURLSessionTaskStateSuspended && !callbacks);
    [task resume]; [task resume]; WaitFor(^BOOL { return callbacks == 1; }); Drain();
    assert(callbacks == 1 && task.state == NSURLSessionTaskStateCompleted && !NativeRequests);
    [task cancel]; Drain(); assert(callbacks == 1);

    task = factory(session, @selector(dataTaskWithRequest:completionHandler:), request,
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            assert(!data && !response && error.code == NSURLErrorCancelled); ++callbacks;
        });
    [task cancel]; [task resume]; WaitFor(^BOOL { return callbacks == 2; }); Drain();
    for (NSString *url in @[@"https://example.com/v1/subscribers/user", @"https://api.revenuecat.com.evil.test/v1/subscribers/user",
                            @"https://api.revenuecat.com/v1/subscribers/user/offerings"]) {
        request = Request(url, key);
        assert((id)factory(session, @selector(dataTaskWithRequest:completionHandler:), request, ^(NSData *d, NSURLResponse *r, NSError *e) {
            (void)d; (void)r; (void)e;
        }) == Passthrough);
    }
    request = Request(@"https://api.revenuecat.com/v1/subscribers/identify", key); request.HTTPMethod = @"POST";
    assert((id)factory(session, @selector(dataTaskWithRequest:completionHandler:), request,
        ^(NSData *d, NSURLResponse *r, NSError *e) { (void)d; (void)r; (void)e; }) == Passthrough);
    assert(NativeRequests == 4);

    // Local receipts never get posted when their entitlement mapping is unknown.
    request = Request(@"https://api.revenuecat.com/v1/receipts", @"Bearer unknown"); request.HTTPMethod = @"POST";
    task = factory(session, @selector(dataTaskWithRequest:completionHandler:), request,
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response; assert(!data && error.code == NSURLErrorCannotParseResponse); ++callbacks;
        });
    [task resume]; WaitFor(^BOOL { return callbacks == 3; }); assert(NativeRequests == 4);

    // Two simultaneous customer requests share one mapping fetch, then later
    // requests reuse the mapping and complete locally with no transport call.
    UseFixtures = YES;
    request = Request(@"https://api.revenuecat.com/v1/subscribers/newuser", @"Bearer fetched-app");
    Completion received = ^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        assert(!error && json[@"subscriber"][@"entitlements"][@"reader_remote"]); ++callbacks;
    };
    NSURLSessionDataTask *other = factory(session, @selector(dataTaskWithRequest:completionHandler:), request, received);
    task = factory(session, @selector(dataTaskWithRequest:completionHandler:), request, received);
    [other resume]; [task resume]; WaitFor(^BOOL { return callbacks == 5; });
    assert(MappingRequests == 1 && NativeRequests == 7);
    task = factory(session, @selector(dataTaskWithRequest:completionHandler:), request, received);
    [task resume]; WaitFor(^BOOL { return callbacks == 6; }); assert(NativeRequests == 7);
    UseFixtures = NO;
    [session invalidateAndCancel];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        NSString *suite = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        Defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        TestSupport = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:suite isDirectory:YES];
        Method directories = class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:));
        OriginalDirectories = (void *)method_getImplementation(directories);
        method_setImplementation(directories, (IMP)TestDirectories);
        method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), (IMP)TestDefaults);
        if ([mode isEqual:@"write"]) {
            AsignRecordLocalPurchase(@"persisted", 2);
            [Defaults synchronize];
        } else if ([mode isEqual:@"read"]) {
            assert([AsignLocalPurchases()[@"persisted"][@"quantity"] integerValue] == 2);
            assert(AsignLocalPendingPurchases().count == 1);
            AsignFinishLocalPurchase(AsignLocalPurchases()[@"persisted"][@"identifier"]);
            assert(!AsignLocalPendingPurchases().count && AsignLocalPurchases().count == 1);
        } else if ([mode isEqual:@"runtime"]) {
            [Defaults removePersistentDomainForName:suite];
            StoreKitChecks(); RevenueCatChecks();
            [Defaults removePersistentDomainForName:suite];
        } else {
            [Defaults removePersistentDomainForName:suite];
        }
        [Defaults synchronize];
        [NSFileManager.defaultManager removeItemAtURL:TestSupport error:NULL];
        puts("Local purchase checks passed.");
    }
    return 0;
}
