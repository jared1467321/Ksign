#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import "SubscriptionPatch.h"
#import "PatchPolicy.h"
#import "MethodHook.h"

__attribute__((used, visibility("default")))
const char AsignSubscriptionPatchVersion[] = "AsignSubscriptionPatch/v1";

static NSString *const RegistrationEntitlement = @"com.apple.smoot.subscriptionservice";
static void (*OriginalRegistration)(id, SEL, id);

static BOOL NeedsSubscriptionPatch(void) {
    // Setup runs before our identity hooks. A previously patched IPA without
    // this first snapshot is unknown; never infer permission from its profile.
    CFDictionaryRef info = CFBundleGetInfoDictionary(CFBundleGetMainBundle());
    CFTypeRef original = info ? CFDictionaryGetValue(info, CFSTR("AsignOriginalSubscriptionRegistration")) : NULL;
    if (!original || CFGetTypeID(original) != CFBooleanGetTypeID() ||
        !CFBooleanGetValue((CFBooleanRef)original)) return NO;

    CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFDictionaryRef (*copy)(CFTypeRef, CFArrayRef, CFErrorRef *) =
        dlsym(RTLD_DEFAULT, "SecTaskCopyValuesForEntitlements");
    if (!create || !copy) return NO;
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return NO;
    NSArray *keys = @[RegistrationEntitlement];
    CFErrorRef error = NULL;
    CFDictionaryRef values = copy(task, (__bridge CFArrayRef)keys, &error);
    BOOL missing = NO;
    if (values && !error && CFGetTypeID(values) == CFDictionaryGetTypeID()) {
        CFTypeRef installed = CFDictionaryGetValue(values, (__bridge CFStringRef)RegistrationEntitlement);
        // Only an absent key or a Boolean false proves lost permission.
        // Strings, integers and failed signature reads keep the SDK untouched.
        missing = !installed || (CFGetTypeID(installed) == CFBooleanGetTypeID() &&
                                !CFBooleanGetValue((CFBooleanRef)installed));
    }
    if (values) CFRelease(values);
    if (error) CFRelease(error);
    CFRelease(task);
    return missing;
}

static void RegisterSubscription(id self, SEL selector, id subscription) {
    // This method only informs Apple's TV app about the user's subscription.
    // Skip app-owned calls under the proven missing permission; system callers
    // still use the original implementation, including its exception behavior.
    if (!AsignPatchCallerIsApp(__builtin_return_address(0))) {
        OriginalRegistration(self, selector, subscription);
    }
}

void AsignInstallSubscriptionPatch(void) {
    if (!NeedsSubscriptionPatch()) return;
    // Do not load an optional framework or modify any method table when the
    // class is absent. Check the complete calling ABI before installing.
    Class center = NSClassFromString(@"VSSubscriptionRegistrationCenter");
    AsignHookMethod(center, sel_registerName("setCurrentSubscription:"),
        (IMP)RegisterSubscription, (IMP *)&OriginalRegistration, "v", "@", NULL);
}
