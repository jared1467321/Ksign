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
let patchLibrary = fixtures.appendingPathComponent("patch")
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
@discardableResult
func apply(_ app: URL, original: String? = nil, replace: ((URL, URL) throws -> Void)? = nil) throws -> [String: [String]] {
    try IPAPatcher.apply(to: app, library: patchLibrary,
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
    try check(data.range(of: Data(IPAPatcher.libraryName.utf8)) != nil, "Missing unified injection")
    try check(!IPAPatcher.legacyLibraryNames.contains { data.range(of: Data($0.utf8)) != nil }, "Legacy load survived")
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
try check(plist(onlyModify.appendingPathComponent("Info.plist"))["CFBundleIdentifier"] as? String == "org.example.clone", "onlyModify signing ID changed")
let withoutDirectorySlash = try fixture("OnlyModifyWithoutDirectorySlash", identifier: "org.example.second.clone")
try apply(URL(fileURLWithPath: withoutDirectorySlash.path, isDirectory: false), original: "org.example.second.original")
try check(plist(withoutDirectorySlash.appendingPathComponent("Info.plist"))[key] as? String == "org.example.second.original",
          "Root identity depends on URL trailing slash")

// Upgrade the old pair, including extension-local copies, to one library.
let upgrade = try fixture("Upgrade", binary: try Data(contentsOf: fixtures.appendingPathComponent("legacy-pair")))
let frameworks = upgrade.appendingPathComponent("Frameworks", isDirectory: true)
try manager.createDirectory(at: frameworks, withIntermediateDirectories: false)
for name in IPAPatcher.legacyLibraryNames {
    try Data("legacy patch".utf8).write(to: frameworks.appendingPathComponent(name))
}
var removed: [String] = []
try IPAPatcher.apply(to: upgrade, library: patchLibrary, didRemoveLibrary: { removed.append($0) })
try check(Set(try manager.contentsOfDirectory(atPath: frameworks.path)) == [IPAPatcher.libraryName], "Upgrade left multiple libraries")
try check(Set(removed) == Set(IPAPatcher.legacyLibraryNames.map { "Frameworks/" + $0 }), "Missing archive deletion journal")
try Data("old unified patch".utf8).write(to: frameworks.appendingPathComponent(IPAPatcher.libraryName))
try apply(upgrade)
try check(Data(contentsOf: frameworks.appendingPathComponent(IPAPatcher.libraryName)) == Data(contentsOf: patchLibrary),
          "Did not refresh unified patch")
let refreshed = try Data(contentsOf: upgrade.appendingPathComponent("Main"))
try apply(upgrade)
try check(Data(contentsOf: upgrade.appendingPathComponent("Main")) == refreshed, "Re-signing grew migrated load commands")
let oldSingle = try fixture("OldSingle", binary: oldPatch)
try apply(oldSingle)
try check(Data(contentsOf: oldSingle.appendingPathComponent("Main")).range(of: Data("blatantsPatch.dylib".utf8)) == nil,
          "Old single patch load survived")
let extensionUpgrade = try fixture("ExtensionUpgrade")
let legacyExtension = extensionUpgrade.appendingPathComponent("PlugIns/Share.appex", isDirectory: true)
try manager.createDirectory(at: legacyExtension, withIntermediateDirectories: true)
try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.share", "CFBundleExecutable": "Share"],
                                  format: .xml, options: 0).write(to: legacyExtension.appendingPathComponent("Info.plist"))
try oldPatch.write(to: legacyExtension.appendingPathComponent("Share"))
let extensionFrameworks = legacyExtension.appendingPathComponent("Frameworks", isDirectory: true)
try manager.createDirectory(at: extensionFrameworks, withIntermediateDirectories: false)
try Data("legacy".utf8).write(to: extensionFrameworks.appendingPathComponent("blatantsPatch.dylib"))
try apply(extensionUpgrade)
try check(try manager.contentsOfDirectory(atPath: extensionFrameworks.path).isEmpty, "Extension kept old patch")

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
let missing = try fixture("MissingPatch")
try expectFailure { try IPAPatcher.apply(to: missing, library: nil) }
try check(Data(contentsOf: missing.appendingPathComponent("Main")) == plain, "Missing patch modified executable")
let failedUpgrade = try fixture("FailedUpgrade", binary: try Data(contentsOf: fixtures.appendingPathComponent("legacy-pair")))
let failedFrameworks = failedUpgrade.appendingPathComponent("Frameworks", isDirectory: true)
try manager.createDirectory(at: failedFrameworks, withIntermediateDirectories: false)
for name in IPAPatcher.legacyLibraryNames { try Data("old".utf8).write(to: failedFrameworks.appendingPathComponent(name)) }
var failedRemovals: [String] = []
try expectFailure {
    try IPAPatcher.apply(to: failedUpgrade, library: patchLibrary, didRemoveLibrary: { failedRemovals.append($0) },
        replace: { source, destination in
            if destination.lastPathComponent == "Info.plist" { throw Failure(message: "Upgrade publication failed") }
            if rename(source.path, destination.path) != 0 { throw Failure(message: "rename failed") }
        })
}
try check(failedRemovals.isEmpty, "Failed migration published deletions")
try check(Set(try manager.contentsOfDirectory(atPath: failedFrameworks.path)) == Set(IPAPatcher.legacyLibraryNames),
          "Failed migration changed legacy files")
try check(Data(contentsOf: failedUpgrade.appendingPathComponent("Main")) == Data(contentsOf: fixtures.appendingPathComponent("legacy-pair")),
          "Failed migration changed executable")
print("General original-identity staging, re-signing, extension and rollback tests passed")

let cloudKey = IPAPatcher.originalCloudEntitlementKeys
let cloudKeys = ["com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services"]
for (file, expected) in [("cloud-local", [String]()), ("cloud-enabled", cloudKeys),
                         ("cloud-kvs", ["com.apple.developer.ubiquity-kvstore-identifier"]),
                         ("cloud-fat", []), ("cloud-big-endian", [])] {
    try check(OriginalCloudEntitlements.read(fixtures.appendingPathComponent(file)) == expected,
              "Wrong original cloud capability snapshot: \(file)")
}
for file in ["plain", "cloud-fat-disagreement", "cloud-truncated", "cloud-der-only"] {
    try check(OriginalCloudEntitlements.read(fixtures.appendingPathComponent(file)) == nil,
              "Inconclusive signature acquired a cloud policy: \(file)")
}
let localBytes = try Data(contentsOf: fixtures.appendingPathComponent("cloud-local"))
let cloudBytes = try Data(contentsOf: fixtures.appendingPathComponent("cloud-enabled"))
let local = try fixture("LocalDatabase", binary: localBytes)
let cloudExtension = local.appendingPathComponent("PlugIns/Cloud.appex", isDirectory: true)
try manager.createDirectory(at: cloudExtension, withIntermediateDirectories: true)
try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.cloud.extension", "CFBundleExecutable": "Cloud"],
                                  format: .xml, options: 0).write(to: cloudExtension.appendingPathComponent("Info.plist"))
try cloudBytes.write(to: cloudExtension.appendingPathComponent("Cloud"))
let policy = try apply(local)
try check(policy["Main"] == [], "Local app did not suppress added cloud capabilities")
try check(policy["PlugIns/Cloud.appex/Cloud"] == cloudKeys, "Root policy leaked into CloudKit extension")
try check(plist(local.appendingPathComponent("Info.plist"))[cloudKey] as? [String] == [], "Missing local snapshot")
try check(plist(cloudExtension.appendingPathComponent("Info.plist"))[cloudKey] as? [String] == cloudKeys, "Missing CloudKit snapshot")
// Simulate re-signing with a profile that added iCloud to a local executable.
try cloudBytes.write(to: local.appendingPathComponent("Main"))
try check(apply(local)["Main"] == [], "Re-signing forgot that the original app was local-only")
let cloudApp = try fixture("CloudDatabase", binary: cloudBytes)
try check(apply(cloudApp)["Main"] == cloudKeys, "Legitimate CloudKit app lost its capabilities")
let containersKey = IPAPatcher.originalCloudContainerIdentifiers
try check(OriginalCloudEntitlements.snapshot(fixtures.appendingPathComponent("cloud-multiple"))?.containers ==
          ["iCloud.org.example.z", "iCloud.org.example.a"], "Original default container order changed")
try check(plist(cloudApp.appendingPathComponent("Info.plist"))[containersKey] as? [String] == ["iCloud.org.example.app"],
          "Original cloud container was not captured")
try check(plist(local.appendingPathComponent("Info.plist"))[containersKey] as? [String] == [],
          "Re-signing invented an original cloud container for a local app")
try check(plist(cloudExtension.appendingPathComponent("Info.plist"))[containersKey] as? [String] == ["iCloud.org.example.app"],
          "Extension cloud container snapshot was not independent")
// An old snapshot without original container values cannot recover those values
// from a subsequently re-signed executable. Do not claim the new profile's ID.
var historical = try plist(cloudApp.appendingPathComponent("Info.plist"))
historical.removeValue(forKey: containersKey)
try PropertyListSerialization.data(fromPropertyList: historical, format: .binary, options: 0)
    .write(to: cloudApp.appendingPathComponent("Info.plist"))
try apply(cloudApp)
try check(plist(cloudApp.appendingPathComponent("Info.plist"))[containersKey] == nil, "Historical cloud snapshot invented an original ID")

let cloudRollback = try fixture("CloudRollback", binary: localBytes)
let rollbackPlist = try Data(contentsOf: cloudRollback.appendingPathComponent("Info.plist"))
try expectFailure {
    try apply(cloudRollback, replace: { source, destination in
        if destination.lastPathComponent == "Info.plist" { throw Failure(message: "Cloud snapshot publication failed") }
        if rename(source.path, destination.path) != 0 { throw Failure(message: "rename failed") }
    })
}
try check(Data(contentsOf: cloudRollback.appendingPathComponent("Main")) == localBytes, "Cloud rollback changed executable")
try check(Data(contentsOf: cloudRollback.appendingPathComponent("Info.plist")) == rollbackPlist, "Cloud rollback left metadata")
print("Original cloud capability capture, per-extension policy and rollback tests passed")
