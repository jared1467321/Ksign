import Foundation

@main
struct LogTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("diagnostics.jsonl")
        let previous = directory.appendingPathComponent("diagnostics-previous.jsonl")
        func rows(_ url: URL) throws -> [[String: String]] {
            try Data(contentsOf: url).split(separator: 0x0a).map {
                try JSONSerialization.jsonObject(with: Data($0)) as! [String: String]
            }
        }
        let log = PersistentDiagnosticLog(directory: directory, maximumBytes: 1024)
        log.record("first", details: ["message": "newlines\nquotes\" remain valid JSON"])
        log.waitForPendingWrites()
        let first = try rows(current)
        precondition(first.count == 1 && first[0]["event"] == "first")
        precondition(first[0]["message"] == "newlines\nquotes\" remain valid JSON")
        // A second instance represents a process relaunch: preserve old evidence.
        let relaunched = PersistentDiagnosticLog(directory: directory, maximumBytes: 1024)
        relaunched.record("relaunch")
        relaunched.waitForPendingWrites()
        let launches = try rows(current)
        precondition(launches.count == 2 && launches[0]["run"] != launches[1]["run"])
        // A stalled disk worker must not stall callers or grow an unlimited queue.
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        log.holdWriter(started: started, release: release)
        precondition(started.wait(timeout: .now() + 5) == .success)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            log.record("concurrent", details: ["index": String(index)])
        }
        precondition(log.pendingForTesting == 64)
        release.signal()
        log.waitForPendingWrites()
        log.record("after_overflow")
        log.waitForPendingWrites()
        let retainedCurrent = try rows(current)
        let retainedPrevious = try rows(previous)
        precondition(!retainedCurrent.isEmpty && !retainedPrevious.isEmpty)
        precondition(retainedCurrent.last?["dropped_events"] == "36")
        for url in [current, previous] {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
            precondition(size.uint64Value <= 1024)
        }
        // An unwritable destination must not throw or crash the caller.
        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        let failedLog = PersistentDiagnosticLog(directory: blocked)
        failedLog.record("ignored")
        failedLog.waitForPendingWrites()
        print("Diagnostic persistence, rotation, concurrent writes, relaunch and failure checks passed")
    }
}
