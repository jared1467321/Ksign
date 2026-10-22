# Built-in device installation

The existing manual build workflow produces one updated `packages/ASign.ipa`.
It embeds `KsignDeviceTunnel.appex` and Ksign's pairing bridge. The Server and
Manual Setup paths remain available in Installation settings.

## Build

Use **Actions → Manual Build (cached) → Run workflow** on the
`Installation-improvements` branch. The artifact contains `ASign.ipa`.

For a local Mac build, install Rust 1.99.0 with rustup, initialize the submodules,
and run `make`. The native build downloads the exact source revision and verifies
its SHA-256 from `source.json`, builds the iOS XCFramework, and applies the Swift
overlays before Xcode resolves the local package. To prepare an Xcode checkout
without building the app, run `make native` first. Generated IDeviceKit edits are
recreated by the scripts; the submodule commit is unchanged.

The native framework cache uses the builder's own fingerprint: the pinned
source manifest, Rust pairing bridge, native build script, and actual Xcode
and Rust versions. Swift overlay, test, and documentation edits reuse it.
The workflow also separates caches by runner OS and architecture. The first
build with a new fingerprint compiles both native targets and saves the cache;
later builds reuse it. Selecting **Ignore caches and build from scratch**
still bypasses all caches.

The native builder enables `aes` 0.8.4's ARMv8 backend with `--cfg aes_armv8`
for both Apple ARM64 targets. The pinned `cpufeatures` recognizes AES support
on Apple ARM64; the AES crate calls its hardware intrinsics through
feature-qualified functions. Existing Rust flags are preserved, and effective
flags participate in the cache fingerprint. This forces a rebuild of libraries
from before acceleration was enabled. The compiler optimization level and TLS
cipher suites remain unchanged so the next device comparison isolates AES
acceleration. The builder also restores upstream's AFC write limit in cached
source trees from the chunk-size experiment.

## Requirements and workflow

- Ksign and its embedded tunnel must be signed with provisioning profiles that
  authorize `com.apple.developer.networking.networkextension` with
  `packet-tunnel-provider`. Ad-hoc packaging preserves the requested
  entitlements but does not grant this capability. Keep the extension when
  re-signing, and use matching bundle identifiers and signing teams.
- Creating a pairing entirely on the device requires iOS 27 or later, Developer
  Mode, Local Network permission, and a one-time pairing PIN in Settings. Older
  versions can still use an imported pairing with Manual Setup. The built-in
  VPN can also use an existing compatible imported pairing.
- Select **iDevice → Built-in Connection**. The first installation configures
  the VPN, guides pairing when needed, and saves the credentials in the device's
  Keychain. Subsequent workflows reconnect automatically. The app does not
  open Safari or require a separate VPN app for this path.
- Select multiple signed apps and install them together. Device installs run
  concurrently, share one native tunnel and handshake across the workflow, and
  report progress per app. Each app has separate upload and installation clients;
  only opening those clients is serialized, while uploads and installs overlap.
  A change in the VPN's reported status alone does not replace the prepared
  native connection during a workflow. Later apps keep using that connection;
  a connection error requests recovery after active installs drain. An app
  rejected by iOS (for example, an incompatible platform or invalid signature)
  fails individually without replacing the shared connection for later apps.
  A queued Ksign update follows the other queued device installs. Avoid adding
  more apps after Ksign's own update has already begun.
- **Sign** and **Sign & Install**, for both single apps and batches, review the
  current signing options before starting work. A local installed-app check warns
  about bundle identifiers already on this device without starting the VPN.
  **Edit Bundle IDs** returns to the signing form; **Continue Signing** signs
  every eligible app, including installed-ID matches. The warning explains that
  a differently signed copy cannot replace an App Store installation with the
  same bundle identifier; compatible updates remain eligible.
  Explicit tvOS, watchOS, visionOS, macOS and simulator targets automatically get
  one iOS compatibility attempt during signing, without a toggle or an extra
  confirmation. The trigger is exactly the main-app declaration check that used
  to skip these apps. iOS/iPadOS roots, including iPad-only apps on iPhone, mixed
  or unknown declarations, and iOS apps with a Watch companion bypass the shim.
  In the private signing workspace, it normalizes the main app and affected code
  bundles' platform/device-family declarations, removes device/capability filters,
  and retargets foreign Mach-O platform/version commands before signing. The
  default minimum is iOS 16.0, independent of this device's exact OS release;
  an explicit signing minimum takes precedence. Embedded iOS code with a higher
  minimum is lowered too, only inside the activated shim tree. It covers thin
  and universal binaries, embedded frameworks/dylibs and retained extensions
  without extracting resources. Versioned framework plists and retained bundle
  plists with compatibility declarations but no executable are covered too.
  CPU types, executable code and original library files stay intact. Existing
  iOS SDK fields are preserved when only lowering a minimum. Malformed or
  encrypted binaries fail the attempt; changing
  metadata does not supply missing APIs or translate machine code. Signing and
  installation report their ordinary success/failure, and launch may still fail.
- Before native **Sign & Install** hands successful packages to the drawer,
  it inspects their final bundle identifiers and signed executable entitlements.
  For locally detected installed matches, a targeted read-only device lookup
  compares application identifiers. Confirmed identity conflicts are withheld
  from installation and explained in the signing results; all successful signed
  packages remain in Signed Apps. Matching identities and declared previous
  application identifiers remain eligible. Only the exact successful library
  IDs are handed off, preserving batch order even when some apps are skipped.
  Ordinary **Sign** does not need a device connection for these checks.
- Direct native installs from Signed Apps also inspect each final IPA when its
  queue slot is admitted and repeat the targeted identity lookup before upload.
  They do not patch an already-signed IPA: older foreign-platform packages must
  be signed again to receive the compatibility attempt and valid new signatures.
  The executable is streamed to temporary storage only for an installed identity
  match and removed after inspection. Unknown signatures remain eligible.
  The lookup does not upload an IPA or send an installation command. A local skip
  does not request connection recovery or affect other native workers.
  Skipped rows remain in the drawer with a separate count; hold one and choose
  **Why skipped?** for its reason. They are excluded from installed-app selection
  and may be retried after resolving the conflict. Native identity checks do not
  apply to Server installs.
- Native installs share one limit across packaging, uploading, iOS installation
  and cleanup. The default is five active apps. **Settings → Installation →
  Native · iDevice → Installation limit** lets you choose from one to 100 for
  built-in and manual connections. The install drawer also has a number field
  and up/down arrows to adjust the same saved limit live. Lowering it lets all
  active apps finish; new apps wait until the active count falls below the
  limit. Raising it wakes waiting work without overriding Pause. Completing an
  upload does not free capacity: the next queued app waits until an installation
  and its native cleanup finish. Memory headroom and kernel pressure may temporarily
  admit fewer apps, but never exceed the chosen limit. Duplicate-bundle
  reservations, pause/drain checks and Ksign's exclusive self-update remain
  enforced.
  Numeric drawer progress is coalesced to at most five deliveries per second
  per attempt while active, with immediate final values at completion. Inactive
  attempts retain their latest numeric samples without scheduling UI deliveries;
  foreground activation flushes them. Native worker phase/progress events feed
  Live Activity independently, with attempt guards preventing cancelled/retried
  work from updating a newer attempt. Foreground phase boundaries keep the same
  immediate numeric flushes.
  Waiting apps suspend on one shared admission sampler instead of each polling
  the main actor. Installation cleanup and pause/resume wake that sampler
  directly; the timer remains for memory measurements and eligibility changes.
  Foreground session notifications are emitted only when progress, counters or
  control state change, while all drawer positions retain the same behavior.
  Queued drawer apps retain static artwork and a stored waiting count; header
  refreshes do not inspect their phases or progress. Phase changes move apps
  into or out of foreground sampling, and the grid subscribes to membership
  changes independently of the header. Settled progress remains cached, while
  native cleanup stays tracked until cancellation/selection is safe.
  Setup cards and native limit controls subscribe only to the session values
  they display. Workflow membership and operation counts publish manager updates
  only when busy/reconnect availability changes, reducing repeated view work
  during concurrent installs without changing admission or control behavior.
- Uploads use bounded 1 MiB chunks. The experimental chunk-size picker has
  been removed; previously saved sizes no longer affect uploads. **Settings →
  Installation → iDevice → Upload performance** retains the latest completed
  upload's duration and average MB/s. Per-app results are also available by
  holding an app in the install drawer. Timing includes reading/sending the
  IPA and closing its staging file, and excludes setup and iOS installation.
  Units use 1,048,576 bytes per MB. Compare the same IPA with the same number
  of concurrent jobs. Results saved by the experimental build remain readable.
- For both iDevice and Server installs, pause the install drawer to stop new
  work and let current work finish. Then choose **Cancel Task & Select Installed**
  to cancel the remaining queue and select successfully installed entries in
  **Library → Signed Apps**. Use the library trash button to remove those signed
  files; failed and unstarted entries remain for later. A completed queue also
  offers **Select Installed Apps** until its result is closed or a new queue starts.
- When the workflow ends, Ksign removes the protected temporary pairing file
  and stops a VPN connection it started. It leaves an already connected VPN
  alone. A new VPN connection may replace another active VPN.
- **Library → Installed Apps** is the third segment beside Downloaded Apps and
  Signed Apps; the original bottom tabs, including App Store, remain available.
  Choose **Load Installed Apps** or
  **Refresh** to query iOS over the selected iDevice connection (Built-in or
  Manual). It shows only installed copies verified against Ksign's persistent
  install receipts, regardless of whether their IPA or library record is kept.
  App Store apps, system apps, and apps installed elsewhere are excluded.
  iOS's inventory does not identify the original installer, so existing apps
  cannot be adopted from the inventory, signing history, or saved library files.
  Apps installed before this tracking was added must be installed through Ksign
  again to enter the list.
  After loading/refreshing, Ksign shows the existing **Reconnect VPN** banner
  with its reconnect and dismiss buttons, as after background installs/setup.
  Loading the list does not open Shortcuts or a share sheet automatically.
  Tapping the reminder uses the selected reconnect method: run the shortcut or
  choose it from the existing share sheet. Dismissing the sheet leaves the
  reminder available. If the device is locked when loading finishes, the existing
  reconnect notification and saved pending request let you choose after unlock
  or relaunch. Native connection/pairing cleanup still runs. Installs/setup/removal
  otherwise keep their configured behavior; a refresh overlapping another workflow
  leaves the manual reminder instead of launching the shortcut automatically.
  Apps are sorted newest first using LaunchServices' reported registration
  dates, which can change after an update or reinstall. Missing dates sort last;
  equal/missing dates use name and bundle ID for stable ordering. If iOS does
  not expose any dates, the screen explains the alphabetical fallback instead
  of inventing dates from library files or when an app was first observed.
  Search by name or bundle identifier. Tap a row to review removal, hold it for
  **Uninstall from Device…**, or use **Edit**, select multiple apps, and choose **Uninstall**.
  Select All applies to the visible search results. Review the selected names
  and bundle identifiers, then confirm deletion of the apps and their data.
  The paired-device command may not show another iOS Delete prompt. The same
  pairing/VPN requirements apply even for apps originally installed with Server.
  Library files are kept. System apps and Ksign itself are not eligible; iOS can
  also reject removal of managed or restricted apps. The app's device-reported
  signing identity and copy binding are checked against the receipt when selected
  and again immediately before removal. Unknown identities are ineligible.
  Native installs save a receipt after iOS confirms completion, using the reported
  signing identity and bundle installation path (or registration date if the path
  is unavailable). Server installs inspect the final signed IPA before prompting;
  they require a new local OS registration after progress completion and bind the
  receipt to that date and the IPA's signing identity. Signing/exporting an IPA,
  accepting a prompt, or an unchanged/unknown registration does not grant ownership.
  If required metadata or persistence is unavailable, the app stays unlisted.
  Receipts live in Application Support separately from the library, with atomic
  writes serialized across install workers. Corrupt tracking files fail closed.
  The installation queue must finish or be cancelled first. Removal runs
  sequentially, waits for iOS completion, verifies absence, deletes the receipt,
  updates the list,
  and shows a result per app. **Stop After Current App** leaves the remaining
  apps untouched. Connection errors never automatically replay a removal command.
  Already absent apps also lose their receipts. Failed/cancelled removals keep
  theirs for retry. A successful inventory refresh prunes absent/replaced copies
  without pruning newer receipts created after the query began. Missing metadata
  hides a copy without throwing away its receipt.
- **Forget Built-in Pairing** removes Ksign's saved credentials. Removing iOS's
  trust entry separately requires Developer settings.
- If the device handshake fails, Built-in Connection refreshes and restarts
  this app's local VPN once before retrying. If saved or imported credentials
  still fail on iOS 27 or later, it guides a replacement pairing. Existing
  credentials remain saved until replacement pairing succeeds. A newly created
  pairing does not trigger repeated pairing attempts in the same setup.
- Forgetting a built-in pairing requests fresh pairing even if an old imported
  file remains, including after relaunch. Manual Setup retains that file.
  Connection recovery finishes before installation starts; a failed app install
  is never automatically replayed.

The initial installation of Ksign, Apple signing and trust requirements, and
system consent prompts cannot be automated by this implementation. No network
service operated by Ksign is required for direct installation.

## Reconnect Tailscale after installation

1. In Apple's Shortcuts app, create a shortcut named **Restore Tailscale** and
   add Tailscale's **Connect** action. Run it once to check that it connects and
   resolve any first-run permissions. In the shortcut's details, enable
   **Show in Share Sheet** and allow **Text** input. The shortcut can ignore
   that input. Remove any **Open App** actions to keep execution inside Ksign.
2. In Ksign, open **Settings → Installation → iDevice → Built-in Connection**
   and enable **Reconnect VPN after installation**. Allow notifications for
   the background completion reminder. Enter a different shortcut name if
   needed; other VPNs can use the same feature through their own shortcuts.
3. Leave **Reconnect method → Share Sheet** selected, then use **Test Share
   Sheet** while no installation is running. Scroll down in the system share
   sheet and select **Restore Tailscale**. The name in Ksign is a reminder;
   iOS requires you to select the actual shortcut yourself.

When all device operations and workflows finish, Ksign stops the local VPN it
started and waits for disconnection before presenting the share sheet over
the current screen, including the install drawer. Select your shortcut to
reconnect without switching to the Shortcuts app. Failed or cancelled work
also offers reconnection once cleanup finishes. Setup checks use the same
handoff. A VPN Ksign adopted without starting stays untouched and does not
trigger reconnection. Manual Setup does not trigger reconnection.

If Ksign finishes in the background, it saves a pending request and sends a
notification. Tap it to open Ksign and show the share sheet. If you dismiss
the sheet or notifications are unavailable, tap the **Reconnect VPN** reminder
in Ksign, the install drawer, or Installation settings to bring it back.
Returning to the app alone does not run the shortcut. Starting new device work
invalidates the previous request, including its notification, and dismisses
its share sheet, so an old request cannot launch another handoff during the
next installation. Dismissing the reminder leaves the setting enabled for
future workflows. Paused workflows retain their device connection until the
workflow ends.

Share Sheet is the default method, including for previously enabled installs
with no saved method. The feature itself remains off until enabled. To retain
the earlier automatic behavior, select **Open Shortcuts Automatically**; this
briefly opens Shortcuts, and you can add **Open App → Ksign** as the shortcut's
last action to return. That method uses **Test Reconnect Shortcut** for testing.

Ksign cannot silently control another app's VPN or confirm the shortcut
connected successfully; Shortcuts reports action failures. Completing a share
activity acknowledges the handoff without verifying the VPN. If your shortcut
is missing from the share sheet, check **Show in Share Sheet** and its accepted
input types. Actions that explicitly open an app still switch to that app.
If the local VPN has not disconnected within 20 seconds, Ksign skips the handoff.
Force quitting or replacing Ksign during self-update can prevent completion
cleanup from running and still requires a manual reconnect.

## Verification status

The pre-build regression scripts have been removed. The following describes
their historical coverage of production connection recovery against VPN and
pairing doubles.
The shared-tunnel check runs the production proxy against native FFI doubles,
holds three uploads open concurrently, verifies one tunnel is used for all
upload and installation clients, and checks lease cleanup after a cache reset.
The queue checks verify the default five-app shared ceiling, lower and higher
configured limits, live decreases/increases, number-field validation, preference
bounds, pause/cancellation and both terminal-status/cleanup orderings.
Native concurrency one is checked for initial admission, serial handoff and
live reduction from a higher limit with a nonzero existing memory footprint.
Capacity stays occupied until the install and its native worker
finish. Upload checks verify that final progress cannot be overwritten by a
delayed UI sample.
The checks include foreground/background shortcut handoff, pending requests
across relaunch, URL encoding, notification permission failure, stale taps,
new work racing with cleanup, and waiting for the actual VPN disconnection.
They also cover share sheet completion/cancellation, failed presentation,
background notification activation, dismissing sheets for new work, stale
sheet callbacks, and releasing installation cleanup before user selection.
The drawer checks exercise 1,000 queued apps with no per-app reads during
foreground refreshes, then verify active progress, removal, retries, failed-entry
replacement, and terminal cleanup without polling the remaining queued apps.
Preflight checks cover platform declarations, iPad-only eligibility, malformed
and universal executables, signing-identity matches/conflicts and migration,
deferred extraction, both signing review choices, and exact signed-ID handoff
with preserved packages. Shared-tunnel tests verify read-only validation sends
no upload or install command, local skips preserve active peers, and skipped
rows support retry without being counted as installed.

The Rust pairing cancellation test has passed on Linux. An iOS Xcode build and
device testing are still required. Verify first-run consent/PIN, relaunch and
automatic reconnect, a multi-app install, cancellation during setup/upload,
retry after a connection failure, self-update last, and the existing Server,
Manual Setup, signing, and export paths on a real device before release. Also
verify pause/drain/resume and cancelling a partial queue from another tab:
only successful signed entries should be selected, including retired rows.
For VPN restoration, verify the configured Tailscale shortcut on a real iPhone,
foreground completion, background/locked-screen notification taps, bulk
completion, cancellation, and starting a new queue before tapping an old
notification. The Linux checks use platform doubles and do not verify iOS
Shortcuts execution or notification delivery.
Also verify selecting the Text-accepting reconnect shortcut inside the share
sheet, presenting it over the install drawer, dismiss/retry, and the iPad
popover anchor. Remove any Open App actions when checking execution inside
Ksign. The UIKit share sheet requires an Xcode build and real device validation.

## Source attribution

The protocol implementation is iDevice by Jackson Coxson, declared MIT by its
upstream Cargo metadata and README:
https://github.com/jkcoxson/idevice/tree/7bd551c16c6dd2e058740d85a2d9399a51a776e9

Ksign's Swift integration, pairing bridge, and narrow IPv4 packet reflection
are maintained in this repository. StikPair's implementation is not included.
