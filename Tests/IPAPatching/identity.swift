import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Failure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
func expectFailure(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw Failure(message: "Expected patch failure")
}

let manager = FileManager.default
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let plain = try Data(contentsOf: fixtures.appendingPathComponent("plain"))
let oldPatch = try Data(contentsOf: fixtures.appendingPathComponent("blatant-only"))
let libraries = [fixtures.appendingPathComponent("blatant"), fixtures.appendingPathComponent("identity")]
let key = IPAPatcher.originalIdentifierKey

func plist(_ url: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
}
func fixture(_ name: String, binary: Data? = nil, identifier: String = "com.example.original") throws -> URL {
    let app = fixtures.appendingPathComponent(name + ".app", isDirectory: true)
    try manager.createDirectory(at: app, withIntermediateDirectories: false)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Main"],
                                      format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    try (binary ?? plain).write(to: app.appendingPathComponent("Main"))
    return app
}
func apply(_ app: URL, original: String? = nil, replace: ((URL, URL) throws -> Void)? = nil) throws {
    try IPAPatcher.apply(to: app, library: libraries[0], identityLibrary: libraries[1],
                         originalRootIdentifier: original, replace: replace)
}

let app = try fixture("GeneralApp")
let ext = app.appendingPathComponent("PlugIns/Share.appex", isDirectory: true)
try manager.createDirectory(at: ext, withIntermediateDirectories: true)
try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.original.share", "CFBundleExecutable": "Share"],
                                  format: .xml, options: 0).write(to: ext.appendingPathComponent("Info.plist"))
try plain.write(to: ext.appendingPathComponent("Share"))
try apply(app)
try check(plist(app.appendingPathComponent("Info.plist"))[key] as? String == "com.example.original", "Missing original root ID")
try check(plist(ext.appendingPathComponent("Info.plist"))[key] as? String == "com.example.original.share", "Extension used root ID")
for bundle in [app, ext] {
    let info = try plist(bundle.appendingPathComponent("Info.plist"))
    let exe = bundle.appendingPathComponent(info["CFBundleExecutable"] as! String)
    let data = try Data(contentsOf: exe)
    try check(data.range(of: Data(IPAPatcher.libraryName.utf8)) != nil, "Missing Blatant injection")
    try check(data.range(of: Data(IPAPatcher.identityLibraryName.utf8)) != nil, "Missing identity injection")
    try check(data.range(of: Data("UNCHANGED_EXECUTABLE_CODE".utf8)) != nil, "Executable payload changed")
}
let before = try Data(contentsOf: app.appendingPathComponent("Main"))
var info = try plist(app.appendingPathComponent("Info.plist"))
info["CFBundleIdentifier"] = "com.example.renamed"
try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    .write(to: app.appendingPathComponent("Info.plist"))
try apply(app)
let afterInfo = try plist(app.appendingPathComponent("Info.plist"))
try check(afterInfo[key] as? String == "com.example.original", "Re-signing lost original ID")
try check(afterInfo["CFBundleIdentifier"] as? String == "com.example.renamed", "Changed signing ID")
try check(Data(contentsOf: app.appendingPathComponent("Main")) == before, "Duplicate injection on re-sign")

let onlyModify = try fixture("OnlyModify", identifier: "org.example.clone")
try apply(onlyModify, original: "org.example.original")
try check(plist(onlyModify.appendingPathComponent("Info.plist"))[key] as? String == "org.example.original", "Captured ID after onlyModify")

// An old Blatant-patched input still needs the new companion.
let upgrade = try fixture("Upgrade", binary: oldPatch)
let frameworks = upgrade.appendingPathComponent("Frameworks", isDirectory: true)
try manager.createDirectory(at: frameworks, withIntermediateDirectories: false)
let suppliedBlatant = Data("preserve third-party library".utf8)
try suppliedBlatant.write(to: frameworks.appendingPathComponent(IPAPatcher.libraryName))
try apply(upgrade)
try check(Data(contentsOf: frameworks.appendingPathComponent(IPAPatcher.libraryName)) == suppliedBlatant, "Replaced Blatant library")
try Data("old companion".utf8).write(to: frameworks.appendingPathComponent(IPAPatcher.identityLibraryName))
try apply(upgrade)
try check(Data(contentsOf: frameworks.appendingPathComponent(IPAPatcher.identityLibraryName)) == Data(contentsOf: libraries[1]),
          "Did not refresh our companion")

let rollback = try fixture("Rollback")
let originalPlist = try Data(contentsOf: rollback.appendingPathComponent("Info.plist"))
try expectFailure {
    try apply(rollback, replace: { source, destination in
        if destination.lastPathComponent == "Info.plist" { throw Failure(message: "Injected plist publication failure") }
        if rename(source.path, destination.path) != 0 { throw Failure(message: "rename failed") }
    })
}
try check(Data(contentsOf: rollback.appendingPathComponent("Main")) == plain, "Rollback left executable patched")
try check(Data(contentsOf: rollback.appendingPathComponent("Info.plist")) == originalPlist, "Rollback left identity metadata")
try check(!manager.fileExists(atPath: rollback.appendingPathComponent("Frameworks").path), "Rollback left libraries")
let missing = try fixture("MissingCompanion")
try expectFailure { try IPAPatcher.apply(to: missing, library: libraries[0], identityLibrary: nil) }
try check(Data(contentsOf: missing.appendingPathComponent("Main")) == plain, "Missing companion modified executable")
print("General original-identity staging, re-signing, extension and rollback tests passed")
