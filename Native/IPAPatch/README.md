# IPA header growth

`IPAPatch.c` handles header edits without changing executable layout. A return
of `KSIGN_IPA_HEADER_SPACE` selects `IPAPatchGrowth.cpp`, which adds at least
16 KiB using LIEF's Mach-O relocation and reconstruction support. Only cramped
ARM64 slices are rebuilt; every slice is retained. ARM64 references to the Mach
header and compact unwind addresses are updated as part of the transformation.

The original signature blob is retained for entitlement extraction by the
normal signer. The fallback does not create an intermediate ad hoc signature.
Changes are staged and atomically installed only after every slice succeeds.
The enclosing app transaction and end-of-signing warnings remain unchanged.

SDK archives are pinned by version and SHA256 in `lief.json`. `make native`
prepares the iOS static SDK; host tests prepare a matching host SDK. Both live
in the ignored `.build/ipa-patch-lief` directory and are cached by CI. The SDK
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

Run the native and optional Swift tests with:

```sh
python3 .github/scripts/test_ipa_patching.py
```

LIEF is Apache-2.0 licensed. Its license and attribution are bundled in app
resources. See https://lief.re/doc/stable/tutorials/11_macho_modification.html.
