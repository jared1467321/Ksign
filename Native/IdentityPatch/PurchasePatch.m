#import "PurchasePatch.h"
#import "PatchOptions.h"
#import "PatchPolicy.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <string.h>

static atomic_bool StoreKitScheduled;

static void PurchaseImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    Dl_info image;
    if (!dladdr(header, &image) || !image.dli_fname ||
        (!strstr(image.dli_fname, "/StoreKit.framework/") && !AsignPatchCallerIsApp(header))) return;
    // Runtime class registration must finish before inspecting Objective-C
    // methods. Do not take Objective-C locks inside the loader callback.
    if (!atomic_exchange(&StoreKitScheduled, true)) dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&StoreKitScheduled, false);
        AsignInstallStoreKitPurchasePatch();
        AsignInstallPurchaseSDKPatch();
    });
}

void AsignInstallPurchasePatch(void) {
    if (!AsignPatchEnabled(AsignPatchLocalPurchases)) return;
    AsignInstallStoreKitPurchasePatch();
    AsignInstallRevenueCatPurchasePatch();
    AsignInstallPurchaseSDKPatch();
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _dyld_register_func_for_add_image(PurchaseImageAdded); });
}
