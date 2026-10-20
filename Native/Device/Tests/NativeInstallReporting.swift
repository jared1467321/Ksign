import Foundation

final class InstallerStatusViewModel {
    enum InstallerStatus {
        case none, ready, sendingManifest, sendingPayload, installing
        case completed(Result<Void, Error>)
        case broken(Error)
    }
    var nativeInstallObserver: ((IDeviceInstallEvent) -> Void)?
}
struct IDeviceInstallSkip: Error {}
final class BackgroundTaskManager {
    enum Owner { case bulkInstalls }
    static let shared = BackgroundTaskManager()
    private let lock = NSLock()
    private var fraction = 0.0
    func clearReport(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        fraction = 0
    }
    func report(_ owner: Owner, completed: Int, total: Int, fraction: Double,
                detail: String, currentItem: String?) {
        lock.lock(); defer { lock.unlock() }
        self.fraction = fraction
    }
    func expect(_ expected: Double) {
        lock.lock(); defer { lock.unlock() }
        precondition(fraction == expected, "Stale attempts must not change Live Activity progress")
    }
}

// The runner supplies the actual observer assignment from InstallJob, the
// status epoch, packaging cancellation token, and Live Activity aggregator.
private func configure(_ viewModel: InstallerStatusViewModel, attempt: PackagingAttempt,
               statusEpoch: InstallStatusEpoch, jobID: UUID) {
    let epoch = statusEpoch.current
    // PRODUCTION_NATIVE_OBSERVER
}

@main struct NativeInstallReportingTests {
    static func main() {
        let reporter = BulkInstallLiveActivityReporter.shared
        let model = InstallerStatusViewModel()
        let epoch = InstallStatusEpoch()
        let first = PackagingAttempt(), retry = PackagingAttempt()
        let jobID = UUID()
        reporter.reset()
        reporter.register(jobID, name: "Native app")
        configure(model, attempt: first, statusEpoch: epoch, jobID: jobID)
        let originalObserver = model.nativeInstallObserver!
        first.cancel()
        epoch.advance()
        configure(model, attempt: retry, statusEpoch: epoch, jobID: jobID)

        originalObserver(.uploading)
        originalObserver(.installing)
        originalObserver(.progress(1))
        reporter.register(jobID, name: "Native app") // serial-queue barrier
        BackgroundTaskManager.shared.expect(0)

        model.nativeInstallObserver?(.uploading)
        model.nativeInstallObserver?(.installing)
        model.nativeInstallObserver?(.progress(0.25))
        reporter.register(jobID, name: "Native app")
        BackgroundTaskManager.shared.expect(0.625)

        retry.cancel()
        model.nativeInstallObserver?(.progress(1))
        reporter.register(jobID, name: "Native app")
        BackgroundTaskManager.shared.expect(0.625)

        let finalAttempt = PackagingAttempt()
        epoch.advance()
        configure(model, attempt: finalAttempt, statusEpoch: epoch, jobID: jobID)
        // The epoch guard must work independently of the cancellation token.
        let finalObserver = model.nativeInstallObserver!
        epoch.cancel()
        finalObserver(.progress(1))
        reporter.register(jobID, name: "Native app")
        BackgroundTaskManager.shared.expect(0.625)
        print("Passed independent native Live Activity telemetry and cancellation/retry epoch isolation")
    }
}
