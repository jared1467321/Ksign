#!/usr/bin/env python3
"""Check original CloudKit ID capture and runtime eligibility (macOS + Swift).

--ipa optionally exercises the same capture/publication path with a real input.
Only native dylib injection is stubbed; the shipping Swift patcher and extracted
Objective-C policy functions run unchanged. This does not launch an iOS app.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SERVICES = "com.apple.developer.icloud-services"
CONTAINERS = "com.apple.developer.icloud-container-identifiers"
LEGACY = "LHXY425M9Z.com.sygic.world"
MODERN = "iCloud.example.original"
OTHER = "iCloud.com.moe.kanan"

# Injection itself is outside this regression's scope. Mark staged files so
# the real patcher can recognize its previous publication on subsequent runs.
SWIFT_STUBS = r'''
import Foundation
private let patchMarker = Data("CONTAINER_CHECK_PATCH".utf8)
func KsignIPAFileHasPatchLibrary(_ path: String, _ name: String, _ error: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 {
    ((try? Data(contentsOf: URL(fileURLWithPath: path)))?.suffix(patchMarker.count) == patchMarker) ? 1 : 0
}
func KsignIPAFileHasLegacyPatchLibrary(_ path: String, _ error: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { 0 }
func KsignPatchIPAFileWithGrowth(_ path: String, _ loadPath: String,
    _ resolver: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32,
    _ context: UnsafeMutableRawPointer?, _ error: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 {
    do {
        let url = URL(fileURLWithPath: path)
        var data = try Data(contentsOf: url)
        data.append(patchMarker)
        try data.write(to: url)
        return 1
    } catch { return -1 }
}
'''

SWIFT_MAIN = r'''
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cases.json"))) as! [[String: Any]]
let key = IPAPatcher.originalCloudContainerIdentifiers
let library = root.appendingPathComponent("library")
try Data("library fixture".utf8).write(to: library)
var results: [[String: Any]] = []
func info(_ app: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), options: [], format: nil) as! [String: Any]
}
for fixture in cases {
    let name = fixture["name"] as! String
    let app = root.appendingPathComponent(name + ".app", isDirectory: true)
    let executable = (try info(app))["CFBundleExecutable"] as! String
    let expected = fixture["expected"] as? [String]
    let snapshots = IPAPatcher.compatibilitySnapshots(in: app)
    precondition(snapshots[executable]?.containers == expected, "capture: " + name)
    try IPAPatcher.apply(to: app, library: library, originalSnapshots: snapshots)
    let first = try info(app)
    precondition(first[key] as? [String] == expected, "publication: " + name)
    let policy = IPAPatcher.cloudEntitlementPolicy(in: app)
    precondition(policy[executable] == snapshots[executable]?.keys, "cloud key policy: " + name)
    precondition(IPAPatcher.compatibilitySnapshots(in: app).isEmpty, "patched app must not become original evidence")
    // Replace the executable's entitlements with the new profile's capabilities.
    let replacement = try Data(contentsOf: root.appendingPathComponent("resigned"))
    try replacement.write(to: app.appendingPathComponent(executable))
    try IPAPatcher.apply(to: app, library: library)
    let resignedInfo = try info(app)
    precondition(resignedInfo[key] as? [String] == expected, "first snapshot must survive re-signing: " + name)
    var result: [String: Any] = ["name": name, "info": first]
    result["expected"] = expected.map { $0 as Any } ?? NSNull()
    results.append(result)
}
// Each executable needs its own original snapshot, including app extensions.
let manager = FileManager.default
let parent = root.appendingPathComponent("per-bundle.app", isDirectory: true)
let child = parent.appendingPathComponent("PlugIns/child.appex", isDirectory: true)
try manager.createDirectory(at: child, withIntermediateDirectories: true)
for (app, source) in [(parent, "modern.app"), (child, "sygic.app")] {
    let originalInfo = try info(root.appendingPathComponent(source))
    var freshInfo: [String: Any] = ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "example.per-bundle"]
    freshInfo["ExpectedContainers"] = originalInfo[key]
    try PropertyListSerialization.data(fromPropertyList: freshInfo, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    let originalExecutable = String(source.dropLast(4)) + ".original"
    try manager.copyItem(at: root.appendingPathComponent(originalExecutable), to: app.appendingPathComponent("Fixture"))
}
let originals = IPAPatcher.compatibilitySnapshots(in: parent)
precondition(originals["Fixture"]?.containers == ["iCloud.example.original"], "root capture")
precondition(originals["PlugIns/child.appex/Fixture"]?.containers == ["LHXY425M9Z.com.sygic.world"], "extension capture")
try IPAPatcher.apply(to: parent, library: library, originalSnapshots: originals)
for app in [parent, child] {
    let published = try info(app)
    precondition(published[key] as? [String] == published["ExpectedContainers"] as? [String], "per-executable publication")
}
try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]).write(to: root.appendingPathComponent("captured.json"))
print("Passed capture, publication, signing-policy and re-signing checks for \(cases.count) inputs")
'''

NATIVE_MAIN = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
static NSDictionary *FixtureInfo, *FixtureSigned;
static NSString *const ServicesKey = @"com.apple.developer.icloud-services";
static NSString *const ContainersKey = @"com.apple.developer.icloud-container-identifiers";
static NSDictionary *SignedEntitlements(void) { return FixtureSigned; }
@interface NSBundle (ContainerCheck)
- (NSDictionary *)containerCheckInfo;
@end
@implementation NSBundle (ContainerCheck)
- (NSDictionary *)containerCheckInfo { return FixtureInfo; }
@end
// The actual policy functions from CloudKitPatch.m are inserted here.
__POLICY__
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        Check(argc == 2, @"Expected capture results");
        method_exchangeImplementations(class_getInstanceMethod(NSBundle.class, @selector(infoDictionary)),
            class_getInstanceMethod(NSBundle.class, @selector(containerCheckInfo)));
        NSArray *fixtures = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:@(argv[1])] options:0 error:NULL];
        Check([fixtures isKindOfClass:NSArray.class] && fixtures.count > 0, @"Capture results must be readable");
        for (NSDictionary *fixture in fixtures) {
            FixtureInfo = fixture[@"info"];
            id expected = fixture[@"expected"];
            BOOL captured = [expected isKindOfClass:NSArray.class] && [expected count] > 0;
            FixtureSigned = @{ServicesKey: @"*", ContainersKey: @[@"iCloud.com.moe.kanan"]};
            Check(NeedsCloudKitPatch() == captured, fixture[@"name"]);
            for (NSString *identifier in captured ? expected : @[]) {
                Check(NeedsLocal(identifier), @"Unavailable captured container needs fallback");
            }
            Check(!NeedsLocal(@"UNKNOWN.com.example") && !NeedsLocal(@"iCloud.unrelated"), @"Uncaptured requests stay native");
            FixtureSigned = nil;
            Check(!NeedsCloudKitPatch() && !NeedsLocal([expected isKindOfClass:NSArray.class] ? [expected firstObject] : nil),
                @"Unreadable signature stays native");
            if (!captured) continue;
            FixtureSigned = @{ServicesKey: @[@"CloudKit"], ContainersKey: expected};
            Check(!NeedsCloudKitPatch(), @"Fully authorized app stays native");
            for (NSString *identifier in expected) Check(!NeedsLocal(identifier), @"Authorized request stays native");
            if ([expected count] > 1) {
                FixtureSigned = @{ServicesKey: @[@"CloudKit"], ContainersKey: @[expected[0]]};
                Check(NeedsCloudKitPatch() && !NeedsLocal(expected[0]) && NeedsLocal(expected[1]), @"Mixed permissions remain scoped");
            }
            FixtureSigned = @{ServicesKey: @"*", ContainersKey: @[@"iCloud.com.moe.kanan"]};
            Check([DefaultIdentifier() isEqual:expected[0]], @"Default fallback preserves original identity");
        }
        FixtureSigned = @{ServicesKey: @"*", ContainersKey: @[@"iCloud.com.moe.kanan"]};
        for (id invalid in @[@"*", @"iCloud.*", @"", @".", @"..", @"a/b", @"a\\b", @"a b", @"é.example", @42]) {
            FixtureInfo = @{@"AsignOriginalCloudContainerIdentifiers": @[@"LHXY425M9Z.com.sygic.world", invalid]};
            Check(!NeedsCloudKitPatch(), @"Malformed runtime snapshots stay dormant");
        }
        FixtureInfo = @{@"AsignOriginalCloudContainerIdentifiers": @"LHXY425M9Z.com.sygic.world"};
        Check(!NeedsCloudKitPatch(), @"Wrong-type runtime snapshot stays dormant");
        puts("Passed runtime eligibility, authorized/mixed permissions, unknown-signature and exact-container checks");
    }
}
'''


def executable(entitlements):
    xml = plistlib.dumps(entitlements)
    blob = struct.pack(">II", 0xFADE7171, 8 + len(xml)) + xml
    signature = struct.pack(">IIIII", 0xFADE0CC0, 20 + len(blob), 1, 5, 20) + blob
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 1, 16, 0, 0)
    return header + struct.pack("<IIII", 0x1D, 16, 48, len(signature)) + signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ksign-cloudkit-containers-") as directory:
        scratch = Path(directory)
        cases = []

        def fixture(name, containers, expected, services=None):
            app = scratch / (name + ".app")
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "example." + name, "CFBundleExecutable": "Fixture"}))
            values = {} if services is None and containers is None else {SERVICES: services or ["CloudKit"], CONTAINERS: containers}
            data = executable(values)
            (app / "Fixture").write_bytes(data)
            (scratch / (name + ".original")).write_bytes(data)
            cases.append(dict(name=name, expected=expected))

        fixture("sygic", [LEGACY], [LEGACY])
        fixture("modern", [MODERN], [MODERN])
        fixture("mixed", [LEGACY, MODERN, LEGACY], [LEGACY, MODERN])
        fixture("local", None, [])
        fixture("documents-only", [LEGACY], [], services=["CloudDocuments"])
        for i, value in enumerate(["*", "iCloud.*", "", ".", "..", "a/b", "a\\b", "a b", "é.example", 42]):
            fixture(f"invalid-{i}", [LEGACY, value], None)
        fixture("wrong-type", LEGACY, None)
        if args.ipa:
            with zipfile.ZipFile(args.ipa) as archive:
                plist = next(n for n in archive.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
                info = plistlib.loads(archive.read(plist))
                app = scratch / "real-sygic.app"
                app.mkdir()
                (app / "Info.plist").write_bytes(archive.read(plist))
                (app / info["CFBundleExecutable"]).write_bytes(archive.read(plist.rsplit("/", 1)[0] + "/" + info["CFBundleExecutable"]))
                cases.append(dict(name="real-sygic", expected=[LEGACY]))
        (scratch / "resigned").write_bytes(executable({SERVICES: "*", CONTAINERS: [OTHER]}))
        (scratch / "cases.json").write_text(json.dumps(cases))
        (scratch / "stubs.swift").write_text(SWIFT_STUBS)
        (scratch / "main.swift").write_text(SWIFT_MAIN)
        subprocess.run([args.swiftc, "-module-cache-path", str(scratch / "modules"),
                        str(ROOT / "Asign/Utilities/Handlers/IPAPatcher.swift"),
                        str(scratch / "stubs.swift"), str(scratch / "main.swift"), "-o", str(scratch / "capture")], check=True)
        subprocess.run([str(scratch / "capture"), str(scratch)], check=True)
        if platform.system() != "Darwin":
            print("Runtime Objective-C checks require macOS Foundation; capture/publication checks completed.")
            return
        source = (ROOT / "Native/IdentityPatch/CloudKitPatch.m").read_text()
        policy = source[source.index("static BOOL ValidIdentifier("):source.index("static NSDictionary *ConstructionEntitlements(")]
        (scratch / "runtime.m").write_text(NATIVE_MAIN.replace("__POLICY__", policy))
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                        str(scratch / "runtime.m"), "-framework", "Foundation", "-o", str(scratch / "runtime")], check=True)
        subprocess.run([str(scratch / "runtime"), str(scratch / "captured.json")], check=True)


if __name__ == "__main__":
    main()
