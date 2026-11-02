#pragma once
#import <Foundation/Foundation.h>

void AsignInstallPurchasePatch(void);
void AsignInstallStoreKitPurchasePatch(void);
void AsignInstallRevenueCatPurchasePatch(void);

// Created lazily on the first purchase call, in this application's container.
NSDictionary *AsignLocalPurchases(void);
void AsignActivateLocalPurchases(void);
BOOL AsignLocalPurchasesActive(void);
NSDictionary *AsignLocalPendingPurchases(void);
NSDictionary *AsignRecordLocalPurchase(NSString *product, NSInteger quantity);
void AsignFinishLocalPurchase(NSString *transaction);
NSString *AsignLocalTransactionIdentifier(void);
NSData *AsignLocalReceipt(void);
NSURL *AsignLocalReceiptURL(void);
NSDictionary *AsignLocalReceiptResponse(void);

// RevenueCat mappings are scoped to the application's public API key.
void AsignRememberPurchaseMapping(NSString *scope, NSDictionary *response);
NSDictionary *AsignPurchaseMapping(NSString *scope);
NSDictionary *AsignLocalSubscriberResponse(NSString *scope, NSString *user, NSDictionary *response);

// A genuine subclass is needed for Swift's SKProduct/SKPaymentTransaction casts.
// No StoreKit framework is loaded by the patch just to create these classes.
id AsignLocalStoreObject(NSString *parent, NSString *name, NSDictionary *values);
BOOL AsignIsLocalStoreObject(id object);
id AsignPurchaseObjectValue(id object, NSString *selector);
