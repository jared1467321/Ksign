#import "PurchasePatch.h"
#import "MethodHook.h"
#import "PatchPolicy.h"
#import <objc/message.h>

// Only published RevenueCat Objective-C classes/selectors are eligible. No
// method-name search, arbitrary app getter replacement, ivar writes or forged
// Swift objects. Swift calls that bypass Objective-C dispatch are unaffected.
static Class EntitlementClass;
static BOOL (*NativeActive)(id, SEL);
static BOOL (*NativeActiveAny)(id, SEL);
static BOOL (*NativeActiveCurrent)(id, SEL);
static BOOL (*NativeWillRenew)(id, SEL);
static id (*NativeExpiration)(id, SEL);
static id (*NativeActiveEntitlements)(id, SEL);
static id (*NativeActiveAnyEntitlements)(id, SEL);
static id (*NativeActiveCurrentEntitlements)(id, SEL);
static id (*NativeActiveSubscriptions)(id, SEL);
static id (*NativePurchasedProducts)(id, SEL);
static id (*NativeProductExpiration)(id, SEL, id);
static id (*NativeEntitlementExpiration)(id, SEL, id);
static id (*NativeProductPurchaseDate)(id, SEL, id);
static id (*NativeEntitlementPurchaseDate)(id, SEL, id);
static id (*NativeProductIdentifier)(id, SEL);
static NSInteger (*NativeProductType)(id, SEL);

static BOOL AppMethod(Class cls, NSString *name, const char *result) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
    return AsignMethodMatches(method, result, NULL, NULL) &&
        AsignPatchCallerIsApp((const void *)method_getImplementation(method));
}

static NSDictionary *LocalEntitlement(id info) {
    if (!EntitlementClass || ![info isKindOfClass:EntitlementClass]) return nil;
    id identifier = AsignPurchaseObjectValue(info, @"identifier");
    id product = AsignPurchaseObjectValue(info, @"productIdentifier");
    if (![identifier isKindOfClass:NSString.class] || ![identifier length] ||
        ![product isKindOfClass:NSString.class] || ![product length]) return nil;
    // The SDK's own entitlement establishes the name/product relationship.
    // Ownership must come from a local purchase, with an established type.
    NSDictionary *record = AsignRestorableLocalPurchases()[product];
    if (record) AsignActivateLocalPurchases();
    return record;
}

static BOOL Active(id self, SEL selector) {
    return NativeActive(self, selector) || LocalEntitlement(self) != nil;
}
static BOOL ActiveAny(id self, SEL selector) {
    return NativeActiveAny(self, selector) || LocalEntitlement(self) != nil;
}
static BOOL ActiveCurrent(id self, SEL selector) {
    return NativeActiveCurrent(self, selector) || LocalEntitlement(self) != nil;
}
static BOOL WillRenew(id self, SEL selector) {
    if (LocalEntitlement(self) && !NativeActive(self, NSSelectorFromString(@"isActive"))) return NO;
    return NativeWillRenew(self, selector);
}
static id Expiration(id self, SEL selector) {
    if (LocalEntitlement(self) && !NativeActive(self, NSSelectorFromString(@"isActive"))) return nil;
    return NativeExpiration(self, selector);
}

static NSDictionary *AllEntitlements(id infos) {
    id all = AsignPurchaseObjectValue(infos, @"all");
    return [all isKindOfClass:NSDictionary.class] ? all : @{};
}
static id MergeActive(id self, id native) {
    if (![native isKindOfClass:NSDictionary.class]) return native;
    NSMutableDictionary *result = [native mutableCopy];
    NSDictionary *all = AllEntitlements(self);
    for (id name in all) {
        id info = all[name];
        if ([name isKindOfClass:NSString.class] &&
            [name isEqual:AsignPurchaseObjectValue(info, @"identifier")] && LocalEntitlement(info)) result[name] = info;
    }
    return [result copy];
}
static id ActiveEntitlements(id self, SEL selector) { return MergeActive(self, NativeActiveEntitlements(self, selector)); }
static id ActiveAnyEntitlements(id self, SEL selector) { return MergeActive(self, NativeActiveAnyEntitlements(self, selector)); }
static id ActiveCurrentEntitlements(id self, SEL selector) { return MergeActive(self, NativeActiveCurrentEntitlements(self, selector)); }

static id MergeProducts(id self, id native, BOOL subscriptionsOnly) {
    if (![native isKindOfClass:NSSet.class]) return native;
    NSMutableSet *result = [native mutableCopy];
    NSDictionary *all = AllEntitlements(AsignPurchaseObjectValue(self, @"entitlements"));
    for (id name in all) {
        id info = all[name];
        if (![name isKindOfClass:NSString.class] || ![name isEqual:AsignPurchaseObjectValue(info, @"identifier")]) continue;
        NSDictionary *record = LocalEntitlement(info);
        if (record && (!subscriptionsOnly || AsignLocalProductKind(record[@"product"]) == AsignProductSubscription))
            [result addObject:record[@"product"]];
    }
    return [result copy];
}
static id ActiveSubscriptions(id self, SEL selector) { return MergeProducts(self, NativeActiveSubscriptions(self, selector), YES); }
static id PurchasedProducts(id self, SEL selector) { return MergeProducts(self, NativePurchasedProducts(self, selector), NO); }

static NSDictionary *CustomerRecord(id customer, id identifier, BOOL entitlementName) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    NSDictionary *all = AllEntitlements(AsignPurchaseObjectValue(customer, @"entitlements"));
    for (id name in all) {
        id info = all[name];
        if (![name isEqual:AsignPurchaseObjectValue(info, @"identifier")]) continue;
        id match = entitlementName ? name : AsignPurchaseObjectValue(info, @"productIdentifier");
        if ([identifier isEqual:match]) return LocalEntitlement(info);
    }
    return nil;
}
static id ExpirationDate(id native, NSDictionary *record) {
    return record && [native isKindOfClass:NSDate.class] && [native timeIntervalSinceNow] <= 0 ? nil : native;
}
static id PurchaseDate(id native, NSDictionary *record) {
    return native ?: (record ? [NSDate dateWithTimeIntervalSince1970:[record[@"date"] doubleValue]] : nil);
}
static id ProductExpiration(id self, SEL selector, id product) {
    return ExpirationDate(NativeProductExpiration(self, selector, product), CustomerRecord(self, product, NO));
}
static id EntitlementExpiration(id self, SEL selector, id name) {
    return ExpirationDate(NativeEntitlementExpiration(self, selector, name), CustomerRecord(self, name, YES));
}
static id ProductPurchaseDate(id self, SEL selector, id product) {
    return PurchaseDate(NativeProductPurchaseDate(self, selector, product), CustomerRecord(self, product, NO));
}
static id EntitlementPurchaseDate(id self, SEL selector, id name) {
    return PurchaseDate(NativeEntitlementPurchaseDate(self, selector, name), CustomerRecord(self, name, YES));
}

static id ProductIdentifier(id self, SEL selector) {
    id identifier = NativeProductIdentifier(self, selector);
    if (![identifier isKindOfClass:NSString.class]) return identifier;
    if (AsignPurchaseObjectValue(self, @"sk1Product")) {
        // RC's SK1 productType is a placeholder nonConsumable even for coins.
        // Only an actual subscription period is evidence in this case.
        if (AsignPurchaseObjectValue(self, @"subscriptionPeriod"))
            AsignRememberProductKind(identifier, AsignProductSubscription);
    } else {
        NSInteger type = NativeProductType(self, NSSelectorFromString(@"productType"));
        // RCStoreProductType's documented values: consumable=0,
        // nonConsumable=1, nonRenewableSubscription=2, autoRenewable=3.
        if (type >= 0 && type <= 3) AsignRememberProductKind(identifier,
            type == 0 ? AsignProductConsumable : type == 1 ? AsignProductNonConsumable : AsignProductSubscription);
    }
    return identifier;
}

void AsignInstallPurchaseSDKPatch(void) {
    static BOOL infoInstalled, infosInstalled, customerInstalled, productInstalled;
    @synchronized (NSObject.class) {
        Class info = NSClassFromString(@"RCEntitlementInfo");
        if (!infoInstalled && AppMethod(info, @"identifier", "@") && AppMethod(info, @"productIdentifier", "@") &&
            AppMethod(info, @"isActive", @encode(BOOL)) && AppMethod(info, @"expirationDate", "@") &&
            AppMethod(info, @"willRenew", @encode(BOOL))) {
            EntitlementClass = info;
            AsignHookMethod(info, NSSelectorFromString(@"isActive"), (IMP)Active, (IMP *)&NativeActive, @encode(BOOL), NULL, NULL);
            AsignHookMethod(info, NSSelectorFromString(@"expirationDate"), (IMP)Expiration, (IMP *)&NativeExpiration, "@", NULL, NULL);
            AsignHookMethod(info, NSSelectorFromString(@"willRenew"), (IMP)WillRenew, (IMP *)&NativeWillRenew, @encode(BOOL), NULL, NULL);
            AsignHookMethod(info, NSSelectorFromString(@"isActiveInAnyEnvironment"), (IMP)ActiveAny, (IMP *)&NativeActiveAny, @encode(BOOL), NULL, NULL);
            AsignHookMethod(info, NSSelectorFromString(@"isActiveInCurrentEnvironment"), (IMP)ActiveCurrent, (IMP *)&NativeActiveCurrent, @encode(BOOL), NULL, NULL);
            infoInstalled = YES;
        }
        Class infos = NSClassFromString(@"RCEntitlementInfos");
        if (!infosInstalled && infoInstalled && AppMethod(infos, @"all", "@") && AppMethod(infos, @"active", "@")) {
            AsignHookMethod(infos, NSSelectorFromString(@"active"), (IMP)ActiveEntitlements, (IMP *)&NativeActiveEntitlements, "@", NULL, NULL);
            AsignHookMethod(infos, NSSelectorFromString(@"activeInAnyEnvironment"), (IMP)ActiveAnyEntitlements, (IMP *)&NativeActiveAnyEntitlements, "@", NULL, NULL);
            AsignHookMethod(infos, NSSelectorFromString(@"activeInCurrentEnvironment"), (IMP)ActiveCurrentEntitlements, (IMP *)&NativeActiveCurrentEntitlements, "@", NULL, NULL);
            infosInstalled = YES;
        }
        Class customer = NSClassFromString(@"RCCustomerInfo");
        if (!customerInstalled && infosInstalled && AppMethod(customer, @"entitlements", "@") &&
            AppMethod(customer, @"activeSubscriptions", "@") && AppMethod(customer, @"allPurchasedProductIdentifiers", "@")) {
            AsignHookMethod(customer, NSSelectorFromString(@"activeSubscriptions"), (IMP)ActiveSubscriptions, (IMP *)&NativeActiveSubscriptions, "@", NULL, NULL);
            AsignHookMethod(customer, NSSelectorFromString(@"allPurchasedProductIdentifiers"), (IMP)PurchasedProducts, (IMP *)&NativePurchasedProducts, "@", NULL, NULL);
            AsignHookMethod(customer, NSSelectorFromString(@"expirationDateForProductIdentifier:"), (IMP)ProductExpiration, (IMP *)&NativeProductExpiration, "@", "@", NULL);
            AsignHookMethod(customer, NSSelectorFromString(@"expirationDateForEntitlement:"), (IMP)EntitlementExpiration, (IMP *)&NativeEntitlementExpiration, "@", "@", NULL);
            AsignHookMethod(customer, NSSelectorFromString(@"purchaseDateForProductIdentifier:"), (IMP)ProductPurchaseDate, (IMP *)&NativeProductPurchaseDate, "@", "@", NULL);
            AsignHookMethod(customer, NSSelectorFromString(@"purchaseDateForEntitlement:"), (IMP)EntitlementPurchaseDate, (IMP *)&NativeEntitlementPurchaseDate, "@", "@", NULL);
            customerInstalled = YES;
        }
        Class product = NSClassFromString(@"RCStoreProduct");
        if (!productInstalled && AppMethod(product, @"productIdentifier", "@") && AppMethod(product, @"productType", @encode(NSInteger)) &&
            AppMethod(product, @"sk1Product", "@") && AppMethod(product, @"subscriptionPeriod", "@")) {
            NativeProductType = (void *)method_getImplementation(class_getInstanceMethod(product, NSSelectorFromString(@"productType")));
            AsignHookMethod(product, NSSelectorFromString(@"productIdentifier"), (IMP)ProductIdentifier, (IMP *)&NativeProductIdentifier, "@", NULL, NULL);
            productInstalled = YES;
        }
    }
}
