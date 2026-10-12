import Foundation

// Native AFC handles require serialized use on the creating thread. A serial
// DispatchQueue alone can move successive operations between OS threads.
final class IDeviceInstallationWorker {
    static let shared = IDeviceInstallationWorker()
    private let condition = NSCondition()
    private var operations: [() -> Void] = []

    private init() {
        let thread = Thread { [self] in
            while true {
                condition.lock()
                while operations.isEmpty { condition.wait() }
                let operation = operations.removeFirst()
                condition.unlock()
                autoreleasepool { operation() }
            }
        }
        thread.name = "Ksign device installation"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            operations.append {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
            condition.signal()
            condition.unlock()
        }
    }
}

final class IDeviceInstallCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
}
