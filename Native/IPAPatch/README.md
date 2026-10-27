# IPA header growth

`IPAPatch.c` handles header edits without changing executable layout. A return
of `KSIGN_IPA_HEADER_SPACE` selects `IPAPatchGrowth.cpp`, which adds at least
16 KiB using LIEF's Mach-O relocation and reconstruction support. Only cramped
ARM64 slices are rebuilt; every slice is retained. ARM64 references to the Mach
header and compact unwind addresses are updated as part of the transformation.

Before staging edits, `IPAPatcher` scans every architecture for
`asignpatch.dylib` and either legacy name (`blatantsPatch.dylib` or
`asignIdentity.dylib`). New apps get one load and one file. Re-signing refreshes
the unified library. Legacy loads are rewritten in their existing ordinal
positions to the same unified library, preserving other dependency bindings.
An upgraded executable can retain multiple load commands to that one image;
only `asignpatch.dylib` is installed and loaded at runtime. Legacy root and
extension-local library files are removed in the rollback transaction, and
successful removals are recorded for archive-backed signing/rebuilds.

Read-only detection validates architecture and load-command tables without
imposing section-layout requirements on executables it leaves untouched. It
accepts strong and weak loads with an exact library basename. Detection does
not certify the original executable or repair existing damage.

The original signature blob is retained for entitlement extraction by the
normal signer. The fallback does not create an intermediate ad hoc signature.
Changes are staged and atomically installed only after every slice succeeds.
The enclosing app transaction and end-of-signing warnings remain unchanged.

The original bundle identifier is captured in `AsignOriginalBundleIdentifier`
for each app/extension Info.plist before native signing rewrites identifiers.
The root identity is captured before `onlyModify` edits as well. Existing
markers survive repeat signing. These plist edits share the executable/library
staging and rollback transaction. Sparse workspaces already include the plists;
current and legacy library paths are included in mutation and resource-hash exclusions.

See [the unified patch](../IdentityPatch/README.md) for runtime coverage and
build integration.

SDK archives are pinned by version and SHA256 in `lief.json`. `make native`
prepares the iOS static SDK in the ignored `.build/ipa-patch-lief` directory,
which is cached by CI. The SDK
is linked statically for devices. Simulator builds retain the header-only path.

The iOS SDK's default logger opens `/tmp/lief.log` before any logging API can
disable or replace it. That path is outside an app's writable container, and
the SDK's spdlog aborts on the failed open. After verifying the release checksum,
SDK preparation redirects the single default filename to `/dev/null`, padding
the replacement to the original length so archive and object offsets stay
unchanged. Preparation fails if the pinned SDK no longer has exactly one such
filename. The preparation stamp and CI cache include this adjustment; existing
SDK caches are rebuilt. The runtime still disables logging before parsing.

Before opening Xcode directly, run:

```sh
python3 .github/scripts/prepare_ipa_patch_lief.py --target ios
```

LIEF is Apache-2.0 licensed. Its license and attribution are bundled in app
resources. See https://lief.re/doc/stable/tutorials/11_macho_modification.html.
