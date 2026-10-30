# Unified Asign compatibility patch

`asignpatch.dylib` contains the bundle identity, keychain, app-group,
NSUserDefaults, CloudKit and subscription-registration compatibility code in one source-built library.
The main Xcode target's **Build Asign patch** phase bundles it as
`asignpatch.dylib.bin`; the packaging script requires all implementation
version markers and removes stale two-library resources from cached products.
There is no runtime dependency on either former patch library.

`PatchPolicy.m` compares captured original groups with the running process's
actual signed capabilities. `CompatibilityPatch.m` tries each native keychain
operation first. Adds retry only an `errSecMissingEntitlement` failure with a
known original group that can be remapped. Searches, updates and deletes also
retry `errSecItemNotFound` when the query's explicit group has that conclusive
mapping: Security can hide an unauthorized group's items with that status.
This keeps reads, updates and deletes consistent with fallback writes.
An update's unavailable destination alone cannot trigger an item-not-found
retry. Success, duplicate, authentication, interaction and parameter errors
retain their native behavior; a fallback failure is returned without another
attempt. Item-not-found results for default, authorized and unknown group
queries remain unchanged.
It preserves default keychain
queries (which can search every authorized group), explicit authorized groups,
and unknown groups. Only a known original group that is now unavailable is
remapped to the installed default keychain group. Both `SecItemUpdate` dictionaries
use this rule on retry. An unusable app-group entry or unrelated signing value
does not disable a known keychain mapping; the default destination itself must
be usable. A first signed keychain group ending in `.*` is retained literally
as Security's native default destination, without expanding it or treating it
as permission for the original developer's groups. The prefix must be concrete;
other malformed defaults remain ineligible, and the read-only `com.apple.token`
group is never selected as a destination. The patch does not skip an unusable
first group to choose a later group or substitute the application identifier.
Default queries, authorized groups and retry conditions retain their behavior.
No probe item is created, no item is moved or deleted by setup,
and Security imports are rebound only in app-owned code. Apple frameworks keep
their native imports.

App-group requests call the native method first. SwiftData callers can use the
same fallback directory as app callers only when the native lookup returns nil
and a captured original group is missing from a readable installed signature.
The caller must belong to the loaded image exporting SwiftData's public
`ModelConfiguration` metadata accessor; no app identifiers, SDK offsets or
framework paths are hardcoded. Missing symbols and unrelated framework callers
retain the native result. A valid native SwiftData container always wins, even
on a recorded legacy upgrade. CloudKit settings and group defaults are unchanged.
This covers explicit SwiftData group configurations during URL construction,
before `ModelContainer` creation or Core Data store loading. Other system callers
always get the native result. App callers retain valid native containers. When
signing an older prepatched input, `AsignPreserveLegacyGroupDirectories` records the upgrade and
permits reusing an existing legacy directory for app callers to keep saved data
reachable. A coincidentally named folder alone never overrides a native group.
New fallback
directories are created only for known original groups missing from a readable
installed signature, below the first usable signed group's native container when
available, or Documents.
Existing directories in either legacy location are reused without moving or
merging files; symlinks and file collisions are rejected. Group defaults use the
same path decision, including the Documents fallback. An explicit defaults
container and system-created suites are preserved. App provenance is carried
through the public suite initializer only for that suite; unrelated nested suite
initialization is not redirected. Private hook signatures are checked first.
File-container repair uses the public `NSFileManager` method independently of
the private defaults initializer. If that private initializer is absent or has
an unsupported ABI, file-container repair remains available and defaults retain
their native behavior. Group-defaults redirection is unavailable on that SDK;
the file repair alone does not establish that shared preferences work.
No app-group methods are hooked when every captured original group is still
authorized, or the installed signature cannot be read, unless a recorded legacy
upgrade requires discovery of existing compatibility directories. Unusable
entries in a readable signed group list do not authorize a group or disable
fallback for other known original groups; concrete authorized entries are kept.

`AsignOriginalAppGroupIdentifiers` and `AsignOriginalKeychainAccessGroups` are
captured per executable before tweak injection and signing. They are metadata,
not custom entitlements or grants of access. The keychain snapshot includes
original keychain groups, the original application identifier and app groups.
Each capability family requires its own conclusive snapshot. Empty groups and
unknown groups are distinct. Cloud keys, cloud containers, app groups and
keychain groups are captured independently: disagreement or malformed data in
one family does not erase evidence for another. Known keychain identifiers from
valid source families survive a malformed sibling family. A removed signature
is unknown, rather than proof that the original app had no cloud capabilities.
First snapshots are
preserved on subsequent signing. Older prepatched inputs cannot reliably recover
their original groups: existing compatibility directories can still be reused,
but new remapping requires starting with the original IPA. A fresh original IPA
installed over an older patched app does not carry evidence of the previous
redirection; legacy data is left on disk and may need a separate migration.
Keychain items already
placed in a default group by the older patch are not migrated to other groups;
an app that explicitly switches to an authorized group may need a separate,
validated migration. Default all-group queries remain unchanged.

CloudKit hooks install only when the process's captured original CloudKit
container list is valid and nonempty, and the installed signature is known to
lack permission for at least one of those containers. Apps without original
CloudKit containers, fully authorized apps, unreadable signatures and invalid
original-container snapshots get no CloudKit/Core Data method swizzles.
An unusable value in a successfully read signature, such as the profile's literal
`icloud-services = "*"`, does not authorize CloudKit and enables the fallback
for unavailable original containers. It is not treated as a failed signature read.
Older inputs without the container snapshot retain normal SDK behavior; use the
original IPA to capture it.
`CloudKitPatch.m` reads the running process's signed capabilities through SecTask,
independently of any SDK compatibility view. When hooks are needed for a mixed
configuration, authorized and uncaptured requested containers still pass through
unchanged. The same original-container restriction applies to each Core Data
store; one unavailable container never makes all stores eligible for local mode.

For a known unavailable container, the patch still runs the real container and
database initializers. A thread-local SDK entitlement view permits local object
construction; it does not change the signature, profile, Security entitlement
queries, or Apple's service authorization. Instance entitlement/database calls
use the matching container's scope, including its initializer before tagging;
nested calls on a different authorized container do not inherit that view.
Unlike the old nil/no-setup hooks,
Swift receives valid objects. Local containers report a restricted cloud account
and a not-authenticated error for user-record requests. Container/database
operations are cancelled before original SDK queuing, so SDK completion handling
still runs and remote writes are not reported as successful.

Core Data's `NSPersistentCloudKitContainer` gets a per-store check before
`loadPersistentStoresWithCompletionHandler:` starts, and at its internal
`_loadStoreDescriptions:withCompletionHandler:` entry when the SDK exposes the
expected object/block ABI. SwiftData's `NSPersistentContainer(CoreDataSPI) load:`
path can enter the base public implementation directly and bypass a public
subclass override. The Trace 3.25.1 iOS 27 report shows this loading stack reaching
CloudKit mirroring despite the patch being loaded. The internal hook checks the
descriptions passed to that call before mirroring starts.
When a store's requested CloudKit container is known to be unavailable under the installed signature,
its `cloudKitContainerOptions` is cleared so Core Data loads the local store
without initializing cloud mirroring. Authorized containers, already-local
stores and unknown capability lookups retain normal behavior, including in
containers with a mixture of local and cloud-backed stores. Store URLs,
configurations, migration settings and completion handlers are retained. The
library links Core Data so these hooks are available when the patch installs.
Every hooked method's result and argument types are checked, distinguishing
objects, blocks and integer widths. Object class annotations and type qualifiers
are accepted when the ABI matches.

After clearing cloud options, some SDKs still initialize mirroring inside the
cloud subclass. For a batch with at least one store repaired by the patch and
no remaining cloud requests, the internal loading hook calls the ABI-checked
`NSPersistentContainer` base implementation. The public hook's repair evidence
is retained on each description and revalidated at the internal hook. A new
cloud request replaces that evidence. Already-local batches, authorized or
unknown requests, and mixed batches with remaining cloud options retain the
cloud subclass loader. Missing or incompatible base methods retain option
clearing alone. The receiver, descriptions and completion block are preserved.
The Five Cents iOS 27 report exercises both loading hooks before mirroring
throws; launch and persistence still require device validation.

The original CloudKit container IDs are captured per app/extension in
`AsignOriginalCloudContainerIdentifiers` with the first capability snapshot.
Concrete IDs are preserved exactly, including older team-prefixed IDs such as
Sygic's `LHXY425M9Z.com.sygic.world`; an `iCloud.` prefix is not required.
Both capture and runtime validation reject empty, wildcard and malformed IDs.
Fallback still requires an exact captured-original match and a readable signed
capability set that does not authorize that container. Previously patched inputs
whose container snapshot was omitted need to be imported from the original IPA;
the replacement signing profile cannot recover their original container IDs.
`python3 .github/scripts/check_cloudkit_containers.py` checks capture,
metadata publication, re-signing and runtime eligibility on macOS; `--ipa`
additionally checks the original Sygic IPA.
Default-container requests can use that identity in local mode. On iOS 17+,
the app's imported SwiftData `CloudKitDatabase.automatic` getter uses an explicit
original container only when the installed signature has no usable container.
The SwiftData import is left untouched when that fallback is unnecessary.
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

`SubscriptionPatch.m` covers the Pluto TV startup failure in
`-[VSSubscriptionRegistrationCenter setCurrentSubscription:]`. The original
`com.apple.smoot.subscriptionservice` Boolean is captured per executable before
tweak injection and signing as `AsignOriginalSubscriptionRegistration`. This is
metadata, not an entitlement. The first snapshot survives re-signing. Malformed
values and disagreements between universal slices remain unknown independently
of the other capability families. Older prepatched inputs without this snapshot
need the original IPA; current signing permissions are not original evidence.

The subscription hook installs only when that snapshot is exactly Boolean true,
a successful SecTask read of the running signature proves the permission absent
or Boolean false, and the loaded registration method has the expected void/object
ABI. Authorized apps, apps without the original permission, unknown or malformed
snapshots/signatures and absent or incompatible methods get no method swizzle.
The optional framework is not loaded by setup. A framework loaded only after
setup is not hooked. When enabled, only app-owned calls to this one method are
skipped, including calls clearing a subscription with nil. System callers retain
the original implementation. No exceptions are caught, no signed permissions are
changed, and other VideoSubscriberAccount APIs are untouched. The tradeoff is
missing subscription registration with Apple's TV app; this does not implement
TV-provider authentication or guarantee that later app initialization/playback
will succeed. Apple's [TV app integration guide](https://help.apple.com/itc/tvpumcstyleguide/en.lproj/static.html)
documents this subscription-registration permission and API.

Signing also prevents accidental iCloud enablement, independently of the IPA
Patching option and runtime patch installation. Before any tweak can rewrite an
executable's signature, `IPAPatcher.cloudEntitlementPolicy` reads its XML signing
entitlements. When compatibility patching is enabled, `IPAPatcher` also
records the cloud capability key names in `AsignOriginalCloudEntitlementKeys`
for each app/extension. Before signing that executable, zsign removes iCloud and
ubiquity keys from the selected profile when those keys weren't present in the
original app. Values for originally used keys still come from the selected
profile; this does not grant access to the original developer's containers.
Identity, keychain and app-group entitlements are left alone.

This avoids SwiftData's automatic CloudKit selection being enabled for a local
schema merely because the signing profile contains iCloud containers. Each bundle
gets its own policy, including when root and extension capabilities differ. The
first snapshot survives re-signing; publication rolls back with the dylib/identity
transaction. Missing or unreadable seals, conflicting cloud-key lists across
universal slices and DER-only signatures don't establish a signing policy.
Malformed container values do not erase an otherwise readable cloud-key list.
A previously re-signed input without a snapshot can't
reveal which cloud capabilities its original developer used: start with the
original IPA. An explicit custom entitlements file remains the user's override.
The signing policy still applies when compatibility patching is disabled or
patch injection fails. Modify-only operations do not apply a signing policy.

The patch installs from Objective-C `+load`, before app initializers:

- `NSBundle.bundleIdentifier`, `infoDictionary`, `localizedInfoDictionary`,
  `objectForInfoDictionaryKey:` and `bundleWithIdentifier:` expose the original
  identity for renamed annotated bundles when called from app-owned code. If
  the process's original and installed IDs match, identity hooks are not installed.
  System callers and other bundles retain their native identities.
- Background Assets and other system frameworks see the installed identity for
  bundle lookups so SDK validation can find the registered app. The app's
  imported Swift `AssetPackManager.shared` getter also uses this view for its
  synchronous initialization, including nested Foundation/LaunchServices calls.
  This scope is thread-local and restored on return or an Objective-C exception;
  concurrent app lookups retain their original identity. The getter forwards the
  Swift metatype and the real SDK object unchanged. No asset manager is fabricated,
  no Swift trap is suppressed, and signed capabilities remain authoritative.
- Background Assets group-container and group-defaults requests can use the
  existing compatibility directory only for the main bundle's `BAAppGroupID`,
  when it exactly matches a captured original group proven unavailable in the
  running signature. Working native containers, explicit defaults containers,
  unrelated groups and unknown signatures retain native behavior. Callers are
  identified by the loaded image exporting `AssetPackManager`'s metadata
  accessor; the synchronous shared-manager scope also covers Foundation helpers.
  Defaults initialization carries only the matching suite's scope and restores
  it for nested calls and Objective-C exceptions. This group repair also applies
  when the bundle identifier was preserved, independently of identity repair.
  The Placify original IPA establishes its group declaration and extension;
  its report omits the assertion message, so this closes a coverage gap without
  proving that every Background Assets validation failure is repaired.
- Imported `CFBundleGetIdentifier`, `CFBundleGetInfoDictionary`,
  `CFBundleGetLocalInfoDictionary`, `CFBundleGetValueForInfoDictionaryKey`,
  `CFBundleGetBundleWithIdentifier`, `CFBundleCopyInfoDictionaryForURL` and
  `CFBundleCopyInfoDictionaryInDirectory` get matching views. Every C wrapper
  honors the same installed-identity scope as the Objective-C hooks, including
  nested synchronous calls through the asset manager.
- Immutable dictionary views are cached per source dictionary and original ID.
  CF Get/Copy ownership is retained. Foundation's real dictionaries are not
  mutated; signing and installation still use the selected identifier. Localized
  dictionaries without an identifier keep that key absent.
- Bundle C imports are rebound only inside the containing app and its embedded code,
  excluding the patch itself. A dyld callback includes later-loaded code.
  Legacy lazy imports use their indirect symbols; resolved ordinary GOT imports
  can also be matched by address for chained-fixup images. Matched pointer pages
  regain their previous protection after a write. Known symbol names take
  precedence over address aliases. Resolved slots already replaced by another
  hook, and null weak imports, are preserved. A named unresolved lazy import can
  still be replaced when its target lies inside that image's stub-helper section.
  Symbol-table reads are bounded by the mapped `__LINKEDIT` segment.

`DyldPatch.c` handles an ARM64 Unreal module-tracing startup race across apps.
Some builds walk `dyld_all_image_infos.infoArray` without a null check while
another thread loads a bundle. Apple's [dyld header](https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld_images.h)
documents that the pointer can temporarily be null during a loader update.
Checking it once inside a `task_info` hook cannot protect a later traversal.

The app-scoped `task_info` import hook instead recognizes the affected optional
diagnostic initializer and takes its existing checked error exit. Recognition
requires the ARM64 call setup, heap-trace/path preparation, unchecked 24-byte
image-array traversal, normal stack-protected error return, and referenced
`Program`/`__LINKEDIT` diagnostic strings. Addresses, app identifiers and
callee-saved registers are not hardcoded. A successful matching self-task
`TASK_DYLD_INFO` query returns `KERN_FAILURE`, skipping module tracing. Other
queries and original API errors pass through. The tradeoff is missing module
metadata and associated image-allocation events in Unreal diagnostic traces.

This is a mitigation for the recognized compiler pattern, not a replacement
loader or a general exception handler. It leaves unknown or guarded instruction
patterns and non-ARM64 builds alone. Code/string inspection uses checked Mach
reads; unreadable or incomplete matches pass through. No code pages or dyld
structures are modified, no image is hidden, and no image-list snapshot or
classification cache survives an unload. The existing rebinder also covers
later-loaded embedded code, with the same import-path limitations below.

For diagnosis, the manual workflow accepts `patch_disabled_hooks`, a comma-separated
list of `identity,keychain,app-groups,cloudkit,background-assets,module-trace,image-callbacks,subscription-registration`,
and `patch_defer_image_callbacks`. Leave both at their defaults for a normal build.
Equivalent standalone options are repeatable `--disable-hook NAME` and
`--defer-image-callbacks` on `.github/scripts/build_identity_patch.py`.
Environment equivalents are `ASIGN_PATCH_DISABLED_HOOKS` and
`ASIGN_PATCH_DEFER_IMAGE_CALLBACKS=1`. Unknown names and conflicting disable/defer
requests fail before compilation. Diagnostic libraries contain an
`AsignPatchDiagnostic/v1` marker. The small patch build phase runs every build so
cached products cannot silently retain a previous diagnostic configuration.

Disabling `image-callbacks` omits all import rebinding, while retaining enabled
Objective-C hooks. Deferral registers the same import callback on the main queue,
so it deliberately misses early initializer calls; it is an isolation tool for
SignNow's dyld report, not a production fix or proof of its cause. Normal builds
retain early registration. For Dokus, compare normal builds with `app-groups`
disabled, then `background-assets` disabled separately. Use a freshly signed
original IPA with the same profile/options for each comparison; also compare
patching off. Confirm launches, asset loading, extension access and an update
over an existing installation with saved group data. Keep a working app and an
app that needs compatibility fixes in the comparison to check for regressions.

For subscription registration, sign an original Pluto IPA with the normal patch
and with `subscription-registration` disabled using the same profile/options.
Check launch, relaunch, sign-in/out and playback. Compare an app retaining the
subscription permission and an app without the original permission: neither
should install this hook. Also verify unknown/malformed snapshots/signatures and
unsupported method ABIs install no hook, and system callers still forward.

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
