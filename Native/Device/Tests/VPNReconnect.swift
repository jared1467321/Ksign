import Foundation

@MainActor private final class ReconnectEnvironment {
    var foreground = true
    var opens: [URL] = []
    var notifications: [(String, String)] = []
    var canOpen = true
    var canNotify = true
    var heldNotification: CheckedContinuation<Bool, Never>?
    var holdNotification = false
    var removals = 0
    var shareSheets: [String] = []
    var shareCompletions: [@MainActor (Bool) -> Void] = []
    var canPresentShareSheet = true
    var shareDismissals = 0

    func coordinator(defaults: UserDefaults) -> VPNReconnectCoordinator {
        VPNReconnectCoordinator(defaults: defaults, isForeground: { self.foreground },
            openShortcut: { self.opens.append($0); return self.canOpen },
            notify: { name, id in
                self.notifications.append((name, id))
                if self.holdNotification {
                    return await withCheckedContinuation { self.heldNotification = $0 }
                }
                return self.canNotify
            }, removeNotification: { _ in self.removals += 1 },
            presentShareSheet: { name, completion in
                guard self.canPresentShareSheet else { return false }
                self.shareSheets.append(name)
                self.shareCompletions.append(completion)
                return true
            }, dismissShareSheet: { self.shareDismissals += 1 })
    }
}

extension ConnectionRecoveryTests {
    @MainActor static func runVPNReconnectTests() async throws {
        let defaults = UserDefaults(suiteName: "Ksign.VPNReconnectTests")!
        defaults.removePersistentDomain(forName: "Ksign.VPNReconnectTests")
        defer { defaults.removePersistentDomain(forName: "Ksign.VPNReconnectTests") }
        let environment = ReconnectEnvironment()
        let reconnect = environment.coordinator(defaults: defaults)

        reconnect.beginDeviceWork()
        await reconnect.deviceWorkFinished(restoreVPN: true)
        expect(environment.opens.isEmpty, "Reconnect is opt-in")
        defaults.set(true, forKey: VPNReconnectCoordinator.enabledKey)
        defaults.set(VPNReconnectPresentation.automatic.rawValue, forKey: VPNReconnectCoordinator.presentationKey)
        defaults.set("Restore & Tailscale ? # / 😀", forKey: VPNReconnectCoordinator.shortcutNameKey)
        reconnect.beginDeviceWork()
        await reconnect.deviceWorkFinished(restoreVPN: false)
        expect(environment.opens.isEmpty, "Adopted or manual tunnels must not trigger restore")
        await reconnect.deviceWorkFinished(restoreVPN: true)
        expect(environment.opens.count == 1, "Foreground completion launches the shortcut once")
        let components = URLComponents(url: environment.opens[0], resolvingAgainstBaseURL: false)!
        expect(components.scheme == "shortcuts" && components.host == "run-shortcut", "Use the supported Shortcuts URL")
        expect(components.queryItems?.count == 1 && components.queryItems?.first?.value == "Restore & Tailscale ? # / 😀", "Shortcut names must round-trip without injecting query parameters")
        expect(reconnect.pendingShortcutName == nil, "Successful handoff consumes the request")

        environment.foreground = false
        reconnect.beginDeviceWork()
        await reconnect.deviceWorkFinished(restoreVPN: true)
        expect(environment.opens.count == 1 && environment.notifications.count == 1, "Background completion offers a notification without opening another app")
        let notificationID = environment.notifications.last!.1
        // Merely returning to Ksign must not run a pending shortcut.
        environment.foreground = true
        await reconnect.appBecameActive()
        expect(environment.opens.count == 1, "Foreground activation alone is not a reconnect trigger")
        environment.foreground = false
        await reconnect.notificationTapped(id: notificationID)
        expect(environment.opens.count == 1, "Notification tap waits until the app is active")
        environment.foreground = true
        await reconnect.appBecameActive()
        expect(environment.opens.count == 2, "Notification tap hands off after activation")
        await reconnect.notificationTapped(id: notificationID)
        expect(environment.opens.count == 2, "Repeated or stale taps cannot rerun the shortcut")

        environment.foreground = false
        await reconnect.deviceWorkFinished(restoreVPN: true)
        let staleID = environment.notifications.last!.1
        reconnect.beginDeviceWork()
        environment.foreground = true
        await reconnect.notificationTapped(id: staleID)
        await reconnect.testShortcut()
        await reconnect.runPendingShortcut()
        expect(environment.opens.count == 2 && reconnect.pendingShortcutName == nil, "New work cancels pending restoration and blocks manual tests")
        await reconnect.deviceWorkFinished(restoreVPN: false)

        environment.canOpen = false
        await reconnect.testShortcut()
        expect(reconnect.pendingShortcutName != nil && reconnect.notice != nil, "Failed handoffs stay available for retry")
        environment.canOpen = true
        await reconnect.runPendingShortcut()
        expect(reconnect.pendingShortcutName == nil, "Manual retry consumes a successful handoff")

        environment.foreground = false
        environment.canNotify = false
        await reconnect.deviceWorkFinished(restoreVPN: true)
        expect(reconnect.notice?.contains("Enable Ksign notifications") == true, "Denied notification permission still offers an in-app recovery")
        let restored = environment.coordinator(defaults: defaults)
        expect(restored.pendingShortcutName != nil, "Pending background requests survive relaunch")
        let previousOpens = environment.opens.count
        environment.foreground = true
        await restored.notificationTapped(id: environment.notifications.last!.1)
        expect(environment.opens.count == previousOpens + 1, "Relaunched app accepts the matching notification")
        reconnect.disable()
        expect(reconnect.pendingShortcutName == nil, "Disabling the option cancels a pending handoff")
        defaults.set("   \n", forKey: VPNReconnectCoordinator.shortcutNameKey)
        await reconnect.testShortcut()
        expect(reconnect.notice?.contains("Enter the name") == true, "Empty shortcut names show setup guidance")

        defaults.set("Restore Tailscale", forKey: VPNReconnectCoordinator.shortcutNameKey)
        environment.foreground = false
        environment.holdNotification = true
        let background = Task { @MainActor in await reconnect.deviceWorkFinished(restoreVPN: true) }
        try await waitUntil("Notification should suspend") { environment.heldNotification != nil }
        reconnect.beginDeviceWork()
        let removals = environment.removals
        environment.heldNotification?.resume(returning: true)
        environment.heldNotification = nil
        await background.value
        expect(environment.removals > removals && reconnect.pendingShortcutName == nil, "Invalidate notification delivery racing with new work")
        environment.holdNotification = false
        await reconnect.deviceWorkFinished(restoreVPN: false)

        // Share sheet is the default, including for existing enabled installs
        // that have not explicitly selected the automatic URL handoff.
        defaults.removeObject(forKey: VPNReconnectCoordinator.presentationKey)
        expect(reconnect.presentation == .shareSheet, "Default to reconnection inside Ksign")
        environment.foreground = true
        let beforeShare = environment.opens.count
        await reconnect.deviceWorkFinished(restoreVPN: true)
        expect(environment.opens.count == beforeShare && environment.shareSheets.count == 1,
               "Foreground share mode presents a sheet without opening Shortcuts")
        expect(environment.shareSheets.last == "Restore Tailscale", "Remind the user which shortcut to select")
        await reconnect.runPendingShortcut()
        expect(environment.shareSheets.count == 1, "Repeated taps must not stack share sheets")
        environment.shareCompletions.last!(false)
        expect(reconnect.pendingShortcutName != nil && reconnect.notice?.contains("Show in Share Sheet") == true,
               "Cancelling keeps a reminder and explains missing shortcuts")
        await reconnect.runPendingShortcut()
        environment.shareCompletions.last!(true)
        expect(reconnect.pendingShortcutName == nil, "Completed sharing consumes the handoff without claiming VPN status")

        await reconnect.deviceWorkFinished(restoreVPN: true)
        let staleShareCompletion = environment.shareCompletions.last!
        reconnect.beginDeviceWork()
        expect(environment.shareDismissals == 1, "New work dismisses a pending share sheet")
        await reconnect.deviceWorkFinished(restoreVPN: true)
        staleShareCompletion(true)
        expect(reconnect.pendingShortcutName != nil, "An old sheet callback must not consume a newer request")
        reconnect.disable()
        expect(environment.shareDismissals == 2, "Disabling reconnect dismisses the current sheet")

        environment.canPresentShareSheet = false
        await reconnect.testShortcut()
        expect(reconnect.pendingShortcutName != nil && reconnect.notice?.contains("Could not show") == true,
               "Presentation failure keeps the request available for retry")
        environment.canPresentShareSheet = true
        await reconnect.runPendingShortcut()
        environment.shareCompletions.last!(true)

        environment.foreground = false
        let beforeBackgroundShare = environment.shareSheets.count
        await reconnect.deviceWorkFinished(restoreVPN: true)
        expect(environment.shareSheets.count == beforeBackgroundShare, "Background completion never presents a share sheet")
        let backgroundShareID = environment.notifications.last!.1
        await reconnect.notificationTapped(id: backgroundShareID)
        environment.foreground = true
        await reconnect.appBecameActive()
        expect(environment.shareSheets.count == beforeBackgroundShare + 1 && environment.opens.count == beforeShare,
               "A background notification opens the share sheet on activation without opening Shortcuts")
        environment.shareCompletions.last!(true)

        // Exercise the actual manager and tunnel, with asynchronous VPN stop.
        let (_, tunnel, fixtureDefaults) = fixture()
        fixtureDefaults.set(true, forKey: VPNReconnectCoordinator.enabledKey)
        fixtureDefaults.set(VPNReconnectPresentation.automatic.rawValue, forKey: VPNReconnectCoordinator.presentationKey)
        environment.foreground = true
        tunnel.connection.status = .disconnected
        let vpn = LocalDeviceVPN(extensionIdentifier: { "test.ksign.tunnel" })
        let manager = DeviceInstallationManager(vpn: vpn, defaults: fixtureDefaults,
            vpnReconnect: environment.coordinator(defaults: fixtureDefaults),
            legacyPairingExists: { false }, canCreatePairing: { true })
        let workflow = UUID()
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let first = launch(manager, "restoreFirst")
        let second = launch(manager, "restoreSecond")
        try await waitUntil("Concurrent restore scenario starts both jobs") { InstallationProxy.pending.count == 2 }
        let beforeCompletion = environment.opens.count
        finish("restoreFirst")
        try await first.value
        expect(environment.opens.count == beforeCompletion, "A completed app must not reconnect beneath another install")
        finish("restoreSecond", error: DeviceSetupError("Installation failed"))
        do { try await second.value; preconditionFailure("Expected install failure") } catch {}
        expect(environment.opens.count == beforeCompletion, "Retained workflows defer restoration after jobs finish")
        tunnel.connection.delayStop = true
        manager.releaseWorkflow(workflow)
        try await waitUntil("Cleanup should start disconnecting the owned tunnel") { tunnel.connection.status == .disconnecting }
        expect(environment.opens.count == beforeCompletion, "Shortcut must wait for VPN disconnection")
        tunnel.connection.status = .disconnected
        try await waitUntil("Cleanup should restore after disconnect") { environment.opens.count == beforeCompletion + 1 }
        await settle()
        expect(!manager.isBusy && manager.canReconnectVPN, "Handoff releases cleanup")
        manager.releaseWorkflow(workflow)
        await settle()
        expect(environment.opens.count == beforeCompletion + 1, "Repeated cleanup cannot reconnect twice")

        // New work arriving during disconnect must suppress the old handoff.
        InstallationProxy.holdInstalls = false
        tunnel.connection.delayStop = true
        try await manager.install(at: URL(fileURLWithPath: "/next.ipa"),
            viewModel: InstallerStatusViewModel(), suspend: false, mode: .builtIn)
        try await waitUntil("Next cleanup should stop the tunnel") { tunnel.connection.status == .disconnecting }
        manager.retainWorkflow(workflow)
        tunnel.connection.status = .disconnected
        try await waitUntil("Old cleanup should drain") { manager.phase == .configured }
        await settle()
        expect(environment.opens.count == beforeCompletion + 1, "New workflow during disconnect suppresses the previous reconnect")
        tunnel.connection.delayStop = false
        try await manager.install(at: URL(fileURLWithPath: "/new-workflow.ipa"),
            viewModel: InstallerStatusViewModel(), suspend: false, mode: .builtIn)
        manager.releaseWorkflow(workflow)
        try await waitUntil("New workflow should restore once it finishes") { environment.opens.count == beforeCompletion + 2 }
        await settle()

        fixtureDefaults.set(VPNReconnectPresentation.shareSheet.rawValue, forKey: VPNReconnectCoordinator.presentationKey)
        let beforeManagedShare = environment.shareSheets.count
        try await manager.install(at: URL(fileURLWithPath: "/share-workflow.ipa"),
            viewModel: InstallerStatusViewModel(), suspend: false, mode: .builtIn)
        try await waitUntil("Manager should present the share sheet after cleanup") {
            environment.shareSheets.count == beforeManagedShare + 1
        }
        await settle()
        expect(manager.canReconnectVPN, "Cleanup must finish while the share sheet is still awaiting user selection")
        expect(environment.opens.count == beforeCompletion + 2, "Share mode must not invoke the Shortcuts URL")
        environment.shareCompletions.last!(true)

        // Failure/cancellation may already stop the tunnel before final cleanup.
        let (_, cancelledTunnel, _) = fixture()
        cancelledTunnel.connection.status = .disconnected
        let cancelledVPN = LocalDeviceVPN(extensionIdentifier: { "test.ksign.tunnel" })
        try await cancelledVPN.connect()
        cancelledVPN.disconnectIfOwned()
        let restoreAfterCancellation = await cancelledVPN.finishSession()
        expect(restoreAfterCancellation, "Early cancellation cleanup retains the restoration request")
        let duplicateRestore = await cancelledVPN.finishSession()
        expect(!duplicateRestore, "A VPN session can request restoration only once")
        print("Passed VPN reconnect handoff scenarios")
    }
}
