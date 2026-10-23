import Foundation

enum SigningPreflight {
    struct Source {
        let name: String
        let recordedIdentifier: String?
        let customIdentifier: String?
        let archiveURL: URL?
        let appDirectory: URL?
    }
    struct Candidate {
        let name: String
        let bundleIdentifier: String?
        let info: [String: Any]?
        var archiveApp: ArchiveBackedApp? = nil
    }
    struct Issue {
        let name: String
        let reason: String
        var description: String { "\(name): \(reason)" }
    }
    struct Report {
        var eligibleIndices: [Int] = []
        var skipped: [Issue] = []
        var installed: [Issue] = []
        var archiveApps: [Int: ArchiveBackedApp] = [:]
    }

    static func candidate(_ source: Source) -> Candidate {
        let archiveApp = source.archiveURL.flatMap { try? ArchiveBackedApp(archiveURL: $0) }
        let info = source.archiveURL != nil && archiveApp == nil ? nil : readInfo(source, archiveApp: archiveApp)
        let custom = source.customIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        return Candidate(name: source.name,
            bundleIdentifier: custom ?? (info?["CFBundleIdentifier"] as? String) ?? source.recordedIdentifier,
            info: info, archiveApp: archiveApp)
    }

    static func readInfo(_ source: Source, archiveApp: ArchiveBackedApp? = nil) -> [String: Any]? {
        let data: Data?
        if let archiveURL = source.archiveURL {
            data = try? (archiveApp ?? ArchiveBackedApp(archiveURL: archiveURL))
                .data(relativePath: "Info.plist", maximumBytes: 16 * 1024 * 1024)
        } else if let directory = source.appDirectory,
                  let file = try? FileHandle(forReadingFrom: directory.appendingPathComponent("Info.plist")) {
            defer { try? file.close() }
            data = try? file.read(upToCount: 16 * 1024 * 1024)
        } else { data = nil }
        guard let data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func evaluate(_ candidates: [Candidate], isInstalled: (String) -> Bool) -> Report {
        var report = Report()
        var installedIDs = Set<String>()
        for (index, candidate) in candidates.enumerated() {
            // Foreign platforms now get one automatic compatibility attempt in
            // SigningHandler's private workspace, before the bundle is signed.
            report.eligibleIndices.append(index)
            report.archiveApps[index] = candidate.archiveApp
            if let id = candidate.bundleIdentifier, !id.isEmpty,
               installedIDs.insert(id).inserted, isInstalled(id) {
                report.installed.append(Issue(name: candidate.name, reason: id))
            }
        }
        return report
    }
}
