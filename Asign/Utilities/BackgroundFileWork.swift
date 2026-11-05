import Foundation

enum BackgroundFileWork {
    private static let queue = DispatchQueue(label: "Asign.file-work", qos: .utility)

    static func perform<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

enum TweakFileStore {
    static func list(in directory: URL) -> [URL] {
        let allowed: Set<String> = ["dylib", "deb", "framework", "bundle"]
        return ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []).filter { allowed.contains($0.pathExtension.lowercased()) }
    }

    static func importFiles(_ urls: [URL], to directory: URL) -> [URL] {
        let manager = FileManager.default
        do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { print("Error creating tweaks directory: \(error)"); return [] }
        let allowed: Set<String> = ["dylib", "deb", "framework", "bundle"]
        var imported: [URL] = []
        for url in urls where allowed.contains(url.pathExtension.lowercased()) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            do {
                if url.standardizedFileURL != destination.standardizedFileURL {
                    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                    try manager.copyItem(at: url, to: destination)
                }
                imported.append(destination)
            } catch { print("Error copying tweak file: \(error)") }
        }
        return imported
    }
}
