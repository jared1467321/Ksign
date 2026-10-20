import Foundation

// Exercise production tweak orchestration and archive IO with a load-command
// recorder. The native suite separately verifies real batched Mach-O edits.
struct Options {
    enum InjectFolder: String { case root = "/", frameworks = "/Frameworks/" }
    enum InjectPath: String { case executable_path = "@executable_path", rpath = "@rpath" }
    var injectFolder: InjectFolder = .frameworks
    var injectPath: InjectPath = .executable_path
    var injectIntoExtensions = true
    var experiment_replaceSubstrateWithEllekit = false
}
final class OptionsManager { static let shared = OptionsManager(); var options = Options() }
enum Logger {
    struct Sink { func warning(_ text: String) {}; func info(_ text: String) {} }
    static let misc = Sink()
}
extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws { try createDirectory(at: url, withIntermediateDirectories: true) }
    func removeFileIfNeeded(at url: URL) throws { if fileExists(atPath: url.path) { try removeItem(at: url) } }
}
struct TweakBundle {
    let url: URL
    static var loaderDeb: URL?
    static var main: TweakBundle { TweakBundle(url: URL(fileURLWithPath: "/"))! }
    init?(url: URL) { self.url = url }
    func url(forResource resource: String, withExtension ext: String) -> URL? { Self.loaderDeb }
    var executableURL: URL? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String else { return nil }
        return url.appendingPathComponent(name)
    }
}
enum Zsign {
    struct Patch { let path: String; let rewrites: [String: String]; let injections: [String] }
    static var patches: [Patch] = []
    static func patchDylibs(appExecutable: String, rewrites: [String: String], injections: [String], weak: Bool = true) -> Bool {
        precondition(weak && FileManager.default.fileExists(atPath: appExecutable))
        patches.append(Patch(path: appExecutable, rewrites: rewrites, injections: injections))
        return true
    }
}
struct AR {
    struct Member { let name: String; let content: Data }
    static var contents: [String: [Member]] = [:]
    static var reads = 0
    let url: URL
    init(with url: URL) { self.url = url }
    func extract() async throws -> [Member] { Self.reads += 1; return Self.contents[url.path] ?? [] }
}
func extractDebPayload(_ data: Data, name: String, to directory: URL) throws {
    try FileManager.default.copyItem(at: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), to: directory)
}
func extractFile(at url: inout URL) throws {
    var directory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { return }
    url = URL(fileURLWithPath: String(decoding: try Data(contentsOf: url), as: UTF8.self))
}

@main struct TweakWorkspaceRegressions {
    static func check(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(condition, message, file: file, line: line) }
    static func write(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    static func framework(_ path: URL, executable: String, binary: Data) throws {
        try write(try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0),
                  to: path.appendingPathComponent("Info.plist"))
        try write(binary, to: path.appendingPathComponent(executable))
    }
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = URL(fileURLWithPath: CommandLine.arguments[2])
        let archive = try ArchiveBackedApp(archiveURL: source)
        let input = work.appendingPathComponent("tweak-input")
        let binary = try archive.data(relativePath: "Standalone.dylib")!
        let inputs = [input.appendingPathComponent("A.dylib"), input.appendingPathComponent("B.dylib"),
                      input.appendingPathComponent("F.framework"), input.appendingPathComponent("Replace.bundle"),
                      input.appendingPathComponent("tweaks.deb")]
        try write(binary, to: inputs[0]); try write(binary, to: inputs[1])
        try write(Data("deb fixture".utf8), to: inputs[4])
        try framework(inputs[2], executable: "F", binary: Data("must not replace the existing framework".utf8))
        try write(Data("replacement shared".utf8), to: inputs[3].appendingPathComponent("shared.txt"))
        try write(Data("new resource".utf8), to: inputs[3].appendingPathComponent("new.txt"))
        let debRoot = input.appendingPathComponent("deb-root")
        try write(binary, to: debRoot.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries/C.dylib"))
        try framework(debRoot.appendingPathComponent("Library/Frameworks/Deb.framework"), executable: "Deb", binary: binary)
        try write(Data("must not replace a bundle from a deb".utf8),
                  to: debRoot.appendingPathComponent("Library/Application Support/Replace.bundle/deb.txt"))
        try write(Data("deb resource".utf8), to: debRoot.appendingPathComponent("Library/Application Support/DebOnly.bundle/value.txt"))
        AR.contents[inputs[4].path] = [.init(name: "data.tar.gz", content: Data(debRoot.path.utf8))]
        var recordings: [[String: [String]]] = []
        let packages = TweakPackageCache()
        for sparse in [false, true] {
            let app = work.appendingPathComponent(sparse ? "tweak-handler-sparse.app" : "tweak-handler-full.app")
            if sparse {
                try ASignArchive.materializeSigningInputs(from: source, rootAppPath: archive.rootAppPath,
                    to: app, index: archive.archiveIndex, removedPaths: ["Replace.bundle"])
                check(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Replace.bundle/Old.dylib").path))
            } else { try archive.extractRootApp(to: app) }
            try FileManager.default.removeFileIfNeeded(at: app.appendingPathComponent("_CodeSignature"))
            try FileManager.default.removeFileIfNeeded(at: app.appendingPathComponent("embedded.mobileprovision"))
            let workspace = sparse ? ArchiveTweakWorkspace(archive: archive, appURL: app, excluded: ["_CodeSignature", "embedded.mobileprovision"]) : nil
            Zsign.patches = []
            var preparations: [(String, Bool)] = []
            var validationPaths: Set<String> = []
            let handler = TweakHandler(app: app, with: inputs, options: Options(), prepareDestination: { path, replacing in
                preparations.append((path, replacing))
                try workspace?.prepare(path, replacing: replacing)
            }, packages: packages, validateWorkspace: { paths in
                validationPaths.formUnion(paths.map { String($0.path.dropFirst(app.path.count + 1)) })
            })
            try await handler.getInputFiles()
            check(validationPaths == Set(preparations.map(\.0)), "Every copied or materialized tweak destination must be validated")
            check(Set(Zsign.patches.map(\.path)).count == Zsign.patches.count)
            let main = Zsign.patches.first { $0.path == app.appendingPathComponent("Main").resolvingSymlinksInPath().path }!
            check(main.injections.count == 5, "Three dylibs and two frameworks share one main-executable patch")
            let ext = Zsign.patches.first { $0.path.hasSuffix("PlugIns/E.appex/Ext") }!
            check(ext.injections.count == 3 && ext.injections.allSatisfy { $0.hasPrefix("@executable_path/../../Frameworks/") })
            check(preparations.contains { $0 == ("Replace.bundle", true) } && preparations.contains { $0 == ("Replace.bundle", false) })
            check(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Replace.bundle/old.txt").path))
            check(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Replace.bundle/deb.txt").path))
            check(try Data(contentsOf: app.appendingPathComponent("Replace.bundle/shared.txt")) == Data("replacement shared".utf8))
            check(try Data(contentsOf: app.appendingPathComponent("Frameworks/F.framework/F")) == archive.data(relativePath: "Frameworks/F.framework/F"))
            if sparse { check(!FileManager.default.fileExists(atPath: app.appendingPathComponent("root.dat").path)) }
            var patches: [String: [String]] = [:]
            for patch in Zsign.patches { patches[String(patch.path.dropFirst(app.resolvingSymlinksInPath().path.count))] = patch.injections.sorted() }
            recordings.append(patches)
            var deleted = workspace?.deletedPaths() ?? []
            if !sparse {
                deleted.formUnion(archive.paths().filter { path in
                    let destination = app.appendingPathComponent(path)
                    return !FileManager.default.fileExists(atPath: destination.path) &&
                        (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil
                })
            }
            deleted.insert("embedded.mobileprovision")
            try ASignArchive.rebuildWithOverlay(from: source,
                at: work.appendingPathComponent(sparse ? "tweak-handler-sparse.ipa" : "tweak-handler-full.ipa"),
                rootAppPath: archive.rootAppPath, overlayAppURL: app, deletedPaths: deleted, index: archive.archiveIndex)
        }
        check(recordings[0] == recordings[1])
        check(AR.reads == 1, "The same deb is decoded once per batch")
        let cached = try await packages.roots(for: inputs[4])
        check(AR.reads == 1)
        let original = try Data(contentsOf: cached[0].appendingPathComponent("Library/MobileSubstrate/DynamicLibraries/C.dylib"))
        check(original == binary, "Patching one app must not mutate a prepared package")
        try write(Data("changed deb fixture".utf8), to: inputs[4])
        _ = try await packages.roots(for: inputs[4])
        check(AR.reads == 2, "Changed packages are decoded again")
        // An ordinary signing operation does not materialize a loader merely to
        // decide that no tweaks were requested.
        var destinations = 0
        var validations = 0
        try await TweakHandler(app: work.appendingPathComponent("tweak-handler-sparse.app"), with: [],
            prepareDestination: { _, _ in destinations += 1 },
            validateWorkspace: { _ in validations += 1 }).getInputFiles()
        check(destinations == 0 && validations == 0)

        // Reject an imported framework that redirects an executable into a
        // different operation before the queued load-command edits run.
        let isolated = SigningWorkspace(root: work)
        try isolated.create()
        defer { try? isolated.clean() }
        let isolatedApp = isolated.directory.appendingPathComponent("Same.app")
        try framework(isolatedApp, executable: "Main", binary: binary)
        let foreign = work.appendingPathComponent("foreign-binary")
        try write(binary, to: foreign)
        let escapingFramework = input.appendingPathComponent("Escape.framework")
        try framework(escapingFramework, executable: "Escape", binary: binary)
        try FileManager.default.removeItem(at: escapingFramework.appendingPathComponent("Escape"))
        try FileManager.default.createSymbolicLink(at: escapingFramework.appendingPathComponent("Escape"), withDestinationURL: foreign)
        let patchCount = Zsign.patches.count
        try isolated.sanitize(isolatedApp)
        do {
            try await TweakHandler(app: isolatedApp, with: [escapingFramework],
                validateWorkspace: { try isolated.sanitizeAdditions($0) }).getInputFiles()
            preconditionFailure("An external framework executable must not be patched")
        } catch is SigningWorkspace.Failure {}
        check(Zsign.patches.count == patchCount, "No queued edits may run before workspace validation")
        check(try Data(contentsOf: foreign) == binary, "Foreign signing inputs must remain unchanged")
        print("Passed batched tweak orchestration, deb/framework/bundle destinations and sparse/full mutation equivalence.")
    }
}
