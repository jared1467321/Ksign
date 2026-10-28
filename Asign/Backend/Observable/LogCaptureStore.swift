import Foundation

// Fixed-capacity recent history. Evicted messages release their strings
// immediately; capture never shifts a growing array for every stdout line.
struct LogTail {
    private var storage: [LogEntry?]
    private var head = 0
    private(set) var count = 0
    private(set) var byteCount = 0
    private let maximumBytes: Int

    init(maximumEntries: Int = 1_000, maximumBytes: Int = 1_048_576) {
        precondition(maximumEntries > 0 && maximumBytes > 0)
        storage = Array(repeating: nil, count: maximumEntries)
        self.maximumBytes = maximumBytes
    }

    var entries: [LogEntry] {
        (0..<count).compactMap { storage[(head + $0) % storage.count] }
    }

    mutating func append(_ entry: LogEntry) {
        let bytes = entry.message.utf8.count
        // Oversized messages still go to the session file in full.
        guard bytes <= maximumBytes else { return }
        while count > 0 && (count == storage.count || byteCount + bytes > maximumBytes) {
            byteCount -= storage[head]!.message.utf8.count
            storage[head] = nil
            head = (head + 1) % storage.count
            count -= 1
        }
        storage[(head + count) % storage.count] = entry
        count += 1
        byteCount += bytes
    }

    mutating func clear() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
        byteCount = 0
    }
}

// The queue owns the file, recent tail and revision. Pipe reads append
// synchronously on their background callback, so slow storage applies pipe
// backpressure instead of building an unbounded queue of retained Data blocks.
final class SessionLogStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let revision: UInt64
        let entries: [LogEntry]
        let totalEntryCount: Int
    }

    private let queue = DispatchQueue(label: "Asign captured log storage", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let fileURL: URL
    private var writer: FileHandle?
    private var writeError: Error?
    private var tail = LogTail()
    private var revision: UInt64 = 0
    private var totalEntryCount = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    deinit { try? writer?.close() }

    @discardableResult
    func append(_ data: Data) -> Bool {
        queue.sync {
            do { try prepareWriter().write(contentsOf: data) }
            catch { writeError = error }
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            guard !lines.isEmpty else { return false }
            for line in lines { tail.append(LogEntry(message: String(line))) }
            totalEntryCount += lines.count
            revision &+= 1
            return true
        }
    }

    func snapshot(_ completion: @escaping @Sendable (Snapshot) -> Void) {
        queue.async { completion(self.currentSnapshot()) }
    }

    func clear(_ completion: @escaping @Sendable (Snapshot) -> Void) {
        queue.async {
            do {
                let writer = try self.prepareWriter()
                try writer.truncate(atOffset: 0)
                try writer.seek(toOffset: 0)
                self.writeError = nil
            } catch { self.writeError = error }
            self.tail.clear()
            self.totalEntryCount = 0
            self.revision &+= 1
            completion(self.currentSnapshot())
        }
    }

    func export(to directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if let error = self.writeError { throw error }
                    _ = try self.prepareWriter()
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                    let date = formatter.string(from: Date())
                    let url = directory.appendingPathComponent("Asign-Logs-\(date)-\(UUID().uuidString).txt")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let output = try FileHandle(forWritingTo: url)
                    defer { try? output.close() }
                    let header = "Asign Logs Export\nExported: \(date)\nTotal entries: \(self.totalEntryCount)\n"
                        + String(repeating: "=", count: 30) + "\n\n"
                    try output.write(contentsOf: Data(header.utf8))
                    let input = try FileHandle(forReadingFrom: self.fileURL)
                    defer { try? input.close() }
                    // Export is a serialized snapshot of the full session. Only
                    // one small chunk is resident, even for very long sessions.
                    while try autoreleasepool(invoking: {
                        guard let data = try input.read(upToCount: 65_536), !data.isEmpty else { return false }
                        try output.write(contentsOf: data)
                        return true
                    }) {}
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(revision: revision, entries: tail.entries, totalEntryCount: totalEntryCount)
    }

    private func prepareWriter() throws -> FileHandle {
        if let writer { return writer }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let writer = try FileHandle(forWritingTo: fileURL)
        self.writer = writer
        return writer
    }
}
