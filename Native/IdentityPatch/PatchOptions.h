#ifndef ASIGN_PATCH_OPTIONS_H
#define ASIGN_PATCH_OPTIONS_H

// Diagnostic builds only. The normal build leaves every family enabled and
// registers imports before app initializers. No app-facing switches are added.
#ifndef ASIGN_PATCH_DISABLED_HOOKS
#define ASIGN_PATCH_DISABLED_HOOKS 0
#endif
#ifndef ASIGN_PATCH_DEFER_IMAGE_CALLBACKS
#define ASIGN_PATCH_DEFER_IMAGE_CALLBACKS 0
#endif

enum {
    AsignPatchIdentity = 1 << 0,
    AsignPatchKeychain = 1 << 1,
    AsignPatchAppGroups = 1 << 2,
    AsignPatchCloudKit = 1 << 3,
    AsignPatchBackgroundAssets = 1 << 4,
    AsignPatchModuleTrace = 1 << 5,
    AsignPatchImageCallbacks = 1 << 6
};

#if ASIGN_PATCH_DISABLED_HOOKS || ASIGN_PATCH_DEFER_IMAGE_CALLBACKS
// Visible in the built library so a diagnostic artifact can be distinguished
// from a normal patch even after packaging or re-signing.
__attribute__((used)) static const char AsignPatchDiagnosticVersion[] = "AsignPatchDiagnostic/v1";
#endif

static inline int AsignPatchEnabled(unsigned family) {
    return !(ASIGN_PATCH_DISABLED_HOOKS & family);
}
#endif
