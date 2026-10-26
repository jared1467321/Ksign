#import "PatchPolicy.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

static NSDictionary *SignedCapabilities;
static NSDictionary *OriginalInfo;
static char *AppScope, *CanonicalScope;
static const void *SelfImage;

static BOOL ConcreteIdentifier(id value) {
    return [value isKindOfClass:NSString.class] && [value length] &&
        ![value isEqualToString:@"."] && ![value isEqualToString:@".."] &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*/\\"]].location == NSNotFound;
}

static NSArray *Identifiers(id value) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    for (id identifier in value) if (!ConcreteIdentifier(identifier)) return nil;
    return value;
}

void AsignInitializePatchPolicy(void) {
    // Run once, before our NSBundle swizzles or import replacements exist.
    CFBundleRef main = CFBundleGetMainBundle();
    OriginalInfo = [(__bridge NSDictionary *)CFBundleGetInfoDictionary(main) copy];
    NSURL *scope = CFBridgingRelease(CFBundleCopyBundleURL(main));
    for (NSURL *parent = scope; parent.path.length > 1; parent = parent.URLByDeletingLastPathComponent) {
        if ([parent.pathExtension isEqualToString:@"app"]) { scope = parent; break; }
    }
    if (scope) {
        AppScope = strdup(scope.path.fileSystemRepresentation);
        CanonicalScope = realpath(scope.path.fileSystemRepresentation, NULL);
    }
    Dl_info image;
    if (dladdr((const void *)&AsignInitializePatchPolicy, &image)) SelfImage = image.dli_fbase;

    // Inspect the signature itself. A provisioning profile or a rewritten
    // bundle identifier is not evidence that a requested group is authorized.
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFDictionaryRef (*copy)(CFTypeRef, CFArrayRef, CFErrorRef *) =
        dlsym(RTLD_DEFAULT, "SecTaskCopyValuesForEntitlements");
    if (!create || !copy) return;
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return;
    NSArray *keys = @[@"keychain-access-groups", @"application-identifier", @"com.apple.security.application-groups"];
    CFErrorRef error = NULL;
    CFDictionaryRef values = copy(task, (__bridge CFArrayRef)keys, &error);
    if (values && !error && CFGetTypeID(values) == CFDictionaryGetTypeID()) {
        SignedCapabilities = [(__bridge NSDictionary *)values copy];
    }
    if (values) CFRelease(values);
    if (error) CFRelease(error);
    CFRelease(task);
}

static BOOL InsideScope(const char *path, const char *scope) {
    if (!scope) return NO;
    size_t length = strlen(scope);
    return !strncmp(path, scope, length) && path[length] == '/';
}

BOOL AsignPatchCallerIsApp(const void *caller) {
    Dl_info image;
    if (!caller || !dladdr(caller, &image) || !image.dli_fname || image.dli_fbase == SelfImage) return NO;
    return InsideScope(image.dli_fname, AppScope) || InsideScope(image.dli_fname, CanonicalScope);
}

BOOL AsignOriginalAppGroup(NSString *identifier) {
    return ConcreteIdentifier(identifier) &&
        [Identifiers(OriginalInfo[@"AsignOriginalAppGroupIdentifiers"]) containsObject:identifier];
}

BOOL AsignAppGroupNeedsFallback(NSString *identifier) {
    if (!AsignOriginalAppGroup(identifier) || !SignedCapabilities) return NO;
    id value = SignedCapabilities[@"com.apple.security.application-groups"];
    NSArray *groups = value ? Identifiers(value) : @[];
    return groups && ![groups containsObject:identifier];
}

NSArray *AsignInstalledAppGroups(void) {
    return Identifiers(SignedCapabilities[@"com.apple.security.application-groups"]);
}

NSString *AsignKeychainReplacementGroup(id identifier) {
    if (!ConcreteIdentifier(identifier) || !SignedCapabilities ||
        ![Identifiers(OriginalInfo[@"AsignOriginalKeychainAccessGroups"]) containsObject:identifier]) return nil;
    id keychainValue = SignedCapabilities[@"keychain-access-groups"];
    id appGroupValue = SignedCapabilities[@"com.apple.security.application-groups"];
    NSArray *keychain = keychainValue ? Identifiers(keychainValue) : @[];
    NSArray *appGroups = appGroupValue ? Identifiers(appGroupValue) : @[];
    id appID = SignedCapabilities[@"application-identifier"];
    if (!keychain || !appGroups || (appID && !ConcreteIdentifier(appID))) return nil;
    if ([keychain containsObject:identifier] || [appGroups containsObject:identifier] || [appID isEqual:identifier]) return nil;
    // Match Keychain Services' default without creating a probe item. Queries
    // that omit an access group must keep their native all-groups semantics.
    return keychain.firstObject ?: appID;
}

BOOL AsignNeedsKeychainPatch(void) {
    for (NSString *identifier in Identifiers(OriginalInfo[@"AsignOriginalKeychainAccessGroups"])) {
        if (AsignKeychainReplacementGroup(identifier)) return YES;
    }
    return NO;
}

BOOL AsignNeedsAppGroupPatch(void) {
    id snapshot = OriginalInfo[@"AsignOriginalAppGroupIdentifiers"];
    if (snapshot) return Identifiers(snapshot).count > 0;
    // Older patches did not snapshot groups. Keep read-only discovery of
    // existing legacy folders, but do not create new fallback directories.
    return AsignPreservesLegacyGroupDirectories();
}

BOOL AsignPreservesLegacyGroupDirectories(void) {
    id value = OriginalInfo[@"AsignPreserveLegacyGroupDirectories"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
