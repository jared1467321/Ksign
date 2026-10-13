import Foundation

extension ConnectionRecoveryTests {
    @MainActor static func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            precondition(Date() < deadline, message)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor static func launch(_ manager: DeviceInstallationManager, _ name: String,
                                  suspend: Bool = false, mode: DeviceConnectionMode = .builtIn,
                                  bundle: String? = nil) -> Task<Void, Error> {
        Task { @MainActor in
            try await manager.install(at: URL(fileURLWithPath: "/\(name)"),
                viewModel: InstallerStatusViewModel(), suspend: suspend, mode: mode,
                bundleIdentifier: bundle)
        }
    }

    @MainActor static func finish(_ name: String, error: Error? = nil) {
        guard let continuation = InstallationProxy.pending.removeValue(forKey: name) else {
            preconditionFailure("No active install named \(name)")
        }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    @MainActor static func expectCancellation(_ task: Task<Void, Error>) async {
        do { try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        catch { preconditionFailure("Unexpected error: \(error)") }
    }

    @MainActor static func runConcurrencyTests() async throws {
        let workflow = UUID()
        var (manager, _, _) = fixture()
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let batch = (0..<5).map { launch(manager, "app\($0)") }
        try await waitUntil("All five installs should overlap") { InstallationProxy.pending.count == 5 }
        expect(manager.pendingOperations == 5, "Count full install lifetimes, not just preparation")
        expect(HeartbeatManager.shared.attempts.count == 1, "Concurrent installs should share one setup")
        for index in 0..<5 { finish("app\(index)") }
        for task in batch { try await task.value }
        expect(!manager.isBusy, "All completed leases should be released")
        manager.releaseWorkflow(workflow)
        await settle()

        (manager, _, _) = fixture()
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let cancelled = launch(manager, "cancelled")
        let survivor = launch(manager, "survivor")
        try await waitUntil("Two installs should overlap") { InstallationProxy.pending.count == 2 }
        cancelled.cancel()
        await settle()
        expect(manager.pendingOperations == 2, "Cancellation must await native cleanup")
        finish("cancelled")
        await expectCancellation(cancelled)
        let replacement = launch(manager, "replacement")
        try await waitUntil("Cancellation must not cancel a peer") { InstallationProxy.pending.count == 2 }
        expect(HeartbeatManager.shared.attempts.count == 1, "Cancellation should not reconnect healthy peers")
        finish("survivor")
        finish("replacement")
        try await survivor.value
        try await replacement.value
        manager.releaseWorkflow(workflow)
        await settle()

        (manager, _, _) = fixture()
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let failing = launch(manager, "failing")
        let active = launch(manager, "active")
        try await waitUntil("Failure scenario needs concurrent peers") { InstallationProxy.pending.count == 2 }
        finish("failing", error: DeviceSetupError("Connection lost"))
        do { try await failing.value; preconditionFailure("Expected failure") } catch {}
        let recovered = launch(manager, "recovered")
        try await waitUntil("Next job should wait for recovery") { manager.pendingOperations == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        expect(InstallationProxy.pending["recovered"] == nil, "Do not admit during deferred recovery")
        expect(HeartbeatManager.shared.attempts.count == 1, "Do not reconnect beneath an active peer")
        finish("active")
        try await active.value
        try await waitUntil("Recover after peers drain") { InstallationProxy.pending["recovered"] != nil }
        expect(HeartbeatManager.shared.attempts.count == 2, "Prepare a fresh connection after failure")
        expect(InstallationProxy.calls == 3, "Never replay the failed installation")
        finish("recovered")
        try await recovered.value
        manager.releaseWorkflow(workflow)
        await settle()

        (manager, _, _) = fixture()
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let beforeUpdate = launch(manager, "beforeUpdate")
        try await waitUntil("Start ordinary install") { InstallationProxy.pending.count == 1 }
        let update = launch(manager, "selfUpdate", suspend: true)
        try await waitUntil("Self-update should wait") { manager.pendingOperations == 2 }
        let afterUpdate = launch(manager, "afterUpdate")
        try await waitUntil("Later work should queue behind self-update") { manager.pendingOperations == 3 }
        expect(InstallationProxy.pending.count == 1, "Self-update cannot overlap an active install")
        finish("beforeUpdate")
        try await beforeUpdate.value
        try await waitUntil("Self-update should enter alone") { InstallationProxy.pending["selfUpdate"] != nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        expect(InstallationProxy.pending.count == 1, "New work cannot overlap self-update")
        finish("selfUpdate")
        try await update.value
        try await waitUntil("Resume work after exclusive install") { InstallationProxy.pending["afterUpdate"] != nil }
        finish("afterUpdate")
        try await afterUpdate.value
        manager.releaseWorkflow(workflow)
        await settle()

        (manager, _, _) = fixture(legacy: true)
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let builtIn = launch(manager, "builtIn")
        try await waitUntil("Start built-in install") { InstallationProxy.pending.count == 1 }
        let manual = launch(manager, "manual", mode: .manual)
        try await waitUntil("Mode change should wait") { manager.pendingOperations == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        expect(HeartbeatManager.shared.attempts.count == 1, "Mode changes must drain active connections")
        finish("builtIn")
        try await builtIn.value
        try await waitUntil("Manual install should enter after mode switch") { InstallationProxy.pending["manual"] != nil }
        expect(HeartbeatManager.shared.attempts.count == 2, "Set up the new mode once")
        expect(HeartbeatManager.shared.attempts.last! == nil, "Manual mode uses imported credentials")
        finish("manual")
        try await manual.value
        manager.releaseWorkflow(workflow)
        await settle()

        (manager, _, _) = fixture()
        manager.retainWorkflow(workflow)
        InstallationProxy.holdInstalls = true
        let original = launch(manager, "original", bundle: "same.bundle")
        try await waitUntil("Start original app") { InstallationProxy.pending.count == 1 }
        let duplicate = launch(manager, "duplicate", bundle: "same.bundle")
        try await waitUntil("Duplicate bundle should wait") { manager.pendingOperations == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        expect(InstallationProxy.pending.count == 1, "Never install the same bundle concurrently")
        duplicate.cancel()
        await expectCancellation(duplicate)
        expect(manager.pendingOperations == 1, "Cancelled admission must release only its own lease")
        finish("original")
        try await original.value
        manager.releaseWorkflow(workflow)
        await settle()
        print("Passed 6 native installation concurrency scenarios")
    }
}
