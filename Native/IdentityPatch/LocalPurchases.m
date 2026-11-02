#import "PurchasePatch.h"
#import "MethodHook.h"
#import <objc/message.h>
#import <stdint.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <math.h>

__attribute__((used, visibility("default")))
const char AsignPurchasePatchVersion[] = "AsignPurchasePatch/v1";

static NSString *const LedgerKey = @"AsignLocalPurchases.v1";
static NSString *const PendingKey = @"AsignLocalPurchasePending.v1";
static NSString *const MappingKey = @"AsignLocalPurchaseMappings.v1";
static char StoreValuesKey;
static atomic_bool PurchaseContextActive;

void AsignActivateLocalPurchases(void) { atomic_store(&PurchaseContextActive, true); }
BOOL AsignLocalPurchasesActive(void) { return atomic_load(&PurchaseContextActive); }

static BOOL Identifier(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 1024;
}

static NSObject *PurchaseLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDictionary *Records(NSString *key) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (![stored isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *valid = [NSMutableDictionary dictionary];
    for (id identifier in stored) {
        id record = stored[identifier];
        if (!Identifier(identifier) || ![record isKindOfClass:NSDictionary.class] ||
            !Identifier(record[@"product"]) || !Identifier(record[@"identifier"]) ||
            ![record[@"date"] isKindOfClass:NSNumber.class] ||
            ![record[@"quantity"] isKindOfClass:NSNumber.class] ||
            !isfinite([record[@"date"] doubleValue]) || [record[@"date"] doubleValue] < 0 ||
            [record[@"quantity"] integerValue] < 1) continue;
        valid[identifier] = record;
    }
    return [valid copy];
}

NSDictionary *AsignLocalPurchases(void) {
    @synchronized (PurchaseLock()) { return Records(LedgerKey); }
}

NSDictionary *AsignLocalPendingPurchases(void) {
    @synchronized (PurchaseLock()) { return Records(PendingKey); }
}

NSString *AsignLocalTransactionIdentifier(void) {
    static uint64_t previous;
    @synchronized (PurchaseLock()) {
        uint64_t now = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000000.0);
        previous = MAX(now, previous + 1);
        return [NSString stringWithFormat:@"%llu", (unsigned long long)previous];
    }
}

NSDictionary *AsignRecordLocalPurchase(NSString *product, NSInteger quantity) {
    if (!Identifier(product) || quantity < 1) return nil;
    AsignActivateLocalPurchases();
    @synchronized (PurchaseLock()) {
        NSDictionary *record = @{@"product":product, @"quantity":@(quantity),
            @"identifier":AsignLocalTransactionIdentifier(), @"date":@(NSDate.date.timeIntervalSince1970)};
        NSMutableDictionary *owned = [Records(LedgerKey) mutableCopy];
        NSMutableDictionary *pending = [Records(PendingKey) mutableCopy];
        owned[product] = record;
        pending[record[@"identifier"]] = record;
        [NSUserDefaults.standardUserDefaults setObject:owned forKey:LedgerKey];
        [NSUserDefaults.standardUserDefaults setObject:pending forKey:PendingKey];
        return record;
    }
}

void AsignFinishLocalPurchase(NSString *transaction) {
    if (!Identifier(transaction)) return;
    @synchronized (PurchaseLock()) {
        NSMutableDictionary *pending = [Records(PendingKey) mutableCopy];
        [pending removeObjectForKey:transaction];
        [NSUserDefaults.standardUserDefaults setObject:pending forKey:PendingKey];
    }
}

static NSString *DateString(NSTimeInterval time) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:time]];
}

NSDictionary *AsignLocalReceiptResponse(void) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *record in AsignLocalPurchases().allValues) {
        NSTimeInterval time = [record[@"date"] doubleValue];
        [items addObject:@{@"product_id":record[@"product"], @"quantity":[record[@"quantity"] stringValue],
            @"transaction_id":record[@"identifier"], @"original_transaction_id":record[@"identifier"],
            @"purchase_date":DateString(time), @"original_purchase_date":DateString(time),
            @"purchase_date_ms":[NSString stringWithFormat:@"%.0f", time * 1000.0]}];
    }
    NSString *bundle = NSBundle.mainBundle.infoDictionary[@"AsignOriginalBundleIdentifier"] ?: NSBundle.mainBundle.bundleIdentifier ?: @"";
    return @{@"status":@0, @"environment":@"Sandbox", @"receipt":@{
        @"bundle_id":bundle, @"application_version":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"1",
        @"in_app":items}, @"latest_receipt_info":items};
}

NSData *AsignLocalReceipt(void) {
    // Local compatibility data, never an Apple-signed receipt/JWS.
    return [NSJSONSerialization dataWithJSONObject:AsignLocalReceiptResponse() options:0 error:NULL];
}

NSURL *AsignLocalReceiptURL(void) {
    @synchronized (PurchaseLock()) {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *root = [[manager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
        if (!root) return nil;
        root = [root URLByAppendingPathComponent:@"AsignLocalPurchases" isDirectory:YES];
        if (![manager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
        NSURL *receipt = [root URLByAppendingPathComponent:@"receipt.json"];
        return [AsignLocalReceipt() writeToURL:receipt options:NSDataWritingAtomic error:NULL] ? receipt : nil;
    }
}

static NSDictionary *Mappings(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:MappingKey];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

NSDictionary *AsignPurchaseMapping(NSString *scope) {
    if (!Identifier(scope)) return @{};
    @synchronized (PurchaseLock()) {
        id value = Mappings()[scope];
        if (![value isKindOfClass:NSDictionary.class]) return @{};
        NSMutableDictionary *valid = [NSMutableDictionary dictionary];
        for (id product in value) {
            id names = value[product];
            if (!Identifier(product) || ![names isKindOfClass:NSArray.class]) continue;
            NSMutableArray *entries = [NSMutableArray array];
            for (id name in names) if (Identifier(name)) [entries addObject:name];
            if (entries.count) valid[product] = [entries copy];
        }
        return [valid copy];
    }
}

void AsignRememberPurchaseMapping(NSString *scope, NSDictionary *response) {
    if (!Identifier(scope) || ![response isKindOfClass:NSDictionary.class]) return;
    @synchronized (PurchaseLock()) {
        NSMutableDictionary *mapping = [AsignPurchaseMapping(scope) mutableCopy];
        id products = response[@"product_entitlement_mapping"];
        if ([products isKindOfClass:NSDictionary.class]) {
            for (id key in products) {
                id entry = products[key];
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                NSString *product = entry[@"product_identifier"];
                id entitlements = entry[@"entitlements"];
                if (!Identifier(product) || ![entitlements isKindOfClass:NSArray.class]) continue;
                NSMutableSet *names = [NSMutableSet set];
                for (id entitlement in entitlements) if (Identifier(entitlement)) [names addObject:entitlement];
                if (names.count) mapping[product] = names.allObjects;
            }
        }
        // Existing (including expired) entitlement records establish exact names.
        id subscriber = response[@"subscriber"];
        id entitlements = [subscriber isKindOfClass:NSDictionary.class] ? subscriber[@"entitlements"] : nil;
        if ([entitlements isKindOfClass:NSDictionary.class]) {
            for (id name in entitlements) {
                id entry = entitlements[name];
                NSString *product = [entry isKindOfClass:NSDictionary.class] ? entry[@"product_identifier"] : nil;
                if (!Identifier(name) || !Identifier(product)) continue;
                id old = mapping[product];
                NSMutableSet *names = [NSMutableSet setWithArray:[old isKindOfClass:NSArray.class] ? old : @[]];
                [names addObject:name];
                mapping[product] = names.allObjects;
            }
        }
        if (!mapping.count) return;
        NSMutableDictionary *all = [Mappings() mutableCopy];
        all[scope] = mapping;
        [NSUserDefaults.standardUserDefaults setObject:all forKey:MappingKey];
    }
}

NSDictionary *AsignLocalSubscriberResponse(NSString *scope, NSString *user, NSDictionary *response) {
    if (![response isKindOfClass:NSDictionary.class]) response = @{};
    AsignRememberPurchaseMapping(scope, response);
    NSDictionary *mapping = AsignPurchaseMapping(scope);
    if (!mapping.count) return nil;
    NSMutableDictionary *result = [response mutableCopy];
    id raw = result[@"subscriber"];
    NSMutableDictionary *subscriber = [raw isKindOfClass:NSDictionary.class] ? [raw mutableCopy] : [NSMutableDictionary dictionary];
    raw = subscriber[@"subscriptions"];
    NSMutableDictionary *subscriptions = [raw isKindOfClass:NSDictionary.class] ? [raw mutableCopy] : [NSMutableDictionary dictionary];
    raw = subscriber[@"entitlements"];
    NSMutableDictionary *entitlements = [raw isKindOfClass:NSDictionary.class] ? [raw mutableCopy] : [NSMutableDictionary dictionary];
    NSString *now = DateString(NSDate.date.timeIntervalSince1970);
    NSDictionary *owned = AsignLocalPurchases();
    for (NSString *product in mapping) {
        id names = mapping[product];
        if (![names isKindOfClass:NSArray.class] || ![names count]) continue;
        id record = owned[product];
        NSString *date = [record isKindOfClass:NSDictionary.class] ? DateString([record[@"date"] doubleValue]) : now;
        raw = subscriptions[product];
        NSMutableDictionary *subscription = [raw isKindOfClass:NSDictionary.class] ? [raw mutableCopy] : [NSMutableDictionary dictionary];
        [subscription addEntriesFromDictionary:@{@"purchase_date":date, @"original_purchase_date":date,
            @"expires_date":NSNull.null, @"store":@"app_store", @"is_sandbox":@YES,
            @"period_type":@"normal", @"ownership_type":@"PURCHASED",
            @"billing_issues_detected_at":NSNull.null, @"unsubscribe_detected_at":NSNull.null,
            @"refunded_at":NSNull.null}];
        subscriptions[product] = subscription;
        for (id name in names) {
            if (!Identifier(name)) continue;
            entitlements[name] = @{@"product_identifier":product, @"purchase_date":date, @"expires_date":NSNull.null};
        }
    }
    subscriber[@"subscriptions"] = subscriptions;
    subscriber[@"entitlements"] = entitlements;
    if (!subscriber[@"non_subscriptions"]) subscriber[@"non_subscriptions"] = @{};
    if (!subscriber[@"original_app_user_id"]) subscriber[@"original_app_user_id"] = user ?: @"asign-local";
    if (!subscriber[@"first_seen"]) subscriber[@"first_seen"] = now;
    result[@"subscriber"] = subscriber;
    result[@"request_date"] = now;
    result[@"request_date_ms"] = @(NSDate.date.timeIntervalSince1970 * 1000.0);
    return result;
}

id AsignPurchaseObjectValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = object ? class_getInstanceMethod(object_getClass(object), selector) : NULL;
    return AsignMethodMatches(method, "@", NULL, NULL) ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static id ObjectValue(id self, SEL selector) {
    id value = objc_getAssociatedObject(self, &StoreValuesKey)[NSStringFromSelector(selector)];
    return value == NSNull.null ? nil : value;
}
static NSInteger IntegerValue(id self, SEL selector) { return [ObjectValue(self, selector) integerValue]; }
static BOOL BooleanValue(id self, SEL selector) { return [ObjectValue(self, selector) boolValue]; }

id AsignLocalStoreObject(NSString *parent, NSString *name, NSDictionary *values) {
    Class base = NSClassFromString(parent);
    if (!base) return nil;
    @synchronized (PurchaseLock()) {
        Class cls = NSClassFromString(name);
        if (!cls) {
            cls = objc_allocateClassPair(base, name.UTF8String, 0);
            if (!cls) return nil;
            for (NSString *key in values) {
                SEL selector = NSSelectorFromString(key);
                Method method = class_getInstanceMethod(base, selector);
                IMP implementation = NULL;
                if (AsignMethodMatches(method, "@", NULL, NULL)) implementation = (IMP)ObjectValue;
                else if (AsignMethodMatches(method, @encode(NSInteger), NULL, NULL)) implementation = (IMP)IntegerValue;
                else if (AsignMethodMatches(method, @encode(BOOL), NULL, NULL)) implementation = (IMP)BooleanValue;
                if (implementation) class_addMethod(cls, selector, implementation, method_getTypeEncoding(method));
            }
            objc_registerClassPair(cls);
        }
        if (class_getSuperclass(cls) != base) return nil;
        // SDK initializers can replace the instance with their own class.
        // These subclasses provide their own immutable public getter values.
        id object = class_createInstance(cls, 0);
        if (object) objc_setAssociatedObject(object, &StoreValuesKey, [values copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return object;
    }
}

BOOL AsignIsLocalStoreObject(id object) { return object && objc_getAssociatedObject(object, &StoreValuesKey) != nil; }
