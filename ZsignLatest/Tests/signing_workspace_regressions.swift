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
        try aliased.clean()
        print("Passed eight simultaneous private workspaces, identical filenames, hard-link separation, symlink escape rejection, source preservation and isolated cleanup.")
    }
}
