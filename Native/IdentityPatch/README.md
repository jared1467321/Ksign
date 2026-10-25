# Unified Asign compatibility patch

`asignpatch.dylib` contains the bundle identity, keychain, app-group,
NSUserDefaults and CloudKit compatibility code in one source-built library.
The main Xcode target's **Build Asign patch** phase bundles it as
`asignpatch.dylib.bin`; the packaging script requires both implementation
version markers and removes stale two-library resources from cached products.
There is no runtime dependency on either former patch library.

`CompatibilityPatch.m` carries the legacy patch's behavior: keychain queries
use the signing profile's accessible group discovered by a probe; app-group
folders live below the first available shared group, or Documents when no
shared group exists; group defaults use the shared folder when available.
The original probe account/service and folder layout are retained for upgrades.
The four Security imports keep the legacy process-wide coverage, while
identity imports remain scoped to the app and its embedded code.

CloudKit handling is conditional. `CloudKitPatch.m` reads the running process's
signed capabilities through SecTask, independently of any SDK compatibility
view. A requested container passes through unchanged when its exact identifier
is permitted and the signature enables CloudKit. A failed capability lookup is
unknown, not a denial, and retains normal SDK behavior.

For a known unavailable container, the patch still runs the real container and
database initializers. A thread-local SDK entitlement view permits local object
construction; it does not change the signature, profile, Security entitlement
queries, or Apple's service authorization. Unlike the old nil/no-setup hooks,
Swift receives valid objects. Local containers report a restricted cloud account
and a not-authenticated error for user-record requests. Container/database
operations are cancelled before original SDK queuing, so SDK completion handling
still runs and remote writes are not reported as successful.

Core Data's `NSPersistentCloudKitContainer` gets a per-store check before
`loadPersistentStoresWithCompletionHandler:` starts. When a store's requested
CloudKit container is known to be unavailable under the installed signature,
its `cloudKitContainerOptions` is cleared so Core Data loads the local store
without initializing cloud mirroring. Authorized containers, already-local
stores and unknown capability lookups retain normal behavior, including in
containers with a mixture of local and cloud-backed stores. Store URLs,
configurations, migration settings and completion handlers are retained. The
library links Core Data so this hook is available when the patch installs.

The original CloudKit container IDs are captured per app/extension in
`AsignOriginalCloudContainerIdentifiers` with the first capability snapshot.
Default-container requests can use that identity in local mode. On iOS 17+,
the app's imported SwiftData `CloudKitDatabase.automatic` getter uses an explicit
original container only when the installed signature has no usable container.
This lets SQLiteData discover a container during database startup. Explicit
`.none` configurations and usable signed CloudKit configurations are preserved.
A small Swift helper constructs the configuration using the public API, with
SwiftData weakly linked for older systems. All code remains in `asignpatch.dylib`.

This is a local compatibility path, not a cloud storage implementation. It
does not recover existing remote-only data, enable sharing, grant access to the
original developer's containers, or promise that an app requiring successful
remote requests can run offline. Private SDK selectors are checked before
hooking and absent or incompatible selectors are left alone.

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

The patch installs from Objective-C `+load`, before app initializers:

- `NSBundle.bundleIdentifier`, `infoDictionary`, `localizedInfoDictionary`,
  `objectForInfoDictionaryKey:` and `bundleWithIdentifier:` expose the original
  identity for annotated bundles. Other bundles retain their own identities.
- Background Assets and its managed helper see the installed identity for
  bundle lookups so SDK validation can find the registered app. The app's
  imported Swift `AssetPackManager.shared` getter also uses this view for its
  synchronous initialization, including nested Foundation/LaunchServices calls.
  This scope is thread-local and restored on return or an Objective-C exception;
  concurrent app lookups retain their original identity. The getter forwards the
  Swift metatype and the real SDK object unchanged. No asset manager is fabricated,
  no Swift trap is suppressed, and signed capabilities remain authoritative.
- Imported `CFBundleGetIdentifier`, `CFBundleGetInfoDictionary`,
  `CFBundleGetLocalInfoDictionary`, `CFBundleGetValueForInfoDictionaryKey`,
  `CFBundleGetBundleWithIdentifier`, `CFBundleCopyInfoDictionaryForURL` and
  `CFBundleCopyInfoDictionaryInDirectory` get matching views.
- Immutable dictionary views are cached per source dictionary and original ID.
  CF Get/Copy ownership is retained. Foundation's real dictionaries are not
  mutated; signing and installation still use the selected identifier.
- Bundle C imports are rebound only inside the containing app and its embedded code,
  excluding the patch itself. A dyld callback includes later-loaded code.
  Legacy lazy imports use their indirect symbols; resolved ordinary GOT imports
  can also be matched by address for chained-fixup images. Matched pointer pages
  regain their previous protection after a write.

This is an API compatibility layer. Direct file reads, signing entitlement
queries, external services, function pointers obtained via `dlsym`, and private
or authenticated arm64e import paths are not rewritten. The rebinder explicitly
skips authenticated pointer sections rather than writing unsigned pointers into
them. It does not claim to conceal an installed identifier from every possible
inspection mechanism or grant capabilities associated with an original ID.

iOS launch/relaunch, device-specific private SDK behavior, keychain,
shared-group, extension and Background Assets behavior require device validation.
The installed-identity view addresses an SDK identity mismatch; it does not
grant access to the original developer's Apple-hosted asset packs or guarantee
that missing app groups, extensions or other validation failures can be repaired.
Inputs already carrying the older key-only snapshot cannot reliably recover
original container IDs; start with the original IPA when adding this fallback.
