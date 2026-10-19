import Foundation

@main struct ArchiveMetadataRegressions {
    private static func check(_ condition: Bool) { precondition(condition) }

    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = try ArchiveBackedApp(archiveURL: source)
        let info = try app.data(relativePath: "Info.plist")!
        check(try app.data(relativePath: "Info.plist") == info)
        do {
            _ = try app.data(relativePath: "Info.plist", maximumBytes: 1)
            preconditionFailure("Cached metadata must still respect the read limit")
        } catch ArchiveBackedAppError.infoPlistTooLarge { }

        let overlay = work.appendingPathComponent("metadata-overlay.app")
        let cache = work.appendingPathComponent("metadata-cache")
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        var plist = try PropertyListSerialization.propertyList(from: info, options: [], format: nil) as! [String: Any]
        plist["CFBundleDisplayName"] = "Updated Name"
        plist["CFBundleIdentifier"] = "updated.identifier"
        plist["CFBundleShortVersionString"] = "2.0"
        plist["CFBundleIconFiles"] = ["Replacement"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: overlay.appendingPathComponent("Info.plist"))
        let icon = Data("replacement icon".utf8)
        try icon.write(to: overlay.appendingPathComponent("Replacement@3x.png"))
        let metadata = try app.metadata(overlayAppURL: overlay)
        precondition(metadata.name == "Updated Name" && metadata.identifier == "updated.identifier" && metadata.version == "2.0")
        precondition(metadata.iconArchivePath == app.rootAppPath + "/Replacement@3x.png")
        let name = try app.cachePrimaryIcon(in: cache, overlayAppURL: overlay, metadata: metadata)!
        check(try Data(contentsOf: cache.appendingPathComponent(name)) == icon)
        check(try app.metadata(overlayAppURL: overlay, deletedPaths: ["Replacement@3x.png"]).iconArchivePath == nil)

        // Icons that remain archive-backed use the same index, including final
        // duplicate selection. New output metadata never requires scanning an IPA.
        plist["CFBundleIconFiles"] = ["OriginalIcon"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: overlay.appendingPathComponent("Info.plist"))
        let original = try app.metadata(overlayAppURL: overlay)
        let originalName = try app.cachePrimaryIcon(in: cache, overlayAppURL: overlay, metadata: original)!
        check(try Data(contentsOf: cache.appendingPathComponent(originalName)) == Data("original icon".utf8))
        check(try app.metadata(overlayAppURL: overlay, deletedPaths: ["OriginalIcon@3x.png"]).iconArchivePath == nil)

        plist["CFBundleIconFiles"] = ["../outside.png"]
        try Data("outside".utf8).write(to: work.appendingPathComponent("outside.png"))
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: overlay.appendingPathComponent("Info.plist"))
        check(try app.metadata(overlayAppURL: overlay).iconArchivePath == nil)

        let stale = work.appendingPathComponent("stale.ipa")
        try FileManager.default.copyItem(at: source, to: stale)
        let staleIndex = try ASignArchiveIndex(archiveURL: stale)
        let file = try FileHandle(forWritingTo: stale)
        try file.seekToEnd()
        try file.write(contentsOf: Data([0]))
        try file.close()
        do {
            _ = try ASignArchive.readEntry(from: stale, path: app.rootAppPath + "/Info.plist",
                                          maximumBytes: 1024 * 1024, index: staleIndex)
            preconditionFailure("An index must reject a changed source archive")
        } catch is ASignArchiveError { }
        print("Passed indexed Swift metadata, icon overlays/deletions, read limits and changed-source rejection.")
    }
}
