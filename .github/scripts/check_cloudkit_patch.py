#!/usr/bin/env python3
"""Check CloudKit installation policy against the real Objective-C runtime.

Requires macOS and Apple's SDK. Each scenario runs in a fresh process so a
previous swizzle or dispatch_once cannot conceal an installation-policy error.
No containers are constructed and no account, keychain or network APIs are used.
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
        Method containerMethod = class_getClassMethod(container, @selector(containerWithIdentifier:));
        Method storeMethod = class_getInstanceMethod(NSPersistentCloudKitContainer.class,
            @selector(loadPersistentStoresWithCompletionHandler:));
        Require(containerMethod != NULL && storeMethod != NULL, "Missing public SDK methods");
        IMP containerBefore = method_getImplementation(containerMethod);
        IMP storeBefore = method_getImplementation(storeMethod);

        AsignInstallCloudKitPatch();
        Require((method_getImplementation(containerMethod) != containerBefore) == expected,
                "CloudKit method installation disagrees with expected policy");
        Require((method_getImplementation(storeMethod) != storeBefore) == expected,
                "Core Data method installation disagrees with expected policy");
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
        compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
        subprocess.run([compiler, "-std=gnu11", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
