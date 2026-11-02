#import "PurchasePatch.h"
#import "MethodHook.h"
#import "PatchPolicy.h"
#import <objc/message.h>

static char RequestKey, QueueKey;
static void (*OriginalStart)(id, SEL);
static void (*OriginalCancel)(id, SEL);
typedef id (*ProductInitializer)(id __attribute__((ns_consumed)), SEL, NSSet *) __attribute__((ns_returns_retained));
static ProductInitializer OriginalProductInitializer;
static void (*OriginalAddObserver)(id, SEL, id);
static void (*OriginalRemoveObserver)(id, SEL, id);
static void (*OriginalFinish)(id, SEL, id);
static NSArray *(*OriginalTransactions)(id, SEL);
static NSURL *(*OriginalReceiptURL)(id, SEL);
static void (*OriginalRefreshStart)(id, SEL);
static void (*OriginalRefreshCancel)(id, SEL);
static id (*OriginalPaymentForProduct)(id, SEL, id);
static NSHashTable *ObservedQueues; // Main queue only, weak; no queue lifetime extension.
static void AutoRestore(id queue);
static void Notify(id queue, NSArray *transactions, NSString *name);

@interface AsignLocalProductRequest : NSObject
@property(nonatomic, copy) NSArray *identifiers;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL cancelled;
@end
@implementation AsignLocalProductRequest
@end

@interface AsignLocalPurchaseQueue : NSObject
@property(nonatomic, strong) NSHashTable *observers;
@property(nonatomic, strong) NSMutableArray *pending;
@property(nonatomic, strong) NSMapTable *delivered;
@property(nonatomic, strong) NSMutableSet *autoRestoredProducts;
@end
@implementation AsignLocalPurchaseQueue
@end

static void OnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static id LocalProduct(NSString *identifier) {
    return AsignLocalStoreObject(@"SKProduct", @"AsignLocalProductV1", @{
        @"productIdentifier":identifier, @"localizedTitle":identifier, @"localizedDescription":identifier,
        @"price":NSDecimalNumber.zero, @"priceLocale":NSLocale.currentLocale,
        @"subscriptionPeriod":NSNull.null, @"introductoryPrice":NSNull.null,
        @"subscriptionGroupIdentifier":NSNull.null, @"discounts":@[],
        @"isFamilyShareable":@NO, @"isDownloadable":@NO,
        @"downloadContentLengths":@[], @"downloadContentVersion":NSNull.null});
}

static id Payment(NSDictionary *record) {
    id payment = [NSClassFromString(@"SKMutablePayment") new];
    SEL product = NSSelectorFromString(@"setProductIdentifier:");
    SEL quantity = NSSelectorFromString(@"setQuantity:");
    if (!AsignMethodMatches(class_getInstanceMethod(object_getClass(payment), product), "v", "@", NULL) ||
        !AsignMethodMatches(class_getInstanceMethod(object_getClass(payment), quantity), "v", @encode(NSInteger), NULL)) return nil;
    ((void (*)(id, SEL, id))objc_msgSend)(payment, product, record[@"product"]);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(payment, quantity, [record[@"quantity"] integerValue]);
    return payment;
}

static id Transaction(NSDictionary *record, id payment, NSInteger state, id original, NSError *error, NSData *receipt) {
    if (!payment) return nil;
    NSString *identifier = record[@"identifier"] ?: AsignLocalTransactionIdentifier();
    return AsignLocalStoreObject(@"SKPaymentTransaction", @"AsignLocalTransactionV1", @{
        @"payment":payment, @"transactionState":@(state),
        @"transactionIdentifier":identifier, @"matchingIdentifier":identifier,
        @"transactionDate":[NSDate dateWithTimeIntervalSince1970:[record[@"date"] doubleValue]],
        @"transactionReceipt":receipt ?: AsignLocalReceipt() ?: NSData.data,
        @"originalTransaction":original ?: NSNull.null, @"error":error ?: NSNull.null, @"downloads":@[]});
}

static id PaymentForProduct(id self, SEL selector, id product) {
    NSString *identifier = AsignPurchaseObjectValue(product, @"productIdentifier");
    if (!AsignIsLocalStoreObject(product)) {
        // A real SK1 subscription period establishes a subscription. Its
        // absence cannot distinguish a consumable from a permanent purchase.
        if (AsignPurchaseObjectValue(product, @"subscriptionPeriod"))
            AsignRememberProductKind(identifier, AsignProductSubscription);
        return OriginalPaymentForProduct(self, selector, product);
    }
    return identifier ? Payment(@{@"product":identifier, @"quantity":@1}) : nil;
}

static id JournalTransaction(NSDictionary *record, NSData *receipt) {
    id payment = Payment(record);
    if (![record[@"restored"] boolValue]) return Transaction(record, payment, 1, nil, nil, receipt);
    AsignProductKind kind = AsignLocalProductKind(record[@"product"]);
    if (kind != AsignProductNonConsumable && kind != AsignProductSubscription) return nil;
    NSMutableDictionary *original = [record mutableCopy];
    original[@"identifier"] = record[@"originalIdentifier"];
    original[@"date"] = record[@"originalDate"];
    return Transaction(record, payment, 3, Transaction(original, payment, 1, nil, nil, receipt), nil, receipt);
}

static AsignLocalPurchaseQueue *QueueState(id queue) {
    @synchronized (queue) {
        AsignLocalPurchaseQueue *state = objc_getAssociatedObject(queue, &QueueKey);
        if (!state) {
            state = [AsignLocalPurchaseQueue new];
            state.observers = NSHashTable.weakObjectsHashTable;
            state.pending = [NSMutableArray array];
            state.delivered = [NSMapTable weakToStrongObjectsMapTable];
            state.autoRestoredProducts = [NSMutableSet set];
            NSData *receipt;
            for (NSDictionary *record in AsignLocalPendingPurchases().allValues) {
                if (!receipt) receipt = AsignLocalReceipt();
                id transaction = JournalTransaction(record, receipt);
                if (transaction) {
                    [state.pending addObject:transaction];
                    [state.autoRestoredProducts addObject:record[@"product"]];
                } else if ([record[@"restored"] boolValue]) AsignFinishLocalPurchase(record[@"identifier"]);
            }
            objc_setAssociatedObject(queue, &QueueKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return state;
    }
}

static void NotifyObserver(id observer, NSString *name, id queue, id payload) {
    SEL selector = NSSelectorFromString(name);
    if ([observer respondsToSelector:selector])
        ((void (*)(id, SEL, id, id))objc_msgSend)(observer, selector, queue, payload);
}

static void PruneIneligibleRestores(id queue, AsignLocalPurchaseQueue *state) {
    NSMutableArray *removed = [NSMutableArray array];
    @synchronized (state) {
        for (id transaction in [state.pending copy]) {
            if (!AsignPurchaseObjectValue(transaction, @"originalTransaction")) continue;
            id payment = AsignPurchaseObjectValue(transaction, @"payment");
            AsignProductKind kind = AsignLocalProductKind(AsignPurchaseObjectValue(payment, @"productIdentifier"));
            if (kind == AsignProductNonConsumable || kind == AsignProductSubscription) continue;
            [state.pending removeObjectIdenticalTo:transaction];
            AsignFinishLocalPurchase(AsignPurchaseObjectValue(transaction, @"transactionIdentifier"));
            [removed addObject:transaction];
        }
    }
    if (removed.count) Notify(queue, removed, @"paymentQueue:removedTransactions:");
}

static void DeliverTransactions(id queue, AsignLocalPurchaseQueue *state, id observer, NSArray *transactions) {
    PruneIneligibleRestores(queue, state);
    NSMutableArray *fresh = [NSMutableArray array];
    @synchronized (state) {
        NSMutableSet *seen = [state.delivered objectForKey:observer];
        if (!seen) { seen = [NSMutableSet set]; [state.delivered setObject:seen forKey:observer]; }
        for (id transaction in transactions) {
            if (AsignPurchaseObjectValue(transaction, @"originalTransaction")) {
                id payment = AsignPurchaseObjectValue(transaction, @"payment");
                AsignProductKind kind = AsignLocalProductKind(AsignPurchaseObjectValue(payment, @"productIdentifier"));
                if (kind != AsignProductNonConsumable && kind != AsignProductSubscription) continue;
            }
            NSString *identifier = AsignPurchaseObjectValue(transaction, @"transactionIdentifier");
            if (identifier && ![seen containsObject:identifier]) {
                [seen addObject:identifier];
                [fresh addObject:transaction];
            }
        }
    }
    if (fresh.count) NotifyObserver(observer, @"paymentQueue:updatedTransactions:", queue, fresh);
}

static void Notify(id queue, NSArray *transactions, NSString *name) {
    // Retain the event, not an old observer list. Removal before delivery wins.
    dispatch_async(dispatch_get_main_queue(), ^{
        AsignLocalPurchaseQueue *state = QueueState(queue);
        NSArray *observers;
        @synchronized (state) { observers = state.observers.allObjects; }
        BOOL updated = [name isEqual:@"paymentQueue:updatedTransactions:"];
        for (id observer in observers) {
            if (updated) DeliverTransactions(queue, state, observer, transactions);
            else NotifyObserver(observer, name, queue, transactions);
        }
        if (!updated) @synchronized (state) {
            for (NSMutableSet *seen in state.delivered.objectEnumerator) {
                for (id transaction in transactions)
                    [seen removeObject:AsignPurchaseObjectValue(transaction, @"transactionIdentifier")];
            }
        }
    });
}

static id ProductInit(id self __attribute__((ns_consumed)), SEL selector, NSSet *identifiers) __attribute__((ns_returns_retained));
static id ProductInit(id self __attribute__((ns_consumed)), SEL selector, NSSet *identifiers) {
    BOOL app = AsignPatchCallerIsApp(__builtin_return_address(0));
    id request = OriginalProductInitializer(self, selector, identifiers);
    if (request && app && [identifiers isKindOfClass:NSSet.class]) {
        NSMutableArray *valid = [NSMutableArray array];
        for (id identifier in identifiers) {
            if ([identifier isKindOfClass:NSString.class] && [identifier length] && [identifier length] <= 1024)
                [valid addObject:[identifier copy]];
        }
        if (valid.count) {
            AsignLocalProductRequest *state = [AsignLocalProductRequest new];
            state.identifiers = [valid sortedArrayUsingSelector:@selector(compare:)];
            objc_setAssociatedObject(request, &RequestKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return request;
}

static void StartProducts(id self, SEL selector) {
    AsignLocalProductRequest *state = objc_getAssociatedObject(self, &RequestKey);
    if (!state) { OriginalStart(self, selector); return; }
    AsignActivateLocalPurchases();
    @synchronized (state) {
        if (state.started || state.cancelled) return;
        state.started = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (state) { if (state.cancelled) return; }
        id delegate = AsignPurchaseObjectValue(self, @"delegate");
        NSMutableArray *products = [NSMutableArray array];
        for (NSString *identifier in state.identifiers) {
            id product = LocalProduct(identifier);
            if (product) [products addObject:product];
        }
        id response = AsignLocalStoreObject(@"SKProductsResponse", @"AsignLocalProductsResponseV1",
            @{@"products":[products copy], @"invalidProductIdentifiers":@[]});
        if (!response || products.count != state.identifiers.count) {
            NotifyObserver(delegate, @"request:didFailWithError:", self,
                (id)[NSError errorWithDomain:@"SKErrorDomain" code:0 userInfo:@{NSLocalizedDescriptionKey:@"Local product metadata is unavailable."}]);
            return;
        }
        NotifyObserver(delegate, @"productsRequest:didReceiveResponse:", self, response);
        @synchronized (state) { if (state.cancelled) return; }
        SEL finished = NSSelectorFromString(@"requestDidFinish:");
        if ([delegate respondsToSelector:finished]) ((void (*)(id, SEL, id))objc_msgSend)(delegate, finished, self);
    });
}

static void CancelProducts(id self, SEL selector) {
    AsignLocalProductRequest *state = objc_getAssociatedObject(self, &RequestKey);
    if (!state) { OriginalCancel(self, selector); return; }
    @synchronized (state) { state.cancelled = YES; }
}

static void AddObserver(id self, SEL selector, id observer) {
    AsignActivateLocalPurchases();
    OriginalAddObserver(self, selector, observer);
    if (!observer) return;
    OnMain(^{
        AsignLocalPurchaseQueue *state = QueueState(self);
        if (!ObservedQueues) ObservedQueues = NSHashTable.weakObjectsHashTable;
        [ObservedQueues addObject:self];
        NSArray *pending;
        @synchronized (state) {
            if ([state.observers containsObject:observer]) return;
            [state.observers addObject:observer];
            pending = [state.pending copy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (state) { if (![state.observers containsObject:observer]) return; }
            // Finished events may have been removed since registration.
            NSMutableArray *current = [NSMutableArray array];
            @synchronized (state) {
                for (id transaction in pending) if ([state.pending containsObject:transaction]) [current addObject:transaction];
            }
            if (current.count) DeliverTransactions(self, state, observer, current);
            AutoRestore(self);
        });
    });
}

static void RemoveObserver(id self, SEL selector, id observer) {
    OriginalRemoveObserver(self, selector, observer);
    AsignLocalPurchaseQueue *state = objc_getAssociatedObject(self, &QueueKey);
    @synchronized (state) { [state.observers removeObject:observer]; [state.delivered removeObjectForKey:observer]; }
}

static BOOL CanPay(id self, SEL selector) { (void)self; (void)selector; AsignActivateLocalPurchases(); return YES; }

static NSURL *ReceiptURL(id self, SEL selector) {
    if (self == NSBundle.mainBundle && AsignLocalPurchasesActive() && AsignPatchCallerIsApp(__builtin_return_address(0)))
        return AsignLocalReceiptURL() ?: OriginalReceiptURL(self, selector);
    return OriginalReceiptURL(self, selector);
}

static void StartReceiptRefresh(id self, SEL selector) {
    if (!AsignPatchCallerIsApp(__builtin_return_address(0))) { OriginalRefreshStart(self, selector); return; }
    AsignActivateLocalPurchases();
    AsignLocalProductRequest *state;
    @synchronized (self) {
        state = objc_getAssociatedObject(self, &RequestKey);
        if (state) return;
        state = [AsignLocalProductRequest new]; state.started = YES;
        objc_setAssociatedObject(self, &RequestKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (state) { if (state.cancelled) return; }
        id delegate = AsignPurchaseObjectValue(self, @"delegate");
        if (!AsignLocalReceiptURL()) {
            NotifyObserver(delegate, @"request:didFailWithError:", self, [NSError errorWithDomain:@"SKErrorDomain" code:0
                userInfo:@{NSLocalizedDescriptionKey:@"Cannot save the local purchase receipt."}]);
            return;
        }
        SEL finished = NSSelectorFromString(@"requestDidFinish:");
        if ([delegate respondsToSelector:finished]) ((void (*)(id, SEL, id))objc_msgSend)(delegate, finished, self);
    });
}

static void CancelReceiptRefresh(id self, SEL selector) {
    AsignLocalProductRequest *state = objc_getAssociatedObject(self, &RequestKey);
    if (!state) { OriginalRefreshCancel(self, selector); return; }
    @synchronized (state) { state.cancelled = YES; }
}

static void AddPayment(id self, SEL selector, id payment) {
    (void)selector;
    // No call to the real addPayment: is made, even if the local input is invalid.
    // Native transactions delivered by StoreKit keep their original behavior.
    NSString *product = [AsignPurchaseObjectValue(payment, @"productIdentifier") copy];
    SEL quantitySelector = NSSelectorFromString(@"quantity");
    Method quantityMethod = payment ? class_getInstanceMethod(object_getClass(payment), quantitySelector) : NULL;
    NSInteger quantity = AsignMethodMatches(quantityMethod, @encode(NSInteger), NULL, NULL)
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(payment, quantitySelector) : 1;
    id snapshot = [payment respondsToSelector:NSSelectorFromString(@"copyWithZone:")] ? [payment copy] : payment;
    OnMain(^{
        AsignLocalPurchaseQueue *state = QueueState(self);
        NSDictionary *record = AsignRecordLocalPurchase(product, quantity);
        NSError *error = record ? nil : [NSError errorWithDomain:@"SKErrorDomain" code:3
            userInfo:@{NSLocalizedDescriptionKey:@"Invalid local purchase."}];
        id transaction = Transaction(record ?: @{}, snapshot, record ? 1 : 2, nil, error, nil);
        if (!transaction) return;
        @synchronized (state) {
            [state.pending addObject:transaction];
            if (record) [state.autoRestoredProducts addObject:product];
        }
        Notify(self, @[transaction], @"paymentQueue:updatedTransactions:");
    });
}

static void Finish(id self, SEL selector, id transaction) {
    if (!AsignIsLocalStoreObject(transaction)) { OriginalFinish(self, selector, transaction); return; }
    OnMain(^{
        AsignLocalPurchaseQueue *state = QueueState(self);
        @synchronized (state) {
            if (![state.pending containsObject:transaction]) return;
            [state.pending removeObjectIdenticalTo:transaction];
        }
        AsignFinishLocalPurchase(AsignPurchaseObjectValue(transaction, @"transactionIdentifier"));
        Notify(self, @[transaction], @"paymentQueue:removedTransactions:");
    });
}

static NSArray *Transactions(id self, SEL selector) {
    NSArray *native = OriginalTransactions(self, selector) ?: @[];
    AsignLocalPurchaseQueue *state = objc_getAssociatedObject(self, &QueueKey);
    if (!state) return native;
    @synchronized (state) { return [native arrayByAddingObjectsFromArray:state.pending]; }
}

static void RestoreLocal(id queue, BOOL automatic) {
    AsignLocalPurchaseQueue *state = QueueState(queue);
    PruneIneligibleRestores(queue, state);
    NSMutableArray *restored = [NSMutableArray array];
    NSDictionary *owned = AsignRestorableLocalPurchases();
    NSData *receipt;
    @synchronized (state) {
        if (automatic && !state.observers.allObjects.count) return;
        for (NSString *product in owned) {
            if (automatic && [state.autoRestoredProducts containsObject:product]) continue;
            BOOL pending = NO;
            for (id transaction in state.pending) {
                id payment = AsignPurchaseObjectValue(transaction, @"payment");
                if ([AsignPurchaseObjectValue(payment, @"productIdentifier") isEqual:product]) { pending = YES; break; }
            }
            if (pending) { [state.autoRestoredProducts addObject:product]; continue; }
            NSDictionary *record = AsignRecordLocalRestore(owned[product]);
            // Every restore in this batch has the same ownership receipt.
            // Serialize it once, rather than once per restored/original object.
            if (record && !receipt) receipt = AsignLocalReceipt();
            id transaction = record ? JournalTransaction(record, receipt) : nil;
            if (transaction) {
                [restored addObject:transaction];
                [state.autoRestoredProducts addObject:product];
            }
        }
        [state.pending addObjectsFromArray:restored];
    }
    if (restored.count) Notify(queue, [restored copy], @"paymentQueue:updatedTransactions:");
}

static void AutoRestore(id queue) { RestoreLocal(queue, YES); }

void AsignStoreKitProductTypesChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id queue in ObservedQueues.allObjects) AutoRestore(queue);
    });
}

static void Restore(id self, SEL selector) {
    (void)selector;
    AsignActivateLocalPurchases();
    OnMain(^{
        RestoreLocal(self, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            AsignLocalPurchaseQueue *state = QueueState(self);
            NSArray *observers;
            @synchronized (state) { observers = state.observers.allObjects; }
            SEL finished = NSSelectorFromString(@"paymentQueueRestoreCompletedTransactionsFinished:");
            for (id observer in observers) if ([observer respondsToSelector:finished])
                ((void (*)(id, SEL, id))objc_msgSend)(observer, finished, self);
        });
    });
}

static void RestoreUser(id self, SEL selector, NSString *user) { (void)user; Restore(self, selector); }

void AsignInstallStoreKitPurchasePatch(void) {
    static BOOL installed;
    Class queue = NSClassFromString(@"SKPaymentQueue"), request = NSClassFromString(@"SKProductsRequest");
    if (!queue || !request) return;
    @synchronized (queue) {
        if (installed) return;
        // Validate the complete critical path before intercepting any purchase.
        Class product = NSClassFromString(@"SKProduct"), response = NSClassFromString(@"SKProductsResponse");
        Class transaction = NSClassFromString(@"SKPaymentTransaction"), payment = NSClassFromString(@"SKMutablePayment");
        Class paymentFactory = object_getClass(NSClassFromString(@"SKPayment"));
        const struct { Class cls; const char *name, *result, *argument; } required[] = {
            {queue, "addPayment:", "v", "@"}, {queue, "addTransactionObserver:", "v", "@"},
            {queue, "removeTransactionObserver:", "v", "@"}, {queue, "finishTransaction:", "v", "@"},
            {queue, "transactions", "@", NULL}, {queue, "restoreCompletedTransactions", "v", NULL},
            {queue, "restoreCompletedTransactionsWithApplicationUsername:", "v", "@"},
            {object_getClass(queue), "canMakePayments", @encode(BOOL), NULL},
            {request, "start", "v", NULL}, {request, "cancel", "v", NULL},
            {request, "initWithProductIdentifiers:", "@", "@"}, {request, "delegate", "@", NULL},
            {product, "productIdentifier", "@", NULL}, {product, "price", "@", NULL},
            {product, "priceLocale", "@", NULL}, {response, "products", "@", NULL},
            {response, "invalidProductIdentifiers", "@", NULL},
            {transaction, "payment", "@", NULL}, {transaction, "transactionState", @encode(NSInteger), NULL},
            {transaction, "transactionIdentifier", "@", NULL}, {transaction, "transactionDate", "@", NULL},
            {transaction, "originalTransaction", "@", NULL}, {transaction, "error", "@", NULL},
            {payment, "setProductIdentifier:", "v", "@"}, {payment, "setQuantity:", "v", @encode(NSInteger)},
            {paymentFactory, "paymentWithProduct:", "@", "@"}
        };
        for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); ++i) {
            Class cls = required[i].cls;
            if (!cls || !AsignMethodMatches(class_getInstanceMethod(cls, NSSelectorFromString(
                [NSString stringWithUTF8String:required[i].name])), required[i].result, required[i].argument, NULL)) return;
        }
#define HOOK(cls, name, replacement, original, result, argument) \
        AsignHookMethod(cls, NSSelectorFromString(@name), (IMP)replacement, (IMP *)&original, result, argument, NULL)
        HOOK(request, "initWithProductIdentifiers:", ProductInit, OriginalProductInitializer, "@", "@");
        HOOK(request, "start", StartProducts, OriginalStart, "v", NULL);
        HOOK(request, "cancel", CancelProducts, OriginalCancel, "v", NULL);
        HOOK(paymentFactory, "paymentWithProduct:", PaymentForProduct, OriginalPaymentForProduct, "@", "@");
        HOOK(queue, "addTransactionObserver:", AddObserver, OriginalAddObserver, "v", "@");
        HOOK(queue, "removeTransactionObserver:", RemoveObserver, OriginalRemoveObserver, "v", "@");
        HOOK(queue, "finishTransaction:", Finish, OriginalFinish, "v", "@");
        HOOK(queue, "transactions", Transactions, OriginalTransactions, "@", NULL);
        IMP unused = NULL;
        HOOK(queue, "restoreCompletedTransactions", Restore, unused, "v", NULL);
        HOOK(queue, "restoreCompletedTransactionsWithApplicationUsername:", RestoreUser, unused, "v", "@");
        HOOK(object_getClass(queue), "canMakePayments", CanPay, unused, @encode(BOOL), NULL);
        HOOK(queue, "addPayment:", AddPayment, unused, "v", "@");
        Class refresh = NSClassFromString(@"SKReceiptRefreshRequest");
        if (AsignMethodMatches(class_getInstanceMethod(NSBundle.class, NSSelectorFromString(@"appStoreReceiptURL")), "@", NULL, NULL) &&
            AsignMethodMatches(class_getInstanceMethod(refresh, @selector(start)), "v", NULL, NULL) &&
            AsignMethodMatches(class_getInstanceMethod(refresh, @selector(cancel)), "v", NULL, NULL)) {
            HOOK(NSBundle.class, "appStoreReceiptURL", ReceiptURL, OriginalReceiptURL, "@", NULL);
            HOOK(refresh, "start", StartReceiptRefresh, OriginalRefreshStart, "v", NULL);
            HOOK(refresh, "cancel", CancelReceiptRefresh, OriginalRefreshCancel, "v", NULL);
        }
#undef HOOK
        installed = YES;
    }
}
