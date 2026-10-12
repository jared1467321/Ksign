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
  serially, share a connection across the workflow, and report progress per app.
  A queued Ksign update follows the other queued device installs. Avoid adding
  more apps after Ksign's own update has already begun.
- When the workflow ends, Ksign removes the protected temporary pairing file
  and waits for its installation VPN to disconnect, then disables its saved
  profile and Connect On Demand. The profile is kept for the next workflow;
  Ksign re-enables it automatically. An existing Ksign installation connection
  is also adopted and stopped when the workflow ends. Cleanup continues after
  cancellation, and a failed disconnect has an explicit retry button.
- A new VPN connection may replace another active VPN. Ksign cannot enumerate
  or restart VPN configurations owned by other apps using the public API:
  https://developer.apple.com/documentation/networkextension/netunnelprovidermanager/loadallfrompreferences(completionhandler:)
  Disabling Ksign's profile does not guarantee restoration of the previous VPN.
  Reconnect it in its app or iOS VPN Settings, or enable the optional shortcut
  handoff described below.
- **Forget Built-in Pairing** removes Ksign's saved credentials. Removing iOS's
  trust entry separately requires Developer settings.

The initial installation of Ksign, Apple signing and trust requirements, and
system consent prompts cannot be automated by this implementation. No network
service operated by Ksign is required for direct installation.

## Optional Tailscale reconnect

Tailscale provides a supported **Connect** action in Apple's Shortcuts app:
https://tailscale.com/docs/features/mac-ios-shortcuts
Its On Demand configuration is disabled when another VPN connects, so stopping
Ksign alone is insufficient to guarantee automatic restoration:
https://tailscale.com/docs/features/client/ios-vpn-on-demand

1. Create a shortcut named **Reconnect Tailscale** in Shortcuts.
2. Add **Tailscale → Connect**, rather than Toggle. Run it once to verify it and
   allow any permissions. It can use your existing signed-in Tailscale account.
3. In **Ksign → Settings → Installation → iDevice → Built-in Connection**, enable
   **Reconnect VPN After Installation**. Enter a different shortcut name if
   needed, and use **Test Reconnect Shortcut** to verify the handoff.

Ksign waits for its VPN to stop and its profile to be disabled, then opens
`shortcuts://run-shortcut?name=...` using Apple's documented URL scheme:
https://support.apple.com/en-us/guide/shortcuts/apd624386f42/ios
Names are encoded as a single query value; no clipboard contents, IPA data, or
pairing credentials are passed to the shortcut.

This opens Shortcuts; it is not a silent background API. When Ksign is inactive,
the request waits for the next foreground activation. It runs once per completed
built-in workflow, including cleanup after a failed/cancelled attempt, and never
between apps in a batch. Starting a new built-in workflow cancels an older queued
handoff. The option is off by default and starts the configured VPN even if it
was previously off: Ksign cannot inspect the prior state of another app's VPN.
URL acceptance only confirms that Shortcuts opened; errors in the shortcut are
displayed by Shortcuts and do not change the installation result. The shortcut
must exist, and the handoff still requires real-device testing.

## Verification status

The Rust pairing cancellation test has passed on Linux. The user reported a
successful Xcode build and device installation after the packaging permission
fix. The asynchronous disconnect/profile-disable update still needs a new
Xcode build and device testing, including the optional shortcut handoff. The
manual build workflow runs Swift tests for shortcut URL encoding on macOS.
Verify first-run consent/PIN, relaunch and
automatic reconnect, a multi-app install, cancellation during setup/upload,
retry after a connection failure, self-update last, and the existing Server,
Manual Setup, signing, and export paths on a real device before release.

## Source attribution

The protocol implementation is iDevice by Jackson Coxson, declared MIT by its
upstream Cargo metadata and README:
https://github.com/jkcoxson/idevice/tree/7bd551c16c6dd2e058740d85a2d9399a51a776e9

Ksign's Swift integration, pairing bridge, and narrow IPv4 packet reflection
are maintained in this repository. StikPair's implementation is not included.
