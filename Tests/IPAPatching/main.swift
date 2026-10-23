import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let manager = FileManager.default
let scratch = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("IPAPatchTests_" + UUID().uuidString)
try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: scratch) }
let library = URL(fileURLWithPath: CommandLine.arguments[1])

func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
}

func executable(encrypted: Bool = false) -> Data {
    // A real segment/section layout, with enough header padding for injection.
    var data = Data(repeating: 0, count: 1024)
    let words: [(Int, UInt32)] = [(0, 0xfeedfacf), (4, 0x100000c), (12, 2),
        (16, encrypted ? 2 : 1), (20, encrypted ? 176 : 152),
        (32, 0x19), (36, 152), (64, 1024), (80, 1024), (96, 1),
        (144, 64), (152, 512)]
    for (offset, value) in words { put32(&data, offset, value) }
    data.replaceSubrange(40..<46, with: Data("__TEXT".utf8))
    data.replaceSubrange(104..<110, with: Data("__text".utf8))
    data.replaceSubrange(512..<576, with: Data(repeating: 0x41, count: 64))
    if encrypted {
        put32(&data, 184, 0x2c); put32(&data, 188, 24); put32(&data, 200, 1)
    }
    return data
}

func executable(runpaths: [String], padding: Int) -> Data {
    var data = executable()
    data.replaceSubrange(512..<576, with: Data(repeating: 0, count: 64))
    var cursor = 184
    for path in runpaths {
        let bytes = Data(path.utf8)
        let length = (12 + bytes.count + 1 + 7) & ~7
        put32(&data, cursor, 0x8000001c)
        put32(&data, cursor + 4, UInt32(length))
        put32(&data, cursor + 8, 12)
        data.replaceSubrange((cursor + 12)..<(cursor + 12 + bytes.count), with: bytes)
        cursor += length
    }
    put32(&data, 16, UInt32(1 + runpaths.count))
    put32(&data, 20, UInt32(cursor - 32))
    let codeOffset = cursor + padding
    put32(&data, 152, UInt32(codeOffset))
    data.replaceSubrange(codeOffset..<(codeOffset + 64), with: Data(repeating: 0x41, count: 64))
    return data
}

func makeBundle(_ url: URL, name: String = "Executable", bytes: Data? = nil) throws {
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": name], format: .binary, options: 0)
    try plist.write(to: url.appendingPathComponent("Info.plist"))
    try (bytes ?? executable()).write(to: url.appendingPathComponent(name))
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(name).path)
}

func checkThrows(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Expected patch failure") }
    catch { precondition(!error.localizedDescription.isEmpty) }
}

func check(_ condition: @autoclosure () throws -> Bool) rethrows {
    let value = try condition()
    precondition(value)
}

let app = scratch.appendingPathComponent("Main.app")
try makeBundle(app, name: "Host")
let share = app.appendingPathComponent("PlugIns/Share.appex")
let widget = app.appendingPathComponent("Extensions/Widget.appex")
let nested = app.appendingPathComponent("Resources/Helper.app")
let deep = nested.appendingPathComponent("PlugIns/Deep.appex")
for bundle in [share, widget, nested, deep] { try makeBundle(bundle) }
for folder in ["Watch", "WatchKit", "com.apple.WatchPlaceholder"] {
    let ignored = app.appendingPathComponent(folder + "/Watch.app/PlugIns/Watch.appex")
    try makeBundle(ignored, bytes: Data("not executable".utf8))
}
let framework = app.appendingPathComponent("Frameworks/NotAnApp.framework")
try manager.createDirectory(at: framework, withIntermediateDirectories: true)
try Data("not a plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
let targets = try IPAPatcher.targets(in: app)
precondition(targets.count == 5)
let paths = Dictionary(uniqueKeysWithValues: targets.map { ($0.executable.path, $0.loadPath) })
precondition(paths[app.appendingPathComponent("Host").path] == "@executable_path/Frameworks/blatantsPatch.dylib")
precondition(paths[share.appendingPathComponent("Executable").path] == "@executable_path/../../Frameworks/blatantsPatch.dylib")
precondition(paths[deep.appendingPathComponent("Executable").path] == "@executable_path/../../../../Frameworks/blatantsPatch.dylib")

try IPAPatcher.apply(to: app, library: library)
let installedLibrary = app.appendingPathComponent(IPAPatcher.libraryRelativePath)
try check(try Data(contentsOf: installedLibrary) == Data(contentsOf: library))
let firstPass = try targets.map { try Data(contentsOf: $0.executable) }
for (target, bytes) in zip(targets, firstPass) {
    precondition(bytes.range(of: Data(target.loadPath.utf8)) != nil)
    let mode = try manager.attributesOfItem(atPath: target.executable.path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o755)
}
try IPAPatcher.apply(to: app, library: library)
try check(try targets.map { try Data(contentsOf: $0.executable) } == firstPass)

// Reproduce tight extension headers: 64 bytes of padding fits IPAPatch's
// 56-byte @rpath command but not the old 80-byte executable-relative command.
let compactApp = scratch.appendingPathComponent("Compact.app")
try makeBundle(compactApp)
let sticker = compactApp.appendingPathComponent("PlugIns/Stickers.appex")
let searchPaths = ["@loader_path/Frameworks", "@executable_path/../../Frameworks"]
try makeBundle(sticker, bytes: executable(runpaths: searchPaths, padding: 64))
try IPAPatcher.apply(to: compactApp, library: library)
let stickerExecutable = sticker.appendingPathComponent("Executable")
let compactResult = try Data(contentsOf: stickerExecutable)
precondition(compactResult.range(of: Data("@rpath/blatantsPatch.dylib".utf8)) != nil)
try IPAPatcher.apply(to: compactApp, library: library)
try check(try Data(contentsOf: stickerExecutable) == compactResult)

// A local copy in an earlier runpath must not shadow the bundled patch.
// The explicit fallback still works when the extension has sufficient room.
let shadowApp = scratch.appendingPathComponent("Shadow.app")
try makeBundle(shadowApp)
let shadowExtension = shadowApp.appendingPathComponent("PlugIns/Stickers.appex")
try makeBundle(shadowExtension, bytes: executable(runpaths: searchPaths, padding: 96))
let localFrameworks = shadowExtension.appendingPathComponent("Frameworks")
try manager.createDirectory(at: localFrameworks, withIntermediateDirectories: false)
try Data("different local library".utf8).write(to: localFrameworks.appendingPathComponent(IPAPatcher.libraryName))
try IPAPatcher.apply(to: shadowApp, library: library)
let shadowResult = try Data(contentsOf: shadowExtension.appendingPathComponent("Executable"))
precondition(shadowResult.range(of: Data("@executable_path/../../Frameworks/blatantsPatch.dylib".utf8)) != nil)
precondition(shadowResult.range(of: Data("@rpath/blatantsPatch.dylib".utf8)) == nil)

// Growth is automatic within the same transaction and remains silent.
let growthApp = scratch.appendingPathComponent("Growth.app")
try makeBundle(growthApp)
let growthExtension = growthApp.appendingPathComponent("PlugIns/Stickers.appex")
let growthInput = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
try makeBundle(growthExtension, bytes: growthInput)
try IPAPatcher.apply(to: growthApp, library: library)
let grown = try Data(contentsOf: growthExtension.appendingPathComponent("Executable"))
precondition(grown.count >= growthInput.count + 0x4000)
precondition(grown.range(of: Data("@executable_path/../../Frameworks/blatantsPatch.dylib".utf8)) != nil)

// A failing extension must not modify the app, earlier extensions, or a
// pre-existing library. Equal executable names must never collide in staging.
let failing = scratch.appendingPathComponent("Failing.app")
try makeBundle(failing, name: "Host")
try makeBundle(failing.appendingPathComponent("PlugIns/A.appex"))
try makeBundle(failing.appendingPathComponent("PlugIns/Z.appex"), bytes: executable(encrypted: true))
let beforeTargets = try IPAPatcher.targets(in: failing)
let before = try beforeTargets.map { try Data(contentsOf: $0.executable) }
checkThrows { try IPAPatcher.apply(to: failing, library: library) }
try check(try beforeTargets.map { try Data(contentsOf: $0.executable) } == before)
precondition(!manager.fileExists(atPath: failing.appendingPathComponent(IPAPatcher.libraryRelativePath).path))

// Simulate a commit I/O error after several replacements. All originals,
// including an already-installed patch, must be restored exactly.
let rollback = scratch.appendingPathComponent("Rollback.app")
try makeBundle(rollback)
try makeBundle(rollback.appendingPathComponent("PlugIns/Share.appex"))
let rollbackTargets = try IPAPatcher.targets(in: rollback)
let originals = try rollbackTargets.map { try Data(contentsOf: $0.executable) }
var replacements = 0
checkThrows {
    try IPAPatcher.apply(to: rollback, library: library, replace: { source, destination in
        replacements += 1
        if replacements == 3 { throw IPAPatcher.Failure(detail: "Simulated commit failure") }
        precondition(rename(source.path, destination.path) == 0)
    })
}
precondition(replacements == 3)
try check(try rollbackTargets.map { try Data(contentsOf: $0.executable) } == originals)
precondition(!manager.fileExists(atPath: rollback.appendingPathComponent("Frameworks").path))

try manager.createDirectory(at: rollback.appendingPathComponent("Frameworks"), withIntermediateDirectories: false)
let oldLibrary = Data("existing patch library".utf8)
let oldLibraryURL = rollback.appendingPathComponent(IPAPatcher.libraryRelativePath)
try oldLibrary.write(to: oldLibraryURL)
replacements = 0
checkThrows {
    try IPAPatcher.apply(to: rollback, library: library, replace: { source, destination in
        replacements += 1
        if replacements == 3 { throw IPAPatcher.Failure(detail: "Simulated library commit failure") }
        precondition(rename(source.path, destination.path) == 0)
    })
}
try check(try Data(contentsOf: oldLibraryURL) == oldLibrary)
try check(try rollbackTargets.map { try Data(contentsOf: $0.executable) } == originals)

// Discovery errors and escaping executables are patch warnings, before writes.
let malformed = scratch.appendingPathComponent("Malformed.app")
try makeBundle(malformed, name: "../Outside")
checkThrows { _ = try IPAPatcher.targets(in: malformed) }
checkThrows { try IPAPatcher.apply(to: app, library: nil) }

let report = SigningPatchReport()
precondition(report.summary == nil, "Successful signing must stay silent")
DispatchQueue.concurrentPerform(iterations: 30) { index in
    report.record(id: String(index), name: "App \(index)", reason: "Failed extension")
}
precondition(report.summary!.components(separatedBy: "Failed extension").count == 31)
print("IPA patch discovery, transaction, repeat-patching, rollback, and report tests passed")
