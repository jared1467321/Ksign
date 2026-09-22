import Foundation

protocol ObservableObject: AnyObject {}

final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    static let willEnterForegroundNotification = Notification.Name("test.foreground")
    static let didBecomeActiveNotification = Notification.Name("test.active")
    var applicationState = State.active
}

class BGTask: NSObject {}
final class BGContinuedProcessingTask: BGTask {
    let progress = Progress(totalUnitCount: 0)
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []
    var title = ""
    var subtitle = ""
    func updateTitle(_ title: String, subtitle: String) {
        precondition(completions.isEmpty, "Updated a retired task")
        self.title = title
        self.subtitle = subtitle
    }
    func setTaskCompleted(success: Bool) {
        precondition(completions.isEmpty, "Completed a task twice")
        completions.append(success)
    }
}

final class BGContinuedProcessingTaskRequest {
    enum Strategy { case queue }
    var strategy = Strategy.queue
    let identifier: String
    init(identifier: String, title: String, subtitle: String) { self.identifier = identifier }
}

final class BGTaskScheduler {
    static let shared = BGTaskScheduler()
    private let lock = NSLock()
    private var pending: Set<String> = []
    var rejectSubmission = false // Tests change this only with the submission queue drained.
    func register(forTaskWithIdentifier: String, using: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool { true }
    func submit(_ request: BGContinuedProcessingTaskRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectSubmission { throw NSError(domain: "TestSubmission", code: 1) }
        pending.insert(request.identifier)
    }
    func cancel(taskRequestWithIdentifier identifier: String) {
        lock.lock(); defer { lock.unlock() }
        pending.remove(identifier)
    }
    func contains(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending.contains(identifier)
    }
}

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    func claimSystemTask(_ key: String) {}
    func releaseSystemTask(_ key: String) {}
}
