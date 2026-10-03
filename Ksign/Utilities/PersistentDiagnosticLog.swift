import Foundation

// A bounded, append-only breadcrumb log. Callers enqueue without waiting for
// disk I/O; the utility worker flushes each event. Abrupt kills may lose queued events.
final class PersistentDiagnosticLog {
    private let queue = DispatchQueue(label: "nya.asami.ksign.diagnostic-file", qos: .utility)
    private let directory: URL
    private let maximumBytes: UInt64
    private let runID = UUID().uuidString
    private let formatter = ISO8601DateFormatter()
    private let pendingLock = NSLock()
    private var pendingCount = 0
    private var droppedCount = 0
    private let maximumPending = 64

    init(directory: URL, maximumBytes: UInt64 = 2 * 1024 * 1024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    func record(_ event: String, details: [String: String] = [:]) {
        let timestamp = Date()
        pendingLock.lock()
        guard pendingCount < maximumPending else {
            droppedCount += 1
            pendingLock.unlock()
            return
        }
        pendingCount += 1
        let dropped = droppedCount
        droppedCount = 0
        pendingLock.unlock()
        // Bound queued strings as well as the number of queued events.
        let boundedEvent = String(event.prefix(256))
        var boundedDetails: [String: String] = [:]
        for (key, value) in details.prefix(16) {
            boundedDetails[String(key.prefix(128))] = String(value.prefix(512))
        }
        let queuedDetails = boundedDetails
        queue.async {
            defer {
                self.pendingLock.lock()
                self.pendingCount -= 1
                self.pendingLock.unlock()
            }
            self.write(boundedEvent, details: queuedDetails, timestamp: timestamp, dropped: dropped)
        }
    }

    #if INSTALL_DIAGNOSTICS_TESTING
    // Tests wait for persistence; production callers have no blocking flush API.
    func waitForPendingWrites() { queue.sync { } }
    func holdWriter(started: DispatchSemaphore, release: DispatchSemaphore) {
        queue.async { started.signal(); release.wait() }
    }
    var pendingForTesting: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingCount
    }
    #endif

    private func write(_ event: String, details: [String: String], timestamp: Date, dropped: Int) {
        autoreleasepool {
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let current = directory.appendingPathComponent("diagnostics.jsonl")
                let previous = directory.appendingPathComponent("diagnostics-previous.jsonl")
                var row = details
                row["event"] = event
                row["time"] = formatter.string(from: timestamp)
                row["run"] = runID
                if dropped > 0 { row["dropped_events"] = String(dropped) }
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0a)
                let attributes = try? manager.attributesOfItem(atPath: current.path)
                let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                if size > 0 && size + UInt64(data.count) > maximumBytes {
                    if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                    try manager.moveItem(at: current, to: previous)
                }
                if !manager.fileExists(atPath: current.path) {
                    guard manager.createFile(atPath: current.path, contents: nil) else { return }
                }
                let file = try FileHandle(forWritingTo: current)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
                try file.synchronize()
            } catch {
                // Disk full, protected data, or a moved folder: retry on the next event.
            }
        }
    }
}
