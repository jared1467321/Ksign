import Foundation

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
        let manager = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let lexicalRoot = directory.standardizedFileURL.path + "/"
        func lexicallyContains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(lexicalRoot) || path.hasPrefix(root)
        }
        func contains(_ url: URL) -> Bool {
            url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
        }
        var enumerationError: Error?
        guard contains(app), let entries = manager.enumerator(at: app, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure.escaped(app.path) }
        for case let file as URL in entries {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                // Framework Versions/Current links are fine if they stay inside
                // this job. Absolute/external links may never redirect writes.
                let target = try manager.destinationOfSymbolicLink(atPath: file.path)
                let targetURL = target.hasPrefix("/") ? URL(fileURLWithPath: target) :
                    file.deletingLastPathComponent().appendingPathComponent(target)
                // resolvingSymlinksInPath may leave dangling links unresolved;
                // check the lexical target too, before trusting its resolution.
                guard lexicallyContains(targetURL), contains(targetURL) else {
                    throw Failure.escaped(file.path)
                }
                entries.skipDescendants()
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
                    guard lexicallyContains(executableURL), contains(executableURL) else {
                        throw Failure.escaped(executable)
                    }
                }
            }
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
