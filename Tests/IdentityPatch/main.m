#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *DuringLoad;
static CFStringRef DuringInitializer;

@interface AppLaunchProbe : NSObject
@end
@implementation AppLaunchProbe
+ (void)load { @autoreleasepool { DuringLoad = NSBundle.mainBundle.bundleIdentifier; } }
@end
__attribute__((constructor)) static void earlyProbe(void) {
    DuringInitializer = CFBundleGetIdentifier(CFBundleGetMainBundle());
}

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}
static void verify(NSBundle *bundle, NSString *original) {
    check([bundle.bundleIdentifier isEqual:original], "NSBundle.bundleIdentifier did not preserve original ID");
    check([bundle.infoDictionary[@"CFBundleIdentifier"] isEqual:original], "NSBundle.infoDictionary did not preserve original ID");
    check([[bundle objectForInfoDictionaryKey:@"CFBundleIdentifier"] isEqual:original], "NSBundle value lookup did not preserve original ID");
    if (bundle.localizedInfoDictionary) {
        check([bundle.localizedInfoDictionary[@"CFBundleIdentifier"] isEqual:original], "Localized dictionary did not preserve original ID");
    }
    CFBundleRef cf = CFBundleCreate(NULL, (__bridge CFURLRef)bundle.bundleURL);
    check(cf != NULL, "Unable to create CF bundle");
    check([(__bridge NSString *)CFBundleGetIdentifier(cf) isEqual:original], "CF identifier did not preserve original ID");
    CFDictionaryRef info = CFBundleGetInfoDictionary(cf);
    check([(__bridge NSString *)CFDictionaryGetValue(info, CFSTR("CFBundleIdentifier")) isEqual:original], "CF dictionary did not preserve original ID");
    check([(__bridge NSString *)CFBundleGetValueForInfoDictionaryKey(cf, CFSTR("CFBundleIdentifier")) isEqual:original], "CF key lookup did not preserve original ID");
    CFDictionaryRef localized = CFBundleGetLocalInfoDictionary(cf);
    if (localized) check([(__bridge NSString *)CFDictionaryGetValue(localized, CFSTR("CFBundleIdentifier")) isEqual:original], "CF localized dictionary did not preserve original ID");
    CFDictionaryRef copied = CFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)bundle.bundleURL);
    check(copied != NULL && [(__bridge NSString *)CFDictionaryGetValue(copied, CFSTR("CFBundleIdentifier")) isEqual:original], "CF copy lookup failed");
    CFRelease(copied);
    copied = CFBundleCopyInfoDictionaryInDirectory((__bridge CFURLRef)bundle.bundleURL);
    check(copied != NULL && [(__bridge NSString *)CFDictionaryGetValue(copied, CFSTR("CFBundleIdentifier")) isEqual:original], "CF directory copy lookup failed");
    CFRelease(copied);
    check([NSBundle bundleWithIdentifier:original] != nil, "NSBundle original-ID bundle lookup failed");
    check(CFBundleGetBundleWithIdentifier((__bridge CFStringRef)original) != NULL, "CF original-ID bundle lookup failed");
    CFRelease(cf);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        check(argc == 4, "Expected nested bundle and two late-load libraries");
        check([DuringLoad isEqual:@"org.example.original"], "Patch was too late for app +load");
        check([(__bridge NSString *)DuringInitializer isEqual:@"org.example.original"], "Patch was too late for app constructor");
        unsigned patchImages = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            NSString *name = [@(_dyld_get_image_name(i)) lastPathComponent];
            if ([name isEqualToString:@"asignpatch.dylib"]) ++patchImages;
            check(![name isEqualToString:@"asignIdentity.dylib"] && ![name isEqualToString:@"blatantsPatch.dylib"],
                  "A legacy patch image was loaded");
        }
        check(patchImages == 1, "Expected exactly one unified patch image");
        check([NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"../escape"] == nil,
              "Invalid app group escaped its directory");
        verify(NSBundle.mainBundle, @"org.example.original");
        NSBundle *nested = [NSBundle bundleWithPath:@(argv[1])];
        check(nested != nil, "Nested fixture bundle is missing");
        verify(nested, @"org.example.original.share");
        NSBundle *foundation = [NSBundle bundleForClass:NSObject.class];
        check(![foundation.bundleIdentifier isEqual:@"org.example.original"], "Changed unrelated framework identity");
        NSDictionary *raw = [NSDictionary dictionaryWithContentsOfURL:[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Info.plist"]];
        check([raw[@"CFBundleIdentifier"] isEqual:@"org.example.renamed"], "Changed actual on-disk signing identity");
        for (int i = 2; i < argc; ++i) {
            void *handle = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
            check(handle != NULL, "Late-load fixture failed to open");
            CFStringRef (*probe)(void) = dlsym(handle, "ProbeOriginalIdentity");
            check(probe && [(__bridge NSString *)probe() isEqual:@"org.example.original"], "Late-loaded CF lookup missed original ID");
            dlclose(handle);
        }
        printf("Launch, NSBundle, CFBundle, nested bundle, copy ownership and late-load identity tests passed\n");
    }
    return 0;
}
