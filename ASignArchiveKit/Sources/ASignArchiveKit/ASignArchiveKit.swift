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
    case materializationFailed(code: Int32)
    case entryAccessFailed(code: Int32)
    case overlayRebuildFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .extractionFailed(let code):
            return "minizip-ng failed to extract the archive (error \(code))."
        case .creationFailed(let code):
            return "minizip-ng failed to create the archive (error \(code))."
        case .materializationFailed(let code):
            return "minizip-ng failed to materialize sparse signing inputs (error \(code))."
        case .entryAccessFailed(let code):
            return "minizip-ng failed to access an archive entry (error \(code))."
        case .overlayRebuildFailed(let code):
            return "minizip-ng failed to build the archive-backed signed IPA (error \(code))."
        }
    }
}

public struct ASignArchiveEntry: Sendable, Hashable {
    public let path: String
    public let uncompressedSize: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool

    public init(path: String, uncompressedSize: Int64, isDirectory: Bool, isSymlink: Bool) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

private final class EntryListContext {
    var entries: [ASignArchiveEntry] = []
}

private let entryListBridge: @convention(c) (UnsafePointer<CChar>?, Int64, UInt8, UInt8, UnsafeMutableRawPointer?) -> Int32 = { path, size, isDirectory, isSymlink, context in
    guard let path, let context else { return -102 }
    let box = Unmanaged<EntryListContext>.fromOpaque(context).takeUnretainedValue()
    box.entries.append(ASignArchiveEntry(
        path: String(cString: path),
        uncompressedSize: size,
        isDirectory: isDirectory != 0,
        isSymlink: isSymlink != 0
    ))
    return 0
}

private let archiveNotFoundStatus: Int32 = 1

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
    /// Returns central-directory entries in archive order. Duplicate names are
    /// preserved so callers can deliberately apply last-entry-wins semantics.
    public static func entries(in archiveURL: URL) throws -> [ASignArchiveEntry] {
        let context = EntryListContext()
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<EntryListContext>.fromOpaque(opaque).release() }

        let status: Int32 = archiveURL.path.withCString { archivePath in
            asign_archive_enumerate_entries(archivePath, entryListBridge, opaque)
        }
        guard status == 0 else {
            throw ASignArchiveError.entryAccessFailed(code: status)
        }
        return context.entries
    }

    /// Reads one small member through minizip-ng. The final duplicate with the
    /// requested name wins, matching the archive-backed logical view.
    public static func readEntry(
        from archiveURL: URL,
        path: String,
        maximumBytes: Int64
    ) throws -> Data? {
        precondition(maximumBytes >= 0)
        var bytes: UnsafeMutablePointer<UInt8>?
        var size: Int64 = 0
        let status: Int32 = archiveURL.path.withCString { archivePath in
            path.withCString { entryPath in
                asign_archive_read_entry(archivePath, entryPath, maximumBytes, &bytes, &size)
            }
        }
        if status == archiveNotFoundStatus { return nil }
        guard status == 0 else {
            throw ASignArchiveError.entryAccessFailed(code: status)
        }
        guard size >= 0, size <= Int64(Int.max) else {
            if let bytes { asign_archive_free_buffer(bytes) }
            throw ASignArchiveError.entryAccessFailed(code: -5)
        }
        guard let bytes else {
            return size == 0 ? Data() : nil
        }
        defer { asign_archive_free_buffer(bytes) }
        return Data(bytes: bytes, count: Int(size))
    }

    @discardableResult
    public static func extractEntry(
        from archiveURL: URL,
        path: String,
        to destinationURL: URL
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let status: Int32 = archiveURL.path.withCString { archivePath in
            path.withCString { entryPath in
                destinationURL.path.withCString { destinationPath in
                    asign_archive_extract_entry(archivePath, entryPath, destinationPath)
                }
            }
        }
        if status == archiveNotFoundStatus { return false }
        guard status == 0 else {
            throw ASignArchiveError.entryAccessFailed(code: status)
        }
        return true
    }

    @discardableResult
    public static func extractPrefix(
        from archiveURL: URL,
        prefix: String,
        to destinationURL: URL
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let status: Int32 = archiveURL.path.withCString { archivePath in
            prefix.withCString { prefixPath in
                destinationURL.path.withCString { destinationPath in
                    asign_archive_extract_prefix(archivePath, prefixPath, destinationPath)
                }
            }
        }
        if status == archiveNotFoundStatus { return false }
        guard status == 0 else {
            throw ASignArchiveError.entryAccessFailed(code: status)
        }
        return true
    }

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

    /// Materialize only the files zsign or ASign modification logic must touch on disk.
    /// Untouched resources remain archive-backed.
    public static func materializeSigningInputs(
        from archiveURL: URL,
        rootAppPath: String,
        to destinationAppURL: URL,
        includeInfoPlistStrings: Bool = false
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationAppURL,
            withIntermediateDirectories: true
        )

        let status: Int32 = archiveURL.path.withCString { archivePath in
            rootAppPath.withCString { rootPath in
                destinationAppURL.path.withCString { destinationPath in
                    asign_archive_materialize_signing_inputs(
                        archivePath,
                        rootPath,
                        destinationPath,
                        includeInfoPlistStrings ? 1 : 0
                    )
                }
            }
        }

        guard status == 0 else {
            throw ASignArchiveError.materializationFailed(code: status)
        }
    }

    /// Build the final IPA from an original IPA plus a sparse on-disk overlay.
    /// Untouched members are copied raw by minizip-ng, preserving their compressed
    /// bytes rather than inflating and recompressing them.
    public static func rebuildWithOverlay(
        from sourceArchiveURL: URL,
        at destinationArchiveURL: URL,
        rootAppPath: String,
        overlayAppURL: URL,
        deletedPaths: Set<String> = [],
        omitExistingCodeSignatures: Bool = true,
        compression: ASignArchiveCompression = .none,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationArchiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationArchiveURL.path) {
            try fileManager.removeItem(at: destinationArchiveURL)
        }

        // Newline is intentionally the transport delimiter: validated logical IPA
        // paths cannot contain it, and the C side never interprets shell syntax.
        let deletionList = deletedPaths.sorted().joined(separator: "\n")
        let context = ProgressContext(handler: progress ?? { _ in })
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<ProgressContext>.fromOpaque(opaque).release() }

        let status: Int32 = sourceArchiveURL.path.withCString { sourcePath in
            destinationArchiveURL.path.withCString { destinationPath in
                rootAppPath.withCString { rootPath in
                    overlayAppURL.path.withCString { overlayPath in
                        deletionList.withCString { deletedPathList in
                            asign_archive_rebuild_with_overlay(
                                sourcePath,
                                destinationPath,
                                rootPath,
                                overlayPath,
                                deletedPathList,
                                omitExistingCodeSignatures ? 1 : 0,
                                compression.minizipLevel,
                                progressBridge,
                                opaque
                            )
                        }
                    }
                }
            }
        }

        guard status == 0 else {
            try? fileManager.removeItem(at: destinationArchiveURL)
            throw ASignArchiveError.overlayRebuildFailed(code: status)
        }
    }

    public static func create(
        from sourceURL: URL,
        at archiveURL: URL,
        compression: ASignArchiveCompression,
        beforeNative: (() throws -> Void)? = nil,
        afterNative: (() -> Void)? = nil,
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

        // The caller holds its archive lease across this size scan, native
        // creation and resource release. Cancellation may stop before C starts;
        // after that, the synchronous writer must close normally.
        try beforeNative?()
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

        afterNative?()

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

        let resourceKeys = Set(keys)
        var total: Int64 = 0
        while try autoreleasepool(invoking: {
            guard let url = enumerator.nextObject() as? URL else { return false }
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isRegularFile == true, values.isSymbolicLink != true {
                let size = Int64(values.fileSize ?? 0)
                total = Int64.max - total < size ? Int64.max : total + size
            }
            return total != Int64.max
        }) { }
        return total
    }
}
