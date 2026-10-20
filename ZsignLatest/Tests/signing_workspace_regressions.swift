import Foundation

@main struct SigningWorkspaceRegressions {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("shared-input")
        try Data("original".utf8).write(to: source)
        let workspaces = (0..<8).map { _ in SigningWorkspace(root: root) }
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for (index, workspace) in workspaces.enumerated() {
                tasks.addTask {
                    try workspace.create()
                    let app = workspace.directory.appendingPathComponent("Same.app")
                    try manager.createDirectory(at: app, withIntermediateDirectories: true)
                    let file = app.appendingPathComponent("Same.dylib")
                    try manager.linkItem(at: source, to: file)
                    try manager.createSymbolicLink(atPath: app.appendingPathComponent("Alias").path,
                                                  withDestinationPath: "Same.dylib")
                    let framework = app.appendingPathComponent("Frameworks/F.framework")
                    let version = framework.appendingPathComponent("Versions/A")
                    try manager.createDirectory(at: version, withIntermediateDirectories: true)
                    try Data("framework".utf8).write(to: version.appendingPathComponent("F"))
                    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "F"], format: .xml, options: 0)
                        .write(to: version.appendingPathComponent("Info.plist"))
                    for (link, target) in [("Versions/Current", "A"), ("F", "Versions/Current/F"),
                                           ("Info.plist", "Versions/Current/Info.plist")] {
                        try manager.createSymbolicLink(atPath: framework.appendingPathComponent(link).path, withDestinationPath: target)
                    }
                    try workspace.sanitize(app)
                    // Truncating writes expose hard-link sharing, unlike atomic
                    // Data.write, which would replace the inode and mask it.
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: Data("job-\(index)".utf8))
                    try handle.close()
                    try workspace.sanitize(app)
                }
            }
            try await tasks.waitForAll()
        }
        let original = try Data(contentsOf: source)
        precondition(original == Data("original".utf8))
        for (index, workspace) in workspaces.enumerated() {
            let file = workspace.directory.appendingPathComponent("Same.app/Same.dylib")
            let contents = try Data(contentsOf: file)
            precondition(contents == Data("job-\(index)".utf8))
        }
        let first = workspaces[0], peer = workspaces[1]
        let app = first.directory.appendingPathComponent("Same.app")
        let escape = app.appendingPathComponent("Escape")
        try manager.createSymbolicLink(atPath: escape.path,
            withDestinationPath: peer.directory.appendingPathComponent("Same.app").path)
        do { try first.sanitize(app); preconditionFailure("Peer workspace link must be rejected") }
        catch is SigningWorkspace.Failure {}
        try manager.removeItem(at: escape)
        try manager.createSymbolicLink(atPath: escape.path, withDestinationPath: "../../outside")
        do { try first.sanitize(app); preconditionFailure("Relative escape must be rejected") }
        catch is SigningWorkspace.Failure {}
        try manager.removeItem(at: escape)
        let escapedExecutable = try PropertyListSerialization.data(fromPropertyList:
            ["CFBundleExecutable": peer.directory.appendingPathComponent("Same.app/Same.dylib").path], format: .xml, options: 0)
        try escapedExecutable.write(to: app.appendingPathComponent("Info.plist"))
        do { try first.sanitize(app); preconditionFailure("Executable metadata must not point into another workspace") }
        catch is SigningWorkspace.Failure {}
        do { try first.create(); preconditionFailure("Workspace reuse must be rejected") }
        catch is SigningWorkspace.Failure {}
        try first.clean()
        precondition(manager.fileExists(atPath: peer.directory.appendingPathComponent("Same.app/Same.dylib").path))
        for workspace in workspaces.dropFirst() { try workspace.clean() }
        let preserved = try Data(contentsOf: source)
        precondition(preserved == original)
        // macOS /var and /private/var spell the same temporary root. Check the
        // equivalent case on every platform without weakening escape checks.
        let physicalRoot = root.appendingPathComponent("physical")
        let aliasRoot = root.appendingPathComponent("alias")
        try manager.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: aliasRoot, withDestinationURL: physicalRoot)
        let aliased = SigningWorkspace(root: aliasRoot)
        try aliased.create()
        let aliasedApp = aliased.directory.appendingPathComponent("Same.app")
        try manager.createDirectory(at: aliasedApp, withIntermediateDirectories: true)
        try Data().write(to: aliasedApp.appendingPathComponent("Main"))
        try manager.createSymbolicLink(atPath: aliasedApp.appendingPathComponent("Alias").path, withDestinationPath: "Main")
        try aliased.sanitize(aliasedApp)
        let appAlias = aliased.directory.appendingPathComponent("AppAlias")
        try manager.createSymbolicLink(at: appAlias, withDestinationURL: aliasedApp)
        try aliased.sanitize(appAlias)
        try aliased.clean()
        // The initial tree is checked once. Later imports must be checked in
        // full without revisiting the hundreds of unchanged resource files.
        let incremental = SigningWorkspace(root: root)
        try incremental.create()
        defer { try? incremental.clean() }
        let incrementalApp = incremental.directory.appendingPathComponent("App.app")
        let resources = incrementalApp.appendingPathComponent("Resources")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0..<256 {
            try Data("resource".utf8).write(to: resources.appendingPathComponent("\(index).dat"))
        }
        var visited: [URL] = []
        incremental.didValidateFile = { visited.append($0) }
        try incremental.sanitize(incrementalApp)
        precondition(visited.count >= 258)
        visited.removeAll()
        let added = incrementalApp.appendingPathComponent("Added.dylib")
        try manager.linkItem(at: source, to: added)
        let bundle = incrementalApp.appendingPathComponent("Added.bundle")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info = bundle.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Main"], format: .xml, options: 0).write(to: info)
        try Data("imported".utf8).write(to: bundle.appendingPathComponent("Main"))
        try incremental.sanitizeAdditions([added, bundle, info, added])
        precondition(visited.count == 4, "Only the imported file and three bundle entries need validation")
        precondition(!visited.contains { $0.path.hasPrefix(resources.path) })
        let writer = try FileHandle(forWritingTo: added)
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("private import".utf8))
        try writer.close()
        let untouchedSource = try Data(contentsOf: source)
        precondition(untouchedSource == original, "An imported hard link must be separated before patching")
        visited.removeAll()
        try incremental.sanitizeAdditions([])
        try incremental.sanitizeAdditions([incrementalApp.appendingPathComponent("Removed.framework")])
        precondition(visited.isEmpty)

        let importedLink = incrementalApp.appendingPathComponent("Escape.dylib")
        try manager.createSymbolicLink(at: importedLink, withDestinationURL: source)
        do { try incremental.sanitizeAdditions([importedLink]); preconditionFailure("Imported external links must be rejected") }
        catch is SigningWorkspace.Failure {}
        try manager.removeItem(at: importedLink)
        try escapedExecutable.write(to: info)
        do { try incremental.sanitizeAdditions([bundle]); preconditionFailure("Imported executable metadata must remain inside this job") }
        catch is SigningWorkspace.Failure {}
        let bundleAlias = incrementalApp.appendingPathComponent("Alias.bundle")
        try manager.createSymbolicLink(at: bundleAlias, withDestinationURL: bundle)
        do { try incremental.sanitizeAdditions([bundleAlias]); preconditionFailure("An imported directory alias must not hide unsafe metadata") }
        catch is SigningWorkspace.Failure {}
        try manager.removeItem(at: info)
        try manager.createSymbolicLink(atPath: info.path, withDestinationPath: "Missing.plist")
        do { try incremental.sanitizeAdditions([bundle]); preconditionFailure("A missing imported Info.plist target must not hide a validation failure") }
        catch let error as CocoaError {
            precondition(error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile)
        }
        catch SigningWorkspace.Failure.escaped(let path) {
            // Darwin may leave /var unresolved for a dangling target and reject
            // the link during containment checks, before opening Info.plist.
            // Both outcomes must reject this nested input, never skip it as a
            // missing optional import root.
            precondition(URL(fileURLWithPath: path).lastPathComponent == "Info.plist")
        }
        print("Passed eight simultaneous private workspaces, identical filenames, hard-link separation, symlink escape rejection, source preservation and isolated cleanup.")
        print("Passed scoped import validation, hard-link separation, executable/link escape rejection and zero rescans of unchanged resources.")
    }
}
