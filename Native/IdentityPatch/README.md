# Original bundle identity companion

`asignIdentity.dylib` supplies the original identifier to app code after signing
changes `CFBundleIdentifier`. It is built from this directory's source during
the main Xcode target's **Build identity patch** phase and bundled as
`asignIdentity.dylib.bin`. `IPAPatcher` injects it alongside Blatant's library.
The packaging script rejects a build without the companion version marker.

Each app and extension gets its own `AsignOriginalBundleIdentifier` in its
Info.plist. Capture happens before native signing; the root identifier is also
captured before `onlyModify` edits. The first captured value survives subsequent
signing. A previously renamed input without this metadata provides no reliable
way to recover its earlier identity.

With compatibility patching enabled, signing also prevents accidental iCloud
enablement. `IPAPatcher` reads the original executable's XML signing entitlements
and records the cloud capability key names in `AsignOriginalCloudEntitlementKeys`
for each app/extension. Before signing that executable, zsign removes iCloud and
ubiquity keys from the selected profile when those keys weren't present in the
original app. Values for originally used keys still come from the selected
profile; this does not grant access to the original developer's containers.
Identity, keychain and app-group entitlements are left alone.

This avoids SwiftData's automatic CloudKit selection being enabled for a local
schema merely because the signing profile contains iCloud containers. Each bundle
gets its own policy, including when root and extension capabilities differ. The
first snapshot survives re-signing; publication rolls back with the dylib/identity
transaction. Unknown, malformed, conflicting universal or DER-only signatures
don't establish a policy. A previously re-signed input without a snapshot can't
reveal which cloud capabilities its original developer used: start with the
original IPA. An explicit custom entitlements file remains the user's override.
Disabling compatibility patching doesn't apply this signing policy.

The companion installs from Objective-C `+load`, before app initializers:

- `NSBundle.bundleIdentifier`, `infoDictionary`, `localizedInfoDictionary`,
  `objectForInfoDictionaryKey:` and `bundleWithIdentifier:` expose the original
  identity for annotated bundles. Other bundles retain their own identities.
- Imported `CFBundleGetIdentifier`, `CFBundleGetInfoDictionary`,
  `CFBundleGetLocalInfoDictionary`, `CFBundleGetValueForInfoDictionaryKey`,
  `CFBundleGetBundleWithIdentifier`, `CFBundleCopyInfoDictionaryForURL` and
  `CFBundleCopyInfoDictionaryInDirectory` get matching views.
- Immutable dictionary views are cached per source dictionary and original ID.
  CF Get/Copy ownership is retained. Foundation's real dictionaries are not
  mutated; signing and installation still use the selected identifier.
- C imports are rebound only inside the containing app and its embedded code,
  excluding the companion itself. A dyld callback includes later-loaded code.
  Legacy lazy imports use their indirect symbols; resolved ordinary GOT imports
  can also be matched by address for chained-fixup images. Matched pointer pages
  regain their previous protection after a write.

This is an API compatibility layer. Direct file reads, signing entitlement
queries, external services, function pointers obtained via `dlsym`, and private
or authenticated arm64e import paths are not rewritten. The rebinder explicitly
skips authenticated pointer sections rather than writing unsigned pointers into
them. It does not claim to conceal an installed identifier from every possible
inspection mechanism or grant capabilities associated with an original ID.

Run on macOS with Xcode and Swift installed:

```sh
python3 .github/scripts/test_identity_patch.py --require-apple
```

The suite compiles the production Swift transaction and the native companion.
It covers generic IDs, extension IDs, repeat signing, upgrading prepatched apps,
companion refresh and publication rollback. A host app checks `+load` and C
initializers, Foundation/CF getters and dictionary copies, nested bundles, the
unchanged on-disk installed ID, and late-loaded dylibs with chained and legacy
fixups. The cached manual build workflow requires this suite before building.
iOS device launch and extension behavior still require device validation.
