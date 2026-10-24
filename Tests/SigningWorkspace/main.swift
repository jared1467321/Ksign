import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The workspace's snapshot type only needs this storage-model interface.
protocol AppInfoPresentable {
    var name: String? { get }
    var version: String? { get }
    var identifier: String? { get }
    var date: Date? { get }
    var icon: String? { get }
    var uuid: String? { get }
    var isSigned: Bool { get }
}

let manager = FileManager.default
let temporary = realpath(manager.temporaryDirectory.path, nil)!
// On Darwin this deliberately retains /private, reproducing the differing
// Foundation normalization of existing directories and missing executables.
let scratch = URL(fileURLWithPath: String(cString: temporary))
    .appendingPathComponent("SigningWorkspaceTests_" + UUID().uuidString, isDirectory: true)
free(temporary)
try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: scratch) }

var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
    let result = try value()
    precondition(result, message)
    checks += 1
}

func rejects(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("Expected rejection: \(message)")
    } catch {
        checks += 1
    }
}

func makeBundle(_ bundle: URL, executable: String, placeholder: Bool = false, binary: Bool = false) throws {
    try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleExecutable": executable]
    if placeholder { info["CF_MIPlaceholderConstructorVersion"] = "25D126" }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    try data.write(to: bundle.appendingPathComponent("Info.plist"))
    if binary { try Data("original executable bytes".utf8).write(to: bundle.appendingPathComponent(executable)) }
}

func withWorkspace(aliased: Bool = false, _ operation: (SigningWorkspace, URL) throws -> Void) throws {
    let alias = scratch.appendingPathComponent("Alias_" + UUID().uuidString)
    if aliased { try manager.createSymbolicLink(at: alias, withDestinationURL: scratch) }
    defer { if aliased { try? manager.removeItem(at: alias) } }
    let workspace = SigningWorkspace(root: aliased ? alias : scratch)
    try workspace.create()
    defer { try? workspace.clean() }
    let app = workspace.directory.appendingPathComponent("Widgy.app", isDirectory: true)
    try makeBundle(app, executable: "Widgy", binary: true)
    try operation(workspace, app)
}

func contents(_ root: URL) throws -> [String: Data] {
    let path = realpath(root.path, nil)!
    let physicalRoot = URL(fileURLWithPath: String(cString: path), isDirectory: true)
    free(path)
    var result: [String: Data] = [:]
    let enumerator = manager.enumerator(at: physicalRoot, includingPropertiesForKeys: nil)!
    for case let file as URL in enumerator {
        let type = try manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        if type == .typeRegular { result[String(file.path.dropFirst(physicalRoot.path.count + 1))] = try Data(contentsOf: file) }
    }
    return result
}

for aliased in [false, true] {
    FileHandle.standardError.write(Data("Testing Watch placeholders through \(aliased ? "aliased" : "physical") workspace root\n".utf8))
    try withWorkspace(aliased: aliased) { workspace, app in
        try makeBundle(app.appendingPathComponent("PlugIns/Home WidgetExtension.appex"),
                       executable: "Home WidgetExtension", binary: true)
        let watch = app.appendingPathComponent("com.apple.WatchPlaceholder/Watchy.app")
        let complication = watch.appendingPathComponent("PlugIns/WatchyComplicationsExtension.appex")
        try makeBundle(watch, executable: "Executable", placeholder: true)
        try makeBundle(complication, executable: "Executable", placeholder: true)
        let before = try contents(app)
        try workspace.sanitize(app)
        try check(contents(app) == before, "Preserve all binaries and Watch placeholder metadata")
        let physical = realpath(app.path, nil)!
        let physicalApp = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        // Darwin enumeration can produce physical paths while Foundation
        // standardization strips /private, independently of the root's alias.
        try workspace.sanitize(physicalApp.standardizedFileURL)
        try workspace.sanitizeAdditions([physicalApp.appendingPathComponent("com.apple.WatchPlaceholder/Watchy.app").standardizedFileURL])
        checks += 2
        check(!manager.fileExists(atPath: watch.appendingPathComponent("Executable").path), "Do not invent a Watch binary")
        check(!manager.fileExists(atPath: complication.appendingPathComponent("Executable").path), "Do not invent a complication binary")
        try workspace.sanitizeAdditions([app.appendingPathComponent("Frameworks/not-created/Library.dylib")])
        checks += 1
    }
}

let outside = scratch.appendingPathComponent("Outside", isDirectory: true)
try manager.createDirectory(at: outside, withIntermediateDirectories: false)
let sentinel = outside.appendingPathComponent("Executable")
let sentinelBytes = Data("external file must stay untouched".utf8)
try sentinelBytes.write(to: sentinel)

for target in [sentinel.path, outside.appendingPathComponent("Missing").path] {
    try withWorkspace { workspace, app in
        try makeBundle(app, executable: target)
        rejects("absolute external executable, existing or absent") { try workspace.sanitize(app) }
    }
}

try withWorkspace { workspace, app in
    try makeBundle(app, executable: "../../Outside/Executable")
    rejects("relative executable traversal") { try workspace.sanitize(app) }
}

try withWorkspace { workspace, app in
    let sibling = URL(fileURLWithPath: workspace.directory.path + "-other/Executable")
    try makeBundle(app, executable: sibling.path)
    rejects("a matching string prefix is not workspace containment") { try workspace.sanitize(app) }
}

for destination in [sentinel, outside.appendingPathComponent("Missing")] {
    try withWorkspace { workspace, app in
        try manager.createSymbolicLink(at: app.appendingPathComponent("Alias"), withDestinationURL: destination)
        try makeBundle(app, executable: "Alias")
        rejects("external executable link, including a dangling link") { try workspace.sanitize(app) }
    }
}

try withWorkspace { workspace, app in
    let alias = app.appendingPathComponent("External")
    try manager.createSymbolicLink(at: alias, withDestinationURL: outside)
    try makeBundle(app, executable: "External/Absent/Executable")
    rejects("a missing executable beneath an external directory alias") { try workspace.sanitize(app) }
    rejects("a missing addition beneath an external alias") {
        try workspace.sanitizeAdditions([alias.appendingPathComponent("Absent/Library.dylib")])
    }
}

try withWorkspace { workspace, app in
    let first = app.appendingPathComponent("First")
    let second = app.appendingPathComponent("Second")
    try manager.createSymbolicLink(at: first, withDestinationURL: second)
    try manager.createSymbolicLink(at: second, withDestinationURL: outside.appendingPathComponent("Missing"))
    try makeBundle(app, executable: "First/Executable")
    rejects("a chain of dangling links cannot hide an external target") { try workspace.sanitize(app) }
}

try withWorkspace { workspace, app in
    try manager.createSymbolicLink(atPath: app.appendingPathComponent("Here").path, withDestinationPath: ".")
    try makeBundle(app, executable: "Here/../../Outside/Executable")
    rejects("resolve links before processing parent traversal") { try workspace.sanitize(app) }
}

try withWorkspace { workspace, app in
    try manager.createSymbolicLink(atPath: app.appendingPathComponent("Cycle").path, withDestinationPath: "Cycle")
    try makeBundle(app, executable: "Cycle/Executable")
    rejects("link cycles fail without hanging") { try workspace.sanitize(app) }
}

try withWorkspace { workspace, app in
    let link = app.appendingPathComponent("Future")
    try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "not-created/Executable")
    try makeBundle(app, executable: "Future")
    try workspace.sanitize(app)
    try check(manager.destinationOfSymbolicLink(atPath: link.path) == "not-created/Executable", "Preserve safe dangling internal links")
}

try withWorkspace { workspace, app in
    let framework = app.appendingPathComponent("Frameworks/Example.framework")
    let version = framework.appendingPathComponent("Versions/A")
    try makeBundle(version, executable: "Example", binary: true)
    try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Example").path, withDestinationPath: "Versions/Current/Example")
    try makeBundle(framework, executable: "Example")
    try workspace.sanitize(app)
    try workspace.sanitizeAdditions([framework.appendingPathComponent("Versions/Current")])
    try check(manager.destinationOfSymbolicLink(atPath: framework.appendingPathComponent("Example").path) == "Versions/Current/Example",
              "Preserve versioned framework aliases")
}

try withWorkspace { workspace, app in
    rejects("missing additions outside the workspace") {
        try workspace.sanitizeAdditions([outside.appendingPathComponent("Missing")])
    }
}

if CommandLine.arguments.count > 1 {
    let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try withWorkspace { workspace, app in
        try manager.removeItem(at: app)
        try manager.copyItem(at: source, to: app)
        let before = try contents(app)
        try workspace.sanitize(app)
        try check(contents(app) == before, "The uploaded IPA's signing inputs remain byte-for-byte unchanged")
        print("Uploaded IPA: workspace validation passed with Watch placeholders preserved")
    }
}

try check(Data(contentsOf: sentinel) == sentinelBytes, "External files remain untouched")
print("Signing workspace: \(checks) checks passed")
