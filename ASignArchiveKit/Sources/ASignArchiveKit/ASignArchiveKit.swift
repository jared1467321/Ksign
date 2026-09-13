import Foundation
import CASignArchive

public enum ASignArchiveCompression: Int, CaseIterable, Sendable {
    // Preserve the legacy compression preference raw values (0...3) so existing
    // Feather.compressionLevel settings migrate without changing behavior.
    case none = 0
    case speed = 1
    case standard = 2
    case best = 3

    fileprivate var minizipLevel: Int16 {
        switch self {
        case .none: return 0
        case .speed: return 1
        case .standard: return -1
        case .best: return 9
        }
    }
}

public enum ASignArchiveError: LocalizedError, Sendable {
    case extractionFailed(code: Int32)
    case creationFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .extractionFailed(let code):
            return "minizip-ng failed to extract the archive (error \(code))."
        case .creationFailed(let code):
            return "minizip-ng failed to create the archive (error \(code))."
        }
    }
}

private final class ProgressContext {
    let handler: (Double) -> Void

    init(handler: @escaping (Double) -> Void) {
        self.handler = handler
    }
}

private let progressBridge: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { progress, context in
    guard let context else { return }
    let box = Unmanaged<ProgressContext>.fromOpaque(context).takeUnretainedValue()
    box.handler(min(max(progress, 0), 1))
}

public enum ASignArchive {
    public static func extract(
        _ archiveURL: URL,
        to destinationURL: URL,
        progress: ((Double) -> Void)? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        let context = ProgressContext(handler: progress ?? { _ in })
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<ProgressContext>.fromOpaque(opaque).release() }

        let status: Int32 = archiveURL.path.withCString { archivePath in
            destinationURL.path.withCString { destinationPath in
                asign_archive_extract(archivePath, destinationPath, progressBridge, opaque)
            }
        }

        guard status == 0 else {
            throw ASignArchiveError.extractionFailed(code: status)
        }
    }

    public static func create(
        from sourceURL: URL,
        at archiveURL: URL,
        compression: ASignArchiveCompression,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }

        let totalSize = try totalRegularFileSize(at: sourceURL)
        let context = ProgressContext(handler: progress ?? { _ in })
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<ProgressContext>.fromOpaque(opaque).release() }

        let status: Int32 = archiveURL.path.withCString { archivePath in
            sourceURL.path.withCString { sourcePath in
                asign_archive_create(
                    archivePath,
                    sourcePath,
                    compression.minizipLevel,
                    totalSize,
                    progressBridge,
                    opaque
                )
            }
        }

        guard status == 0 else {
            try? fileManager.removeItem(at: archiveURL)
            throw ASignArchiveError.creationFailed(code: status)
        }
    }

    private static func totalRegularFileSize(at rootURL: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]

        let rootValues = try rootURL.resourceValues(forKeys: Set(keys))
        if rootValues.isRegularFile == true {
            return Int64(rootValues.fileSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if Int64.max - total < size {
                return Int64.max
            }
            total += size
        }
        return total
    }
}
