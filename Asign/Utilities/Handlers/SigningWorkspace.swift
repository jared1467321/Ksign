import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns every mutable input for one signing operation. Shared prepared tweaks
/// are copied into this directory before patching; no writable tree is reused.
final class SigningWorkspace {
    let id: UUID
    let directory: URL

    init(root: URL = FileManager.default.temporaryDirectory, id: UUID = UUID()) {
        self.id = id
        directory = root.appendingPathComponent("FeatherSigning_" + id.uuidString, isDirectory: true)
    }

    func create() throws {
        // Refuse even an existing empty directory or a pre-existing symlink.
        guard (try? FileManager.default.attributesOfItem(atPath: directory.path)) == nil else {
            throw Failure.escaped(directory.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.escaped(directory.path) }
    }

    func sanitize(_ app: URL) throws {
        try sanitizeContents(at: app)
    }

    // After the initial scan, only imported/materialized destinations can add
    // links or executable metadata. Existing files stay private to this job;
    // our plist edits, Mach-O patches and signer only change their contents.
    func sanitizeAdditions(_ paths: [URL]) throws {
        var checked: [String] = []
        for path in Set(paths.map { $0.standardizedFileURL }).sorted(by: { $0.path < $1.path }) {
            if checked.contains(where: { path.path.hasPrefix($0 + "/") }) { continue }
            try sanitizeContents(at: path, allowMissing: true)
            checked.append(path.path)
        }
    }

#if ARCHIVE_MEMORY_TESTING
    var didValidateFile: ((URL) -> Void)?
#endif

    /// Use filesystem spelling consistently, including for paths whose final
    /// components do not exist (for example MobileInstallation placeholders).
    /// Foundation can strip /private from an existing path but retain it for a
    /// missing file, so independently normalized URL strings cannot be compared.
    private static func canonicalPath(_ url: URL) throws -> String {
        let path = url.path
        guard !path.contains("\0") else { throw Failure.escaped(path) }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let code = errno
        guard code == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }

        // Resolve existing ancestors even when realpath cannot resolve the whole
        // path. Follow links explicitly: peeling a dangling link off as though it
        // were a missing filename could conceal an external destination.
        let manager = FileManager.default
        var pending = Array(path.split(separator: "/").map(String.init).reversed())
        var resolved: [String] = []
        var links = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            let attributes: [FileAttributeKey: Any]
            do { attributes = try manager.attributesOfItem(atPath: candidate) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                resolved.append(component)
                continue
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                links += 1
                guard links <= 40 else { throw Failure.escaped(path) }
                let target = try manager.destinationOfSymbolicLink(atPath: candidate)
                if target.hasPrefix("/") { resolved.removeAll() }
                pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
            } else {
                resolved.append(component)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    private func sanitizeContents(at path: URL, allowMissing: Bool = false) throws {
        let manager = FileManager.default
        let canonicalRoot = try Self.canonicalPath(directory)
        let root = canonicalRoot + "/"
        // Enumeration can return the physical path even when the workspace was
        // opened through an alias. Accept both roots, including Foundation's
        // /private-stripped spelling, for the lexical check. The filesystem
        // containment check below still resolves every candidate independently.
        let lexicalRoots = [directory, URL(fileURLWithPath: canonicalRoot)].flatMap {
            [$0.path + "/", $0.standardizedFileURL.path + "/"]
        }
        func lexicallyContains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return lexicalRoots.contains(where: { path.hasPrefix($0) })
        }
        func contains(_ url: URL) throws -> Bool {
            try Self.canonicalPath(url).hasPrefix(root)
        }
        func validate(_ file: URL, attributes: [FileAttributeKey: Any]) throws -> FileAttributeType? {
#if ARCHIVE_MEMORY_TESTING
            didValidateFile?(file)
#endif
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                // Framework Versions/Current links are fine if they stay inside
                // this job. Absolute/external links may never redirect writes.
                let target = try manager.destinationOfSymbolicLink(atPath: file.path)
                let targetURL = target.hasPrefix("/") ? URL(fileURLWithPath: target) :
                    file.deletingLastPathComponent().appendingPathComponent(target)
                // Reject lexical escapes as well as destinations reached
                // through links, including links whose targets do not exist.
                guard lexicallyContains(targetURL), try contains(targetURL) else {
                    throw Failure.escaped(file.path)
                }
            } else if type == .typeRegular, ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) > 1 {
                let copy = file.deletingLastPathComponent().appendingPathComponent(".FeatherPrivate_" + UUID().uuidString)
                defer { try? manager.removeItem(at: copy) }
                try manager.copyItem(at: file, to: copy)
                try manager.removeItem(at: file)
                try manager.moveItem(at: copy, to: file)
            }
            if file.lastPathComponent == "Info.plist" {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                guard data.count <= 16 * 1024 * 1024 else { throw Failure.oversizedMetadata(file.path) }
                if let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let executable = info["CFBundleExecutable"] as? String {
                    let executableURL = executable.hasPrefix("/") ? URL(fileURLWithPath: executable) :
                        file.deletingLastPathComponent().appendingPathComponent(executable)
                    guard lexicallyContains(executableURL), try contains(executableURL) else {
                        throw Failure.escaped("\(file.path) (CFBundleExecutable: \(executable))")
                    }
                }
            }
            return type
        }
        guard try contains(path) else { throw Failure.escaped(path.path) }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: path.path) }
        catch let error as CocoaError where allowMissing && (error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile) {
            // Preparing a destination can remove it without installing a replacement.
            return
        }
        let type = try validate(path, attributes: attributes)
        if type == .typeSymbolicLink {
            // A requested root can itself be a framework alias. Inspect its
            // target directory too; enumeration below only skips child links.
            let target = path.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try sanitizeContents(at: target)
            }
            return
        }
        guard type == .typeDirectory else { return }
        var enumerationError: Error?
        guard let entries = manager.enumerator(at: path, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure.escaped(path.path) }
        for case let file as URL in entries {
            if try validate(file, attributes: manager.attributesOfItem(atPath: file.path)) == .typeSymbolicLink { entries.skipDescendants() }
        }
        if let enumerationError { throw enumerationError }
    }

    func clean() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    enum Failure: LocalizedError {
        case escaped(String)
        case oversizedMetadata(String)
        var errorDescription: String? {
            switch self {
            case .oversizedMetadata(let path): return "An app Info.plist exceeds the signing metadata limit: \(path)"
            case .escaped(let path): return "An app file points outside its private signing workspace: \(path)"
            }
        }
    }
}

/// Core Data records remain on their context's queue; workers use a value copy.
struct SigningAppSnapshot: AppInfoPresentable {
    let name: String?
    let version: String?
    let identifier: String?
    let date: Date?
    let icon: String?
    let uuid: String?
    let isSigned: Bool

    init(_ app: AppInfoPresentable) {
        name = app.name; version = app.version; identifier = app.identifier
        date = app.date; icon = app.icon; uuid = app.uuid; isSigned = app.isSigned
    }
}
