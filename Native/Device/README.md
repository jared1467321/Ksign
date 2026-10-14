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
  concurrently, share a connection across the workflow, and report progress per app.
  A queued Ksign update follows the other queued device installs. Avoid adding
  more apps after Ksign's own update has already begun.
- For both iDevice and Server installs, pause the install drawer to stop new
  work and let current work finish. Then choose **Cancel Task & Select Installed**
  to cancel the remaining queue and select successfully installed entries in
  **Library → Signed Apps**. Use the library trash button to remove those signed
  files; failed and unstarted entries remain for later. A completed queue also
  offers **Select Installed Apps** until its result is closed or a new queue starts.
- When the workflow ends, Ksign removes the protected temporary pairing file
  and stops a VPN connection it started. It leaves an already connected VPN
  alone. A new VPN connection may replace another active VPN.
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
   resolve any first-run permissions. Optionally add **Open App → Ksign** as
   the final action to return to Ksign after reconnecting.
2. In Ksign, open **Settings → Installation → iDevice → Built-in Connection**
   and enable **Reconnect VPN after installation**. Allow notifications for
   the background completion reminder. Enter a different shortcut name if
   needed; other VPNs can use the same feature through their own shortcuts.
3. Use **Test Reconnect Shortcut** while no installation is running.

When all device operations and workflows finish, Ksign stops the local VPN it
started and waits for disconnection before opening Shortcuts. Failed or
cancelled work also restores the VPN once cleanup finishes. Setup checks use
the same handoff. A VPN Ksign adopted without starting stays untouched and
does not trigger reconnection. Manual Setup does not trigger reconnection.

If Ksign finishes in the background, it saves a pending request and sends a
notification. Tap it to open Ksign and run the shortcut. If notifications are
unavailable, return to Installation settings and tap **Reconnect VPN**.
Returning to the app alone does not run the shortcut. Starting new device work
invalidates the previous request, including its notification, so an old tap
cannot interrupt the next installation. Paused workflows retain their device
connection until the workflow ends.

This feature is off by default and briefly opens Shortcuts in the foreground.
It cannot silently control another app's VPN or confirm the shortcut connected
successfully; Shortcuts reports missing shortcuts or action failures. If the
local VPN has not disconnected within 20 seconds, Ksign skips the handoff.
Force quitting or replacing Ksign during self-update can prevent completion
cleanup from running and still requires a manual reconnect.

## Verification status

Run `python3 .github/scripts/test_device_connection.py` on a machine with Swift
to exercise production connection recovery against VPN and pairing doubles.
The manual build runs these regression checks before building the IPA.
The checks include foreground/background shortcut handoff, pending requests
across relaunch, URL encoding, notification permission failure, stale taps,
new work racing with cleanup, and waiting for the actual VPN disconnection.

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

## Source attribution

The protocol implementation is iDevice by Jackson Coxson, declared MIT by its
upstream Cargo metadata and README:
https://github.com/jkcoxson/idevice/tree/7bd551c16c6dd2e058740d85a2d9399a51a776e9

Ksign's Swift integration, pairing bridge, and narrow IPv4 packet reflection
are maintained in this repository. StikPair's implementation is not included.
