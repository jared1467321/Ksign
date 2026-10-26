#!/usr/bin/env python3
"""Check CloudKit installation policy against the real Objective-C runtime.

Requires macOS and Apple's SDK. Each scenario runs in a fresh process so a
previous swizzle or dispatch_once cannot conceal an installation-policy error.
Store-loading checks replace SDK loading with a recorder before installing the
patch. No cloud containers, accounts, keychain or network APIs are used.
"""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Native/IdentityPatch"
CONTAINER = "iCloud.example.original"
OTHER = "iCloud.example.other"
SERVICES = "com.apple.developer.icloud-services"
CONTAINERS = "com.apple.developer.icloud-container-identifiers"

FIXTURE = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
#define ASIGN_CLOUDKIT_TESTING 1
#import "CloudKitPatch.m"

static NSDictionary *TestEntitlements, *TestInfo;
static NSBundle *TestBundle;
static NSDictionary *(*RealInfo)(NSBundle *, SEL);
static unsigned EntitlementReads;
static NSArray *ExpectedDescriptions;
static StoreCompletion ExpectedCompletion;
static unsigned ForwardedLoads;
static BOOL AllowDescriptionCopy;

NSDictionary *AsignTestCloudEntitlements(void) {
    ++EntitlementReads;
    return TestEntitlements;
}

bool AsignInitializeLocalCloudConfiguration(void *destination, const char *identifier) {
    (void)destination; (void)identifier;
    return false;
}

static NSDictionary *Info(NSBundle *self, SEL selector) {
    return self == TestBundle ? TestInfo : RealInfo(self, selector);
}

static void Require(BOOL success, const char *message) {
    if (!success) { fprintf(stderr, "%s\n", message); exit(1); }
}

static void RecordLoad(id self, SEL selector, NSArray *descriptions, StoreCompletion completion) {
    (void)self; (void)selector;
    Require(AllowDescriptionCopy ? [descriptions isEqual:ExpectedDescriptions] : descriptions == ExpectedDescriptions,
            "Store description argument was replaced");
    Require(AllowDescriptionCopy || completion == ExpectedCompletion, "Store completion handler was replaced");
    ++ForwardedLoads;
    for (NSPersistentStoreDescription *description in descriptions) completion(description, nil);
}

static void RecordPublicLoad(NSPersistentCloudKitContainer *self, SEL selector, StoreCompletion completion) {
    RecordLoad(self, selector, self.persistentStoreDescriptions, completion);
}

static void CheckStoreLoading(NSString *entry, BOOL local) {
    NSPersistentCloudKitContainer *container = [[NSPersistentCloudKitContainer alloc]
        initWithName:@"PatchChecks" managedObjectModel:[[NSManagedObjectModel alloc] init]];
    NSPersistentStoreDescription *unavailable = [NSPersistentStoreDescription persistentStoreDescriptionWithURL:
        [NSURL fileURLWithPath:@"/unused/unavailable.sqlite"]];
    NSPersistentStoreDescription *authorized = [NSPersistentStoreDescription persistentStoreDescriptionWithURL:
        [NSURL fileURLWithPath:@"/unused/authorized.sqlite"]];
    NSPersistentStoreDescription *plain = [NSPersistentStoreDescription persistentStoreDescriptionWithURL:
        [NSURL fileURLWithPath:@"/unused/local.sqlite"]];
    unavailable.cloudKitContainerOptions = [[NSPersistentCloudKitContainerOptions alloc]
        initWithContainerIdentifier:@"iCloud.example.other"];
    authorized.cloudKitContainerOptions = [[NSPersistentCloudKitContainerOptions alloc]
        initWithContainerIdentifier:@"iCloud.example.original"];
    unavailable.configuration = @"PreservedConfiguration";
    unavailable.shouldMigrateStoreAutomatically = NO;
    unavailable.shouldInferMappingModelAutomatically = NO;
    [unavailable setOption:@YES forKey:NSPersistentHistoryTrackingKey];
    NSURL *url = unavailable.URL;
    NSDictionary *options = unavailable.options;
    NSPersistentCloudKitContainerOptions *unavailableOptions = unavailable.cloudKitContainerOptions;
    NSPersistentCloudKitContainerOptions *authorizedOptions = authorized.cloudKitContainerOptions;
    ExpectedDescriptions = @[unavailable, authorized, plain];
    __block unsigned completions = 0;
    ExpectedCompletion = ^(NSPersistentStoreDescription *description, NSError *error) {
        Require([ExpectedDescriptions containsObject:description] && !error, "Store callback changed");
        Require(local ? unavailable.cloudKitContainerOptions == nil :
                       unavailable.cloudKitContainerOptions == unavailableOptions,
                "Store options were not prepared before forwarding");
        ++completions;
    };
    // For the internal entry, the explicit array must win over the property.
    NSPersistentStoreDescription *unused = [[NSPersistentStoreDescription alloc] init];
    unused.cloudKitContainerOptions = unavailableOptions;
    container.persistentStoreDescriptions = [entry isEqual:@"internal"] ? @[unused] : ExpectedDescriptions;
    if ([entry isEqual:@"public"]) {
        [container loadPersistentStoresWithCompletionHandler:ExpectedCompletion];
    } else if ([entry isEqual:@"base"]) {
        // Reproduce a caller entering the superclass implementation directly.
        // The public subclass hook cannot help; only the internal hook can
        // prepare these stores before our stand-in mirroring entry runs.
        AllowDescriptionCopy = YES;
        IMP baseLoad = method_getImplementation(class_getInstanceMethod(NSPersistentContainer.class,
            @selector(loadPersistentStoresWithCompletionHandler:)));
        ((void (*)(id, SEL, StoreCompletion))baseLoad)(container,
            @selector(loadPersistentStoresWithCompletionHandler:), ExpectedCompletion);
    } else {
        ((void (*)(id, SEL, NSArray *, StoreCompletion))objc_msgSend)(container,
            NSSelectorFromString(@"_loadStoreDescriptions:withCompletionHandler:"),
            ExpectedDescriptions, ExpectedCompletion);
    }
    Require(ForwardedLoads == 1 && completions == 3, "Store loading was dropped or duplicated");
    Require(authorized.cloudKitContainerOptions == authorizedOptions && !plain.cloudKitContainerOptions,
            "Authorized or local store options changed");
    Require(unused.cloudKitContainerOptions == unavailableOptions, "Unrequested store was changed");
    Require([unavailable.URL isEqual:url] && [unavailable.options isEqual:options] &&
            [unavailable.configuration isEqual:@"PreservedConfiguration"] &&
            !unavailable.shouldMigrateStoreAutomatically && !unavailable.shouldInferMappingModelAutomatically,
            "Local store location, configuration, migration or history options changed");
    ExpectedCompletion = nil;
    ExpectedDescriptions = nil;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        Require(argc == 2, "Expected one JSON scenario");
        NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:
            [[NSString stringWithUTF8String:argv[1]] dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:NULL];
        Require(fixture != nil, "Invalid scenario");
        id signedValues = fixture[@"signed"];
        TestEntitlements = signedValues == NSNull.null ? nil : signedValues;
        TestBundle = NSBundle.mainBundle;
        NSMutableDictionary *info = [TestBundle.infoDictionary mutableCopy] ?: [NSMutableDictionary dictionary];
        id originals = fixture[@"originals"];
        if (originals != NSNull.null) info[@"AsignOriginalCloudContainerIdentifiers"] = originals;
        else [info removeObjectForKey:@"AsignOriginalCloudContainerIdentifiers"];
        TestInfo = [info copy];
        Method infoMethod = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
        RealInfo = (void *)method_setImplementation(infoMethod, (IMP)Info);

        BOOL expected = [fixture[@"hooks"] boolValue];
        Class container = NSClassFromString(@"CKContainer");
        SEL containerSelector = NSSelectorFromString(@"containerWithIdentifier:");
        Class storeClass = NSPersistentCloudKitContainer.class;
        SEL storeSelector = @selector(loadPersistentStoresWithCompletionHandler:);
        SEL descriptionsSelector = NSSelectorFromString(@"_loadStoreDescriptions:withCompletionHandler:");
        Method descriptionsMethod = class_getInstanceMethod(storeClass, descriptionsSelector);
        NSString *storeEntry = fixture[@"store_entry"];
        if (storeEntry) {
            Require(descriptionsMethod != NULL, "SDK lacks the internal store-loading entry");
            class_replaceMethod(storeClass, storeSelector, (IMP)RecordPublicLoad,
                method_getTypeEncoding(class_getInstanceMethod(storeClass, storeSelector)));
            class_replaceMethod(storeClass, descriptionsSelector, (IMP)RecordLoad,
                method_getTypeEncoding(descriptionsMethod));
            descriptionsMethod = class_getInstanceMethod(storeClass, descriptionsSelector);
        }
        Method containerMethod = class_getClassMethod(container, containerSelector);
        Method storeMethod = class_getInstanceMethod(storeClass, storeSelector);
        Method parentStoreMethod = class_getInstanceMethod(class_getSuperclass(storeClass), storeSelector);
        Require(containerMethod != NULL && storeMethod != NULL, "Missing public SDK methods");
        IMP containerBefore = method_getImplementation(containerMethod);
        IMP storeBefore = method_getImplementation(storeMethod);
        IMP parentBefore = parentStoreMethod ? method_getImplementation(parentStoreMethod) : NULL;
        IMP descriptionsBefore = descriptionsMethod ? method_getImplementation(descriptionsMethod) : NULL;

        AsignInstallCloudKitPatch();
        // Hook may add an override for an inherited method. A Method captured
        // before installation still refers to the superclass in that case.
        // Resolve the effective method again on the class actually being used.
        IMP containerAfter = method_getImplementation(class_getClassMethod(container, containerSelector));
        IMP storeAfter = method_getImplementation(class_getInstanceMethod(storeClass, storeSelector));
        Require((containerAfter != containerBefore) == expected,
                "CloudKit method installation disagrees with expected policy");
        Require((storeAfter != storeBefore) == expected,
                "Core Data method installation disagrees with expected policy");
        Require(!parentStoreMethod || method_getImplementation(parentStoreMethod) == parentBefore,
                "CloudKit override modified the superclass implementation");
        Require(expected ? (IMP)OriginalLoadPersistentStores == storeBefore : OriginalLoadPersistentStores == NULL,
                "Core Data forwarding implementation disagrees with installation policy");
        if (descriptionsMethod) {
            IMP after = method_getImplementation(class_getInstanceMethod(storeClass, descriptionsSelector));
            Require((after != descriptionsBefore) == expected,
                    "Internal Core Data installation disagrees with expected policy");
            Require(expected ? (IMP)OriginalLoadStoreDescriptions == descriptionsBefore :
                               OriginalLoadStoreDescriptions == NULL,
                    "Internal Core Data forwarding implementation changed");
        }
        AsignIdentityBinding automatic = AsignCloudKitAutomaticBinding();
        Require((automatic.replacement != NULL) == [fixture[@"automatic"] boolValue],
                "SwiftData import selection disagrees with expected policy");
        if (!automatic.replacement) Require(automatic.original == NULL && automatic.name == NULL,
                                          "Skipped SwiftData binding must be entirely empty");
        if ([fixture[@"no_entitlement_read"] boolValue]) {
            Require(EntitlementReads == 0, "Local or unknown-original app queried cloud capabilities");
        }
        if (fixture[@"authorized_request"]) {
            Require(!NeedsLocal(fixture[@"authorized_request"]), "Authorized container changed to local mode");
            Require(NeedsLocal(fixture[@"unavailable_request"]), "Unavailable container lost its local fallback");
        }
        if (storeEntry) CheckStoreLoading(storeEntry, expected);
    }
    return 0;
}
'''


@unittest.skipUnless(platform.system() == "Darwin", "Requires Apple's macOS SDK and Objective-C runtime")
class CloudKitPatchChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="asign-cloudkit-check-")
        cls.addClassCleanup(cls.scratch.cleanup)
        root = Path(cls.scratch.name)
        source = root / "checks.m"
        source.write_text(FIXTURE)
        cls.executable = root / "checks"
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        compiler = subprocess.check_output(["xcrun", "--sdk", "macosx", "--find", "clang"], text=True).strip()
        subprocess.run([compiler, "-isysroot", sdk, "-std=gnu11", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                        "-I", str(SOURCE), str(source), "-framework", "Foundation", "-framework", "Security",
                        "-framework", "CoreData", "-framework", "CloudKit", "-o", str(cls.executable)], check=True)

    def check(self, originals, signed, *, hooks=False, automatic=False, no_read=False, **extra):
        scenario = dict(originals=originals, signed=signed, hooks=hooks, automatic=automatic,
                        no_entitlement_read=no_read, **extra)
        result = subprocess.run([str(self.executable), json.dumps(scenario)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_apps_without_original_cloudkit_containers_install_nothing(self):
        for originals in (None, [], "iCloud.invalid-type", [CONTAINER, 123], ["not-a-container"], ["iCloud.*"]):
            with self.subTest(originals=originals):
                self.check(originals, {SERVICES: ["CloudKit"], CONTAINERS: [OTHER]}, no_read=True)

    def test_authorized_app_installs_nothing(self):
        self.check([CONTAINER], {SERVICES: ["CloudKit"], CONTAINERS: [CONTAINER]})
        self.check([CONTAINER, OTHER], {SERVICES: ["CloudKit"], CONTAINERS: [CONTAINER, OTHER]})

    def test_unknown_or_malformed_signed_capabilities_install_nothing(self):
        for signed in (None, [], {SERVICES: "CloudKit"}, {CONTAINERS: CONTAINER},
                       {SERVICES: [123]}, {CONTAINERS: [123]}, {CONTAINERS: ["iCloud.*"]}):
            with self.subTest(signed=signed):
                self.check([CONTAINER], signed)

    def test_lost_capabilities_keep_local_fallback(self):
        for signed in ({}, {SERVICES: ["CloudKit"]}, {CONTAINERS: [CONTAINER]},
                       {SERVICES: ["CloudKit"], CONTAINERS: []}):
            with self.subTest(signed=signed):
                self.check([CONTAINER], signed, hooks=True, automatic=True)

    def test_other_usable_container_leaves_swiftdata_import_untouched(self):
        self.check([CONTAINER], {SERVICES: ["CloudKit"], CONTAINERS: [OTHER]}, hooks=True)

    def test_mixed_containers_preserve_authorized_requests(self):
        self.check([CONTAINER, OTHER], {SERVICES: ["CloudKit"], CONTAINERS: [CONTAINER]}, hooks=True,
                   authorized_request=CONTAINER, unavailable_request=OTHER)

    def test_store_loading_preserves_mixed_stores_and_callbacks(self):
        for entry in ("public", "internal", "base"):
            with self.subTest(entry=entry):
                self.check([CONTAINER, OTHER], {SERVICES: ["CloudKit"], CONTAINERS: [CONTAINER]},
                           hooks=True, store_entry=entry)

    def test_authorized_and_unknown_store_loading_passes_through(self):
        for entry in ("public", "internal", "base"):
            for signed in (None, {SERVICES: ["CloudKit"], CONTAINERS: [CONTAINER, OTHER]}):
                with self.subTest(entry=entry, signed=signed):
                    self.check([CONTAINER, OTHER], signed, store_entry=entry)


if __name__ == "__main__":
    unittest.main(verbosity=2)
