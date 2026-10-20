import Foundation

@main struct ArchiveMetadataRegressions {
    private static func check(_ condition: Bool) { precondition(condition) }

    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = try ArchiveBackedApp(archiveURL: source)
        let sparse = work.appendingPathComponent("swift-fused.app")
        let digests = try ASignArchive.materializeSigningInputs(from: source, rootAppPath: app.rootAppPath,
            to: sparse, hashResources: true)
        precondition(digests?.prefix(8) == Data("ASHSH001".utf8))
        precondition(!FileManager.default.fileExists(atPath: sparse.appendingPathComponent("root.dat").path))
        precondition(!app.supportsSparseTweakMutations, "Symlink aliases retain the broad tweak fallback")
        precondition(app.supportsSparseTweakMutations(at: ["Replace.bundle"]), "Unrelated file aliases do not require full extraction")
        precondition(!app.supportsSparseTweakMutations(at: ["Frameworks/V.framework"]), "An affected versioned framework retains the fallback")
        for label in ["unrelated", "case", "dot", "unicode-target", "link-ancestor", "link-target", "unrelated-case", "unrelated-dot", "unicode-normalization"] {
            let candidate = try ArchiveBackedApp(archiveURL: work.appendingPathComponent("mutation-\(label).ipa"))
            precondition(candidate.supportsSparseTweakMutations(at: ["Target.bundle"]) == (label == "unrelated"), label)
        }
        let tweakSource = URL(fileURLWithPath: CommandLine.arguments[3])
        let tweakApp = try ArchiveBackedApp(archiveURL: tweakSource)
        precondition(tweakApp.supportsSparseTweakMutations)
        let tweakOverlay = work.appendingPathComponent("tweak-overlay.app")
        try ASignArchive.materializeSigningInputs(from: tweakSource, rootAppPath: tweakApp.rootAppPath,
            to: tweakOverlay, index: tweakApp.archiveIndex)
        let excluded = "Frameworks/F.framework/resource-0.dat"
        let workspace = ArchiveTweakWorkspace(archive: tweakApp, appURL: tweakOverlay, excluded: [excluded])
        let changedExecutable = Data("already modified executable".utf8)
        try changedExecutable.write(to: tweakOverlay.appendingPathComponent("Frameworks/F.framework/F"))
        try workspace.prepare("Frameworks/F.framework", replacing: false)
        check(try Data(contentsOf: tweakOverlay.appendingPathComponent("Frameworks/F.framework/F")) == changedExecutable)
        precondition(FileManager.default.fileExists(atPath: tweakOverlay.appendingPathComponent("Frameworks/F.framework/resource-1.dat").path))
        precondition(!FileManager.default.fileExists(atPath: tweakOverlay.appendingPathComponent(excluded).path))
        try workspace.prepare("Replace.bundle", replacing: true)
        precondition(!FileManager.default.fileExists(atPath: tweakOverlay.appendingPathComponent("Replace.bundle/old.txt").path),
                     "Whole replacement must not extract obsolete resources")
        try FileManager.default.createDirectory(at: tweakOverlay.appendingPathComponent("Replace.bundle"), withIntermediateDirectories: true)
        try Data("replacement shared".utf8).write(to: tweakOverlay.appendingPathComponent("Replace.bundle/shared.txt"))
        try Data("new".utf8).write(to: tweakOverlay.appendingPathComponent("Replace.bundle/new.txt"))
        try workspace.prepare("Replace.bundle", replacing: false)
        precondition(!FileManager.default.fileExists(atPath: tweakOverlay.appendingPathComponent("Replace.bundle/old.txt").path),
                     "A later add-only request cannot restore replaced resources")
        precondition(workspace.deletedPaths().contains("Replace.bundle/old.txt"))
        precondition(!workspace.deletedPaths().contains("Replace.bundle/shared.txt"))
        precondition(!workspace.deletedPaths().contains("Replace.bundle.extra/untouched.txt"), "Subtree matching respects path boundaries")
        precondition(!FileManager.default.fileExists(atPath: tweakOverlay.appendingPathComponent("root.dat").path))
        let tweakOutput = work.appendingPathComponent("tweak-output.ipa")
        try ASignArchive.rebuildWithOverlay(from: tweakSource, at: tweakOutput, rootAppPath: tweakApp.rootAppPath,
            overlayAppURL: tweakOverlay, deletedPaths: workspace.deletedPaths().union([excluded]), index: tweakApp.archiveIndex)
        let rebuilt = try ArchiveBackedApp(archiveURL: tweakOutput)
        check(try rebuilt.data(relativePath: "Replace.bundle/old.txt") == nil)
        check(try rebuilt.data(relativePath: "Replace.bundle/shared.txt") == Data("replacement shared".utf8))
        check(try rebuilt.data(relativePath: "Replace.bundle.extra/untouched.txt") == Data("untouched".utf8))
        check(try rebuilt.data(relativePath: "root.dat") == Data("last duplicate wins".utf8))
        check(try rebuilt.data(relativePath: "Frameworks/F.framework/F") == changedExecutable)
        check(try rebuilt.data(relativePath: excluded) == nil)
        try Data("regenerated".utf8).write(to: tweakOverlay.appendingPathComponent("Replace.bundle/old.txt"))
        precondition(!workspace.deletedPaths().contains("Replace.bundle/old.txt"), "Refresh deletions after signing creates replacement files")
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
        try staleIndex.validate()
        let file = try FileHandle(forWritingTo: stale)
        try file.seekToEnd()
        try file.write(contentsOf: Data([0]))
        try file.close()
        do {
            try staleIndex.validate()
            preconditionFailure("A review handoff must reject a changed source before reusing cached metadata")
        } catch is ASignArchiveError { }
        do {
            _ = try ASignArchive.readEntry(from: stale, path: app.rootAppPath + "/Info.plist",
                                          maximumBytes: 1024 * 1024, index: staleIndex)
            preconditionFailure("An index must reject a changed source archive")
        } catch is ASignArchiveError { }
        print("Passed indexed Swift metadata, icon overlays/deletions, read limits and changed-source rejection.")
    }
}
